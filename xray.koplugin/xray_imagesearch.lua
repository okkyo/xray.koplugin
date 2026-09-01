--[[
X-Ray Image Search

Searches the web for an image of an X-Ray entity (character, location,
historical figure, glossary term) and downloads the chosen image into the
book's ".sdr" sidecar so it travels with the book.

Primary source : Tavily Search API (include_images). Needs one config value,
                 tavily_api_key (Bearer token). Used only when the key is set.
Fallback source: DuckDuckGo image search (no key). This is a two-step scrape:
                 fetch a page to read the "vqd" token, then call i.js for JSON.
                 It is the default when no Tavily key is set, and the fallback
                 when a Tavily search fails or returns nothing.

Network I/O in this module is meant to run inside a KOReader Trapper
subprocess (see xray_ui: showImageAttachFlow), so the UI thread never blocks
and the reader can cancel. The pure URL-building and JSON-parsing helpers are
exposed for the test suite.
--]]

local ImageSearch = {}

-- ---------------------------------------------------------------------------
-- JSON (rapidjson if present, else the bundled json)
-- ---------------------------------------------------------------------------
local json_ok, json = pcall(require, "json")
if not json_ok or type(json) ~= "table" then
    json_ok, json = pcall(require, "rapidjson")
end

-- Optional logger. Guarded so the pure helpers still load under the test
-- harness, which does not always provide KOReader's logger.
local log_ok, logger = pcall(require, "logger")
if not log_ok then logger = nil end

local MAX_RESULTS = 6

-- Cap on a downloaded image. A large image decodes to a bitmap many times its
-- file size and can exhaust memory on old e-ink hardware (2012 Kindle reference).
-- The card re-decodes this file on every open, so keep the cap tight. A 2 MB
-- JPEG already decodes to ~15-30 MB of bitmap.
local MAX_IMAGE_BYTES = 2 * 1024 * 1024

-- Longest edge (px) of the stored display image. Above this it is downscaled at
-- attach; at or below it the original bytes are kept, to avoid re-encode quality
-- loss. The full-screen viewer supports zoom, so this keeps headroom above the
-- ~1024 px device height.
local DISPLAY_MAX_EDGE = 1600
-- Smallest thumbnail longest edge (px). The card renders at ~half the device
-- short edge. This floor keeps a thumbnail made on a small device usable if the
-- book later opens on a larger screen.
local THUMB_MIN_EDGE = 400
-- JPEG quality for generated (downscaled) images.
local JPEG_QUALITY = 85
-- Longest edge (px) for a candidate preview in the picker. Some providers give
-- no separate thumbnail (Tavily returns the full image URL as the "thumbnail"),
-- so a full-size file — up to MAX_IMAGE_BYTES — would otherwise be decoded on
-- the UI thread on every Previous/Next tap. Those files are shrunk to this edge
-- in the search subprocess so the picker only ever decodes a small image.
local PREVIEW_MAX_EDGE = 600

local KNOWN_EXT = {
    jpg = true, jpeg = true, png = true, gif = true, webp = true, bmp = true, tiff = true,
}

-- ---------------------------------------------------------------------------
-- Pure helpers (unit-tested)
-- ---------------------------------------------------------------------------

function ImageSearch.urlencode(s)
    s = tostring(s or "")
    s = s:gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return s
end

-- Make a safe, short filename fragment from an entity name.
function ImageSearch.slugify(name)
    local s = tostring(name or "entity"):lower()
    s = s:gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if #s == 0 then s = "entity" end
    if #s > 40 then s = s:sub(1, 40) end
    return s
end

-- Derive a usable image extension from a URL. Falls back to "jpg" because
-- KOReader's ImageWidget decides how to render by the file extension.
function ImageSearch.extFromUrl(url)
    local path = tostring(url or ""):gsub("%?.*$", ""):gsub("#.*$", "")
    local ext = path:match("%.([%a]+)$")
    ext = ext and ext:lower() or nil
    if ext and KNOWN_EXT[ext] then return ext end
    return "jpg"
end

-- Tavily Search API endpoint. A single POST with a Bearer token; asking for
-- images returns a top-level `images` list of query-related image URLs.
ImageSearch.TAVILY_URL = "https://api.tavily.com/search"

