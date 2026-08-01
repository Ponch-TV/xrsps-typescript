import fs from "fs";
import type { IncomingMessage, ServerResponse } from "http";
import path from "path";

import { logger } from "../utils/logger";

/**
 * Static file serving for `server/caches/` over the same HTTP server that
 * upgrades to WebSocket.
 *
 * In development the CRA dev server serves `/caches` itself (see
 * `client/craco.config.js`). In production the client is a static bundle on a
 * CDN, so the cache has to come from somewhere with CORS — serving it next to
 * the game server keeps it to a single deployable and a single hostname.
 *
 * The client downloads `main_file_cache.dat2` (~200MB) resumably, so range
 * requests and HEAD both have to work. See `client/rs/cache/CacheFiles.ts`.
 */

const URL_PREFIX = "/caches/";

/** Long TTL: cache dirs are versioned by revision (`osrs-237_2026-03-25`). */
const IMMUTABLE_CACHE_CONTROL = "public, max-age=31536000, immutable";
/** The cache manifest changes when the target revision moves. */
const MANIFEST_CACHE_CONTROL = "public, max-age=60";

function contentTypeFor(file: string): string {
    return file.endsWith(".json") ? "application/json" : "application/octet-stream";
}

function corsHeaders(): Record<string, string> {
    return {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
        "Access-Control-Allow-Headers": "Range, Content-Type",
        // Without this the browser hides these from `fetch`, and the client's
        // resumable download can't tell how many bytes it still needs.
        "Access-Control-Expose-Headers": "Content-Length, Content-Range, Accept-Ranges",
        "Access-Control-Max-Age": "86400",
    };
}

/**
 * Resolve a URL path to a file inside `root`, or undefined when it escapes the
 * root or does not exist.
 */
function resolveFile(root: string, urlPath: string): string | undefined {
    let decoded: string;
    try {
        decoded = decodeURIComponent(urlPath);
    } catch {
        return undefined;
    }
    if (decoded.includes("\0")) return undefined;

    const resolved = path.resolve(root, `.${path.posix.normalize(decoded)}`);
    const rootWithSep = root.endsWith(path.sep) ? root : root + path.sep;
    if (resolved !== root && !resolved.startsWith(rootWithSep)) return undefined;

    let stat: fs.Stats;
    try {
        stat = fs.statSync(resolved);
    } catch {
        return undefined;
    }
    return stat.isFile() ? resolved : undefined;
}

type ParsedRange = { start: number; end: number };

/**
 * Parse a single-range `Range` header against a known size.
 * Returns undefined for "no range", null for "unsatisfiable".
 *
 * The client sends `bytes=<offset>-9007199254740991` (MAX_SAFE_INTEGER) when
 * resuming, so the end has to be clamped rather than rejected.
 */
function parseRange(header: string | undefined, size: number): ParsedRange | null | undefined {
    if (!header) return undefined;
    const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
    if (!match) return undefined;

    const [, rawStart, rawEnd] = match;
    if (rawStart === "" && rawEnd === "") return undefined;

    let start: number;
    let end: number;
    if (rawStart === "") {
        // Suffix range: last N bytes.
        const suffix = Number(rawEnd);
        if (!Number.isFinite(suffix) || suffix <= 0) return null;
        start = Math.max(0, size - suffix);
        end = size - 1;
    } else {
        start = Number(rawStart);
        end = rawEnd === "" ? size - 1 : Number(rawEnd);
        if (!Number.isFinite(start)) return null;
        if (!Number.isFinite(end)) end = size - 1;
        end = Math.min(end, size - 1);
    }

    if (start >= size || start > end) return null;
    return { start, end };
}

export type CacheRequestHandler = (req: IncomingMessage, res: ServerResponse) => boolean;

/**
 * Build a request handler for `/caches/*`.
 *
 * Returns `true` when it took ownership of the request, `false` when the caller
 * should keep handling it (different path, or the cache dir is absent).
 */
export function createCacheRequestHandler(cachesRoot: string): CacheRequestHandler {
    const root = path.resolve(cachesRoot);

    return (req, res) => {
        const urlPath = (req.url ?? "").split("?")[0];
        if (!urlPath.startsWith(URL_PREFIX)) return false;

        const method = req.method ?? "GET";
        if (method === "OPTIONS") {
            res.writeHead(204, corsHeaders());
            res.end();
            return true;
        }
        if (method !== "GET" && method !== "HEAD") {
            res.writeHead(405, { ...corsHeaders(), Allow: "GET, HEAD, OPTIONS" });
            res.end();
            return true;
        }

        const file = resolveFile(root, urlPath.slice(URL_PREFIX.length - 1));
        if (!file) {
            res.writeHead(404, { ...corsHeaders(), "Content-Type": "text/plain" });
            res.end("Not found");
            return true;
        }

        const size = fs.statSync(file).size;
        const isManifest = path.basename(file) === "caches.json";
        const baseHeaders: Record<string, string> = {
            ...corsHeaders(),
            "Content-Type": contentTypeFor(file),
            "Accept-Ranges": "bytes",
            "Cache-Control": isManifest ? MANIFEST_CACHE_CONTROL : IMMUTABLE_CACHE_CONTROL,
        };

        const range = parseRange(req.headers.range, size);
        if (range === null) {
            res.writeHead(416, { ...baseHeaders, "Content-Range": `bytes */${size}` });
            res.end();
            return true;
        }

        const start = range ? range.start : 0;
        const end = range ? range.end : size - 1;
        const length = size === 0 ? 0 : end - start + 1;

        const headers: Record<string, string> = {
            ...baseHeaders,
            "Content-Length": String(length),
        };
        if (range) headers["Content-Range"] = `bytes ${start}-${end}/${size}`;

        res.writeHead(range ? 206 : 200, headers);

        if (method === "HEAD" || length === 0) {
            res.end();
            return true;
        }

        const stream = fs.createReadStream(file, { start, end });
        stream.on("error", (err) => {
            logger.warn(`[cacheHttp] read failed for ${file}`, err);
            res.destroy();
        });
        // Client aborts are routine (page reload mid-download); just stop reading.
        res.on("close", () => stream.destroy());
        stream.pipe(res);
        return true;
    };
}

/**
 * Create the handler only when the cache directory actually exists, so a server
 * started without a local cache keeps its previous behaviour.
 */
export function tryCreateCacheRequestHandler(cachesRoot: string): CacheRequestHandler | undefined {
    if (!fs.existsSync(cachesRoot)) {
        logger.info(`[cacheHttp] no cache directory at ${cachesRoot}, not serving /caches`);
        return undefined;
    }
    logger.info(`[cacheHttp] serving /caches from ${cachesRoot}`);
    return createCacheRequestHandler(cachesRoot);
}