-- Build the JSON request body for a Tavily image search. "basic" depth costs
-- 1 credit; descriptions give each image a caption for the picker.
function ImageSearch.buildTavilyBody(query, num)
    if not json_ok then return nil end
    return json.encode({
        query = tostring(query or ""),
        search_depth = "basic",
        include_images = true,
        include_image_descriptions = true,
        max_results = num or MAX_RESULTS,
    })
end

-- Parse a Tavily response body. The `images` field is either a list of URL
-- strings or, with descriptions on, a list of { url, description } objects.
-- Returns a list of { full=<url>, thumb=<url>, title=<str> } or nil, err.
function ImageSearch.parseTavily(body)
    if not json_ok then return nil, "json module unavailable" end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then return nil, "parse error" end
    local detail = ImageSearch._errorDetail(body)
    if detail then return nil, detail end
    local out = {}
    for _, item in ipairs(data.images or {}) do
        local url, title
        if type(item) == "string" then
            url = item
        elseif type(item) == "table" then
            url = item.url
            title = item.description
        end
        if type(url) == "string" and #url > 0 then
            -- Tavily gives one URL per image (no separate thumbnail), so the
            -- same URL serves both the preview and the full download.
            out[#out + 1] = { full = url, thumb = url, title = title or "" }
        end
    end
    return out
end

-- DuckDuckGo image search is an unofficial two-step flow:
--   1. GET the search page and read a per-session "vqd" token from it.
--   2. GET i.js with that token to receive results as JSON.
-- It needs a browser-like User-Agent and a duckduckgo.com Referer, or the
-- endpoint answers 403. See DDG_HEADERS below.
-- DURABILITY: this is the no-key default path, so every user without a Tavily
-- key depends on it. DDG can change the token shape, the i.js endpoint, or the
-- required headers with no notice; a break shows as "could not read
-- DuckDuckGo token" (extractVqd miss) or an empty result set. If that happens,
-- re-check the vqd patterns (extractVqd), the URLs, and DDG_HEADERS first.
function ImageSearch.buildDdgTokenUrl(query)
    return "https://duckduckgo.com/?q=" .. ImageSearch.urlencode(query)
        .. "&iax=images&ia=images"
end

-- Pull the vqd token out of the DDG search page. The token has appeared in a
-- few shapes over time (quoted, and as vqd=NN-... inside a URL), so try each.
function ImageSearch.extractVqd(body)
    if type(body) ~= "string" then return nil end
    local vqd = body:match("vqd=['\"]([^'\"]+)['\"]")
        or body:match('"vqd":"([^"]+)"')
        or body:match("vqd=([%d%-]+)&")
    return vqd
end

function ImageSearch.buildDdgSearchUrl(query, vqd)
    return "https://duckduckgo.com/i.js?l=us-en&o=json&f=,,,&p=1"
        .. "&q=" .. ImageSearch.urlencode(query)
        .. "&vqd=" .. ImageSearch.urlencode(vqd)
end

-- Parse a DuckDuckGo i.js response body.
-- Returns a list of { full=<url>, thumb=<url>, title=<str> } or nil, err.
function ImageSearch.parseDdg(body)
    if not json_ok then return nil, "json module unavailable" end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then return nil, "parse error" end
    -- A genuine empty search returns a "results" array (possibly empty). A
    -- missing "results" key means DuckDuckGo changed its response shape; report
    -- that as a provider error, so the picker does not show it as "no images".
    if type(data.results) ~= "table" then
        return nil, "unexpected DuckDuckGo response"
    end
    local out = {}
    for _, item in ipairs(data.results) do
        local full = item.image
        if type(full) == "string" and #full > 0 then
            out[#out + 1] = {
                full  = full,
                thumb = (type(item.thumbnail) == "string" and item.thumbnail) or full,
                title = item.title or item.source or "",
            }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Filesystem helpers
-- ---------------------------------------------------------------------------

local function _lfs()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or type(lfs) ~= "table" then ok, lfs = pcall(require, "lfs") end
    if ok and type(lfs) == "table" then return lfs end
    return nil
end

local function _ensureDir(dir)
    local lfs = _lfs()
    if not lfs then return true end -- assume present when we cannot check
    if lfs.attributes(dir, "mode") ~= "directory" then
        pcall(lfs.mkdir, dir)
    end
    return lfs.attributes(dir, "mode") == "directory"
end

-- Remove every file in a directory (best-effort). Used to prune stale candidate
-- thumbnails, whose variable extensions would otherwise accumulate.
local function _clearDir(dir)
    if not dir then return end
    local lfs = _lfs()
    if not lfs then return end
    pcall(function()
        for f in lfs.dir(dir) do
            if f ~= "." and f ~= ".." then
                pcall(os.remove, dir .. "/" .. f)
            end
        end
    end)
end

-- Per-book image directory inside the .sdr sidecar (images travel with the book).
function ImageSearch.getImagesDir(book_path)
    if not book_path then return nil end
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or not DocSettings then return nil end
    local sidecar = DocSettings:getSidecarDir(book_path)
    if not sidecar then return nil end
    local dir = sidecar .. "/xray_images"
    _ensureDir(dir)
    return dir
end

-- Plugin-global scratch dir for candidate thumbnails during a search.
function ImageSearch.getTempDir()
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok or not DataStorage then return nil end
    local base = DataStorage:getDataDir() .. "/xray"
    _ensureDir(base)
    local dir = base .. "/imgtmp"
    _ensureDir(dir)
    return dir
end

-- Prune the candidate-thumbnail scratch dir. Call when the picker closes so
-- thumbnails do not sit on disk until the next search.
function ImageSearch.clearTempDir()
    _clearDir(ImageSearch.getTempDir())
end

-- Permanent destination path for an attached image.
function ImageSearch.destPathFor(book_path, entity_type, name, ext, stamp)
    local dir = ImageSearch.getImagesDir(book_path)
    if not dir then return nil end
    local fname = (entity_type or "entity")
        .. "_" .. ImageSearch.slugify(name)
        .. "_" .. tostring(stamp or os.time())
        .. "." .. (ext or "jpg")
    return dir .. "/" .. fname
end

-- Deterministic thumbnail path for a stored image: "<base>.thumb.jpg" in the
-- same sidecar dir. Thumbnails are always JPEG, so the path is independent of
-- the source extension.
function ImageSearch.thumbPathFor(image_path)
    if type(image_path) ~= "string" or #image_path == 0 then return nil end
    local base = image_path:gsub("%.[%w]+$", "")
    return base .. ".thumb.jpg"
end

-- Swap a path's extension: "<base>.<old>" -> "<base>.<new>".
local function _swapExt(path, new_ext)
    return (path:gsub("%.[%w]+$", "")) .. "." .. new_ext
end

-- ---------------------------------------------------------------------------
-- HTTP (scheme-aware; mirrors xray_updater / xray_websetup idioms)
-- ---------------------------------------------------------------------------

-- KOReader's socket/http speaks both http and https (LuaSec sits underneath the
-- https scheme) AND follows redirects, including a scheme switch. Do NOT use
-- ssl.https directly: it rejects the `redirect` option with "redirect not
-- supported", which broke every https search/download. This mirrors
-- xray_updater, which fetches from GitHub (a host that redirects) the same way.
local function _httpLib(_url)
    return require("socket/http")
end

-- A browser-like User-Agent. DuckDuckGo rejects unknown agents, and many image
-- hosts (fan wikis, CDNs) hotlink-block non-browser agents on download.
local BROWSER_UA =
    "Mozilla/5.0 (X11; Linux x86_64; rv:115.0) Gecko/20100101 Firefox/115.0"

-- Headers the DuckDuckGo endpoints expect. Without a browser agent and a
-- duckduckgo.com Referer, both the token page and i.js answer 403.
ImageSearch.DDG_HEADERS = {
    ["User-Agent"]      = BROWSER_UA,
    ["Accept"]          = "application/json, text/javascript, */*; q=0.01",
    ["Accept-Language"] = "en-US,en;q=0.5",
    ["Referer"]         = "https://duckduckgo.com/",
}

-- Trim a string to at most max_bytes, but never in the middle of a UTF-8
-- character, so a non-Latin error message does not end in a broken glyph.
local function _utf8TrimToBytes(s, max_bytes)
    if #s <= max_bytes then return s end
    local cut = max_bytes
    -- If the first dropped byte is a UTF-8 continuation byte (0x80-0xBF), the
    -- cut falls inside a character. Back up to the character start.
    while cut > 0 do
        local b = s:byte(cut + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut)
end

-- Pull a short human reason out of an API error body, so a bare "HTTP 401"
-- can instead say WHY (key invalid, quota exceeded). Handles the shapes seen
-- from both providers:
--   Google-style : { "error": { "message": "..." } }
--   Tavily-style : { "detail": "..." } or { "detail": { "error": "..." } }
--                  or a top-level { "error": "..." } string.
-- Returns a trimmed string or nil when the body carries no error message.
function ImageSearch._errorDetail(body)
    if type(body) ~= "string" or #body == 0 or not json_ok then return nil end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then return nil end
    local msg
    if type(data.error) == "table" then
        msg = data.error.message
    elseif type(data.error) == "string" then
        msg = data.error
    elseif type(data.detail) == "string" then
        msg = data.detail
    elseif type(data.detail) == "table" then
        msg = data.detail.error or data.detail.message
    end
    if type(msg) ~= "string" or #msg == 0 then return nil end
    if #msg > 160 then msg = _utf8TrimToBytes(msg, 160) .. "..." end
    return msg
end

function ImageSearch.httpGetString(url, timeout, extra_headers)
    local ok_su, socketutil = pcall(require, "socketutil")
    local ltn12  = require("ltn12")
    local socket = require("socket")
    local httplib = _httpLib(url)

    timeout = timeout or 20
    if ok_su then socketutil:set_timeout(timeout, timeout * 2) end

    local headers = {
        ["User-Agent"] = "KOReader-XRay/1.0",
        ["Accept"]     = "application/json",
    }
    if type(extra_headers) == "table" then
        for k, v in pairs(extra_headers) do headers[k] = v end
    end

    local chunks = {}
    local code, rheaders, status = socket.skip(1, httplib.request({
        url     = url,
        method  = "GET",
        headers = headers,
        sink     = ltn12.sink.table(chunks),
        redirect = true,
    }))

    if ok_su then socketutil:reset_timeout() end

    if rheaders == nil then
        return nil, "network error (" .. tostring(code or status) .. ")"
    end
    if code == 200 then return table.concat(chunks) end
    local detail = ImageSearch._errorDetail(table.concat(chunks))
    return nil, "HTTP " .. tostring(code) .. (detail and (": " .. detail) or "")
end

-- POST a request body (used by the Tavily provider). Mirrors httpGetString:
-- socket/http (redirect-safe), byte-safe table sink, error-detail extraction.
function ImageSearch.httpPostString(url, req_body, extra_headers, timeout)
    local ok_su, socketutil = pcall(require, "socketutil")
    local ltn12  = require("ltn12")
    local socket = require("socket")
    local httplib = _httpLib(url)

    req_body = req_body or ""
    timeout = timeout or 20
    if ok_su then socketutil:set_timeout(timeout, timeout * 2) end

    local headers = {
        ["User-Agent"]     = "KOReader-XRay/1.0",
        ["Accept"]         = "application/json",
        ["Content-Type"]   = "application/json",
        ["Content-Length"] = tostring(#req_body),
    }
    if type(extra_headers) == "table" then
        for k, v in pairs(extra_headers) do headers[k] = v end
    end

    local chunks = {}
    local code, rheaders, status = socket.skip(1, httplib.request({
        url     = url,
        method  = "POST",
        headers = headers,
        source  = ltn12.source.string(req_body),
        sink    = ltn12.sink.table(chunks),
        redirect = true,
    }))

    if ok_su then socketutil:reset_timeout() end

    if rheaders == nil then
        return nil, "network error (" .. tostring(code or status) .. ")"
    end
    if code == 200 then return table.concat(chunks) end
    local detail = ImageSearch._errorDetail(table.concat(chunks))
    return nil, "HTTP " .. tostring(code) .. (detail and (": " .. detail) or "")
end

function ImageSearch.httpGetToFile(url, dest_path, timeout)
    local ok_su, socketutil = pcall(require, "socketutil")
    local socket = require("socket")
    local httplib = _httpLib(url)

    local fh, err_open = io.open(dest_path, "wb")
    if not fh then return nil, "cannot create file: " .. tostring(err_open) end

    timeout = timeout or 30
    if ok_su then socketutil:set_timeout(timeout, timeout * 2) end

    -- Custom sink: write to the file but abort once the byte cap is exceeded,
    -- so a hostile or oversized body cannot fill memory or storage.
    local written = 0
    local too_large = false
    local capped_sink = function(chunk)
        if chunk == nil then return 1 end
        written = written + #chunk
        if written > MAX_IMAGE_BYTES then
            too_large = true
            return nil, "image too large"
        end
        return fh:write(chunk) and 1 or nil
    end

    local code, headers, status = socket.skip(1, httplib.request({
        url      = url,
        method   = "GET",
        headers  = { ["User-Agent"] = BROWSER_UA },
        sink     = capped_sink,
        redirect = true,
    }))

    if ok_su then socketutil:reset_timeout() end
    pcall(function() fh:close() end)

    if too_large then
        pcall(os.remove, dest_path)
        return nil, "image too large"
    end
    if headers == nil then
        pcall(os.remove, dest_path)
        return nil, "network error (" .. tostring(code or status) .. ")"
    end
    if code ~= 200 then
        pcall(os.remove, dest_path)
        return nil, "HTTP " .. tostring(code)
    end
    -- Reject non-image bodies: a hotlink-block or a 404-served-as-200 returns
    -- HTML, which would store a bogus file and later render blank. Accept an
    -- image/* type, but also accept a generic or absent type: many CDNs and
    -- wikis serve valid JPEG/PNG as application/octet-stream or with no type.
    -- Reject only a clearly non-image type such as text/html.
    local ctype = headers and (headers["content-type"] or headers["Content-Type"])
    if type(ctype) == "string" and ctype ~= "" then
        local c = ctype:lower()
        local is_image = c:match("^%s*image/")
        local is_generic = c:match("^%s*application/octet%-stream")
            or c:match("^%s*binary/octet%-stream")
        if not is_image and not is_generic then
            pcall(os.remove, dest_path)
            return nil, "not an image (" .. ctype .. ")"
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- High-level operations (run inside a Trapper subprocess)
-- ---------------------------------------------------------------------------

-- Tavily provider: one POST with a Bearer token. Returns results or nil, err.
function ImageSearch.searchTavily(query, api_key)
    local body = ImageSearch.buildTavilyBody(query)
    if not body then return nil, "json module unavailable" end
    local resp, err = ImageSearch.httpPostString(ImageSearch.TAVILY_URL, body, {
        ["Authorization"] = "Bearer " .. tostring(api_key),
    }, 20)
    if not resp then return nil, err end
    return ImageSearch.parseTavily(resp)
end

-- DuckDuckGo provider: read the vqd token, then fetch i.js JSON. Both requests
-- use the browser-like DDG headers. Returns results or nil, err.
function ImageSearch.searchDdg(query)
    local token_body, err = ImageSearch.httpGetString(
        ImageSearch.buildDdgTokenUrl(query), 15, ImageSearch.DDG_HEADERS)
    if not token_body then return nil, err end
    local vqd = ImageSearch.extractVqd(token_body)
    if not vqd then
        -- No token means DuckDuckGo changed its page shape. Log it so a future
        -- silent break of the no-key default is diagnosable from the log.
        if logger then
            logger.warn("[X-Ray] DuckDuckGo image search: could not read vqd token; site format may have changed")
        end
        return nil, "could not read DuckDuckGo token"
    end
    local body, serr = ImageSearch.httpGetString(
        ImageSearch.buildDdgSearchUrl(query, vqd), 20, ImageSearch.DDG_HEADERS)
    if not body then return nil, serr end
    return ImageSearch.parseDdg(body)
end

-- Run the search. Tavily is the primary when a key is set; DuckDuckGo is the
-- no-key default and the fallback when Tavily fails or returns nothing.
-- Returns results, source, err.
function ImageSearch.doSearch(query, tavily_key)
    if type(tavily_key) == "string" and #tavily_key > 0 then
        local results, err = ImageSearch.searchTavily(query, tavily_key)
        if results and #results > 0 then return results, "tavily" end
        -- Tavily errored or came back empty: fall back to DuckDuckGo.
        local ddg, derr = ImageSearch.searchDdg(query)
        if ddg then return ddg, "duckduckgo" end
        return nil, "tavily", err or derr
    end

    local ddg, derr = ImageSearch.searchDdg(query)
    if not ddg then return nil, "duckduckgo", derr end
    return ddg, "duckduckgo"
end

-- Downscale a preview file in place to PREVIEW_MAX_EDGE (never upscale) and
-- re-encode as JPEG, so the picker decodes a small image instead of a full-size
-- one. Best-effort: needs KOReader's renderer, so it no-ops (keeps the original
-- file) when the renderer is absent or the decode fails. Meant to run inside the
-- search subprocess. Returns true when it rewrote the file.
function ImageSearch.shrinkPreviewFile(path)
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not ok_ri or not RenderImage then return false end
    local rewrote = false
    local ok = pcall(function()
        local native = RenderImage:renderImageFile(path, false)
        if not native then error("decode failed") end
        local nw, nh = native:getWidth(), native:getHeight()
        local longest = math.max(nw or 0, nh or 0)
        if longest <= 0 then native:free(); error("bad dimensions") end
        if longest <= PREVIEW_MAX_EDGE then native:free(); return end -- already small
        local s = PREVIEW_MAX_EDGE / longest
        local small = RenderImage:scaleBlitBuffer(native, math.floor(nw * s), math.floor(nh * s), false)
        native:free()
        -- Write JPEG under the same path; the picker decides format by extension,
        -- so normalize the file to ".jpg" and drop the original if it differed.
        local jpg_path = path:gsub("%.[%a]+$", ".jpg")
        local wok = small:writeToFile(jpg_path, "jpg", JPEG_QUALITY)
        small:free()
        if wok then
            if jpg_path ~= path then pcall(os.remove, path) end
            rewrote = jpg_path
        end
    end)
    if ok and rewrote then return rewrote end
    return false
end

-- Search, then download each candidate thumbnail into tmp_dir so the picker can
-- render local files with no per-page network. Returns a list of
-- { local_thumb=<path|nil>, full=<url>, title=<str> }, source, err.
-- Designed to be the body of a Trapper:dismissableRunInSubprocess call.
function ImageSearch.searchAndFetchThumbs(query, tavily_key, tmp_dir)
    local results, source, err = ImageSearch.doSearch(query, tavily_key)
    if not results then return nil, source, err end

    -- Prune leftovers from a previous search so old extensions do not pile up.
    if tmp_dir then _clearDir(tmp_dir) end

    local out = {}
    for i, r in ipairs(results) do
        if i > MAX_RESULTS then break end
        local entry = { full = r.full, title = r.title or "" }
        if tmp_dir and r.thumb then
            local ext = ImageSearch.extFromUrl(r.thumb)
            local thumb_path = tmp_dir .. "/thumb_" .. i .. "." .. ext
            local ok = ImageSearch.httpGetToFile(r.thumb, thumb_path, 15)
            if ok then
                -- When the provider has no separate thumbnail (thumb URL equals
                -- the full URL, e.g. Tavily), the downloaded "thumbnail" is a
                -- full-size image. Shrink it here in the subprocess so the picker
                -- does not decode a large file on the UI thread each tap.
                if r.thumb == r.full then
                    local shrunk = ImageSearch.shrinkPreviewFile(thumb_path)
                    if shrunk then thumb_path = shrunk end
                end
                entry.local_thumb = thumb_path
            end
        end
        out[#out + 1] = entry
    end
    return out, source
end

-- Download the chosen full image to dest_path. Returns true or nil, err.
function ImageSearch.download(url, dest_path)
    return ImageSearch.httpGetToFile(url, dest_path, 45)
end

-- Decode the stored image once and produce the on-device variants:
--   * a small card thumbnail ("<base>.thumb.jpg"), always;
--   * the display image, downscaled to DISPLAY_MAX_EDGE when it is larger
--     (kept as the original bytes when already small), only if cap_display.
-- The card decodes the tiny thumbnail; the full-screen viewer keeps the display
-- image. Runs on the UI thread at attach (a one-time cost; the caller shows a
-- spinner around it) and lazy migration; it needs KOReader's renderer, so it is
-- not part of a unit-tested pure path. Returns display_path, thumb_path, or nil,
-- err on any failure.
-- display_path may change extension to .jpg when the image was downscaled.
function ImageSearch.makeVariants(image_path, thumb_edge, cap_display)
    if cap_display == nil then cap_display = true end
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not ok_ri or not RenderImage then return nil, "no renderer" end
    local ok_bb, Blitbuffer = pcall(require, "ffi/blitbuffer")
    if not ok_bb or not Blitbuffer then return nil, "no blitbuffer" end

    thumb_edge = math.max(THUMB_MIN_EDGE, tonumber(thumb_edge) or THUMB_MIN_EDGE)
    local display_path = image_path
    local thumb_path = ImageSearch.thumbPathFor(image_path)
    local thumb_ok = false

    local ok, err = pcall(function()
        local native = RenderImage:renderImageFile(image_path, false)
        if not native then error("decode failed") end
        local nw, nh = native:getWidth(), native:getHeight()
        local longest = math.max(nw or 0, nh or 0)
        if longest <= 0 then native:free(); error("bad dimensions") end

        -- Flatten transparency onto white. A transparent PNG (e.g. a logo)
        -- otherwise bakes a black background into the opaque JPEG output, and
        -- the source cannot be kept as-is because the viewer shows the same
        -- black. So when the source has alpha, always re-encode to JPEG below.
        local bbtype = native:getType()
        local has_alpha = (bbtype == Blitbuffer.TYPE_BB8A
            or bbtype == Blitbuffer.TYPE_BBRGB32)
        local src = native
        if has_alpha then
            local flat = Blitbuffer.new(nw, nh, Blitbuffer.TYPE_BBRGB32)
            flat:fill(Blitbuffer.COLOR_WHITE)
            flat:pmulalphablitFrom(native, 0, 0, 0, 0, nw, nh)
            native:free()
            src = flat
        end
        local function freeIfScaled(bb)
            if bb ~= src then bb:free() end
        end

        -- Display image: downscale when larger than the cap. Keep the original
        -- bytes when it is already small AND opaque (no re-encode quality loss);
        -- a flattened (previously transparent) image is always re-encoded so it
        -- is opaque on disk.
        if cap_display and (longest > DISPLAY_MAX_EDGE or has_alpha) then
            local s = math.min(1, DISPLAY_MAX_EDGE / longest)
            local dbb = RenderImage:scaleBlitBuffer(src, math.floor(nw * s), math.floor(nh * s), false)
            local new_path = _swapExt(image_path, "jpg")
            local dok = dbb:writeToFile(new_path, "jpg", JPEG_QUALITY)
            freeIfScaled(dbb)
            if dok then
                if new_path ~= image_path then pcall(os.remove, image_path) end
                display_path = new_path
            else
                pcall(os.remove, new_path)   -- drop any partial write; keep original
            end
        end

        -- Card thumbnail: never upscale (cap the factor at 1).
        local ts = math.min(1, thumb_edge / longest)
        local tbb = RenderImage:scaleBlitBuffer(src, math.floor(nw * ts), math.floor(nh * ts), false)
        thumb_ok = tbb:writeToFile(thumb_path, "jpg", JPEG_QUALITY) and true or false
        freeIfScaled(tbb)

        src:free()
    end)

    if not ok then return nil, tostring(err) end
    if not thumb_ok then thumb_path = nil end
    return display_path, thumb_path
end

ImageSearch.MAX_RESULTS = MAX_RESULTS
ImageSearch.DISPLAY_MAX_EDGE = DISPLAY_MAX_EDGE
ImageSearch.THUMB_MIN_EDGE = THUMB_MIN_EDGE
ImageSearch.PREVIEW_MAX_EDGE = PREVIEW_MAX_EDGE

return ImageSearch
