--[[
X-Ray Image Search

Searches the web for an image of an X-Ray entity (character, location,
historical figure, glossary term) and downloads the chosen image into the
book's ".sdr" sidecar so it travels with the book.

Every provider needs a key. By default ("auto") they are tried in this fixed
order, skipping any whose key is empty; the search fails if none has a key:

  1. SerpApi         serpapi_api_key  -- Google Images Light engine.
  2. Brave Search    brave_api_key    -- Brave image index.
  3. Tavily          tavily_api_key   -- web search with include_images.

The user can pick one provider in the Image Search settings. The pick moves
that provider to the front of the order; the others keep their place behind it
as fallbacks (see providerOrder), so a broken key still yields an image and the
UI can say which provider really answered.

The first provider that returns at least one image wins. SerpApi and Brave
each return a small thumbnail URL that is separate from the full-size image,
so the picker downloads only thumbnails. Tavily returns one URL per image, so
its "thumbnail" is a full-size file that must be shrunk on the device; that is
why it sits below the other two.

No provider caption is kept. The picker shows only the position and the source
name, so parsers return image URLs and nothing else.

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

-- Per-provider result caps. The picker is a one-at-a-time carousel with
-- Previous/Next. Thumbnails are downloaded THUMB_PAGE at a time (the first page
-- with the search, later pages when the user asks for more), so a longer list
-- costs nothing before the picker opens. Tavily is capped lower: it charges
-- credits per search, returns no separate thumbnail, and every image it gives
-- back must be downloaded at full size and shrunk.
local MAX_RESULTS_SERPAPI = 15
local MAX_RESULTS_BRAVE   = 15
local MAX_RESULTS_TAVILY  = 5

-- Picker cap. The largest provider cap; each provider list is already cut to
-- its own cap, so this only backstops a provider that ignores the limit.
local MAX_RESULTS = math.max(MAX_RESULTS_SERPAPI, MAX_RESULTS_BRAVE, MAX_RESULTS_TAVILY)

-- Thumbnails downloaded per page. Five small downloads is the wait before the
-- picker opens on a 2012 Kindle; each later page is one more cancellable wait
-- that the user chose by tapping "Show more images".
local THUMB_PAGE = 5

-- Extra entries to request from a provider that honours a result count, to
-- cover the ones the parser discards for having no usable http(s) image URL.
local BRAVE_COUNT_HEADROOM = 2

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

-- Accept only an http(s) URL. A provider can put a "data:" URI, a relative
-- path, or an empty string where an image URL is expected; the downloader
-- speaks HTTP only, so anything else must be discarded, not stored.
local function _httpUrl(v)
    if type(v) ~= "string" then return nil end
    if v:match("^https?://") then return v end
    return nil
end

-- ---------------------------------------------------------------------------
-- Provider: SerpApi (Google Images Light)
-- ---------------------------------------------------------------------------

-- SerpApi endpoint. One GET; the key travels in the query string, so there is
-- no auth header. Never log this URL -- it carries the key.
ImageSearch.SERPAPI_URL = "https://serpapi.com/search"

-- Build the SerpApi request URL. "google_images_light" is SerpApi's fast
-- Google Images engine: the same JSON shape as "google_images" but without the
-- extra-rich blocks.
-- NOTE: SerpApi has no parameter that asks for fewer results (pagination is
-- `start`, an offset with no per-page count), so one request always returns a
-- long list and a large body. json.decode still builds the whole ~100-entry table, so the cost
-- of the large body is paid; parseSerpApi's MAX_RESULTS stop only avoids
-- copying the entries the picker will never show. This all runs inside the
-- dismissable search subprocess, so it costs latency, not a UI freeze.
function ImageSearch.buildSerpApiUrl(query, api_key)
    return ImageSearch.SERPAPI_URL
        .. "?engine=google_images_light"
        .. "&q=" .. ImageSearch.urlencode(query)
        .. "&api_key=" .. ImageSearch.urlencode(api_key)
end

-- Parse a SerpApi Google Images response body. Each `images_results` entry has
-- a small `thumbnail` (and a SerpApi-cached `serpapi_thumbnail`) that is
-- separate from the full-size `original`, so the picker never downloads a
-- full-size file. Captions are not kept.
-- Returns a list of { full=<url>, thumb=<url> } or nil, err.
function ImageSearch.parseSerpApi(body)
    if not json_ok then return nil, "json module unavailable" end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then return nil, "parse error" end
    local detail = ImageSearch._errorDetailFromData(data)
    if detail then
        -- SerpApi answers a query with no images as HTTP 200 plus an `error`
        -- string ("Google hasn't returned any results for this query.") and no
        -- images_results key. That is an empty search, not a provider failure:
        -- reporting it as one would burn a call on the next provider and show
        -- "Search failed" instead of "No images found".
        local meta = data.search_metadata
        local succeeded = type(meta) == "table" and meta.status == "Success"
        if succeeded or detail:lower():find("hasn.t returned any results") then
            return {}
        end
        return nil, detail
    end
    -- A genuine empty search still returns an "images_results" array. A missing
    -- key means SerpApi changed its response shape; report that as a provider
    -- error so the picker does not show it as "no images".
    if type(data.images_results) ~= "table" then
        return nil, "unexpected SerpApi response"
    end
    local out = {}
    for _, item in ipairs(data.images_results) do
        if type(item) == "table" then
            local full = _httpUrl(item.original)
            if full then
                out[#out + 1] = {
                    full  = full,
                    thumb = _httpUrl(item.thumbnail) or _httpUrl(item.serpapi_thumbnail) or full,
                }
                -- SerpApi sends ~100 entries, so stop at the provider cap
                -- instead of building a table that is thrown away.
                if #out >= MAX_RESULTS_SERPAPI then break end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Provider: Brave Image Search
-- ---------------------------------------------------------------------------

-- Brave endpoint. One GET with an X-Subscription-Token header.
ImageSearch.BRAVE_URL = "https://api.search.brave.com/res/v1/images/search"

-- Build the Brave request URL. Brave accepts `count`, so keep the response body
-- small -- this matters on slow e-ink hardware. Ask for a little more than the
-- picker shows: parseBrave discards any entry with no http(s) image URL, so an
-- exact count can leave the picker short.
-- Safe search is left at Brave's default ("strict"). Add "&safesearch=off" here
-- if strict filtering hides too many legitimate results.
function ImageSearch.buildBraveUrl(query, count)
    return ImageSearch.BRAVE_URL
        .. "?q=" .. ImageSearch.urlencode(query)
        .. "&count=" .. tostring(count or (MAX_RESULTS_BRAVE + BRAVE_COUNT_HEADROOM))
end

-- Parse a Brave Image Search response body. Each `results` entry carries a
-- proxied `thumbnail.src` (resized to 500 px wide) that is separate from the
-- full-size `properties.url`, so the picker never downloads a full-size file.
-- Note: the entry's own `url` is the SOURCE PAGE, not an image. Never use it.
-- Captions are not kept.
-- Returns a list of { full=<url>, thumb=<url> } or nil, err.
function ImageSearch.parseBrave(body)
    if not json_ok then return nil, "json module unavailable" end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then return nil, "parse error" end
    local detail = ImageSearch._errorDetailFromData(data)
    if detail then return nil, detail end
    if type(data.results) ~= "table" then
        return nil, "unexpected Brave response"
    end
    local out = {}
    for _, item in ipairs(data.results) do
        if type(item) == "table" then
            local props = (type(item.properties) == "table") and item.properties or {}
            local thumb_obj = (type(item.thumbnail) == "table") and item.thumbnail or {}
            local thumb = _httpUrl(thumb_obj.src)
            -- Prefer the original; a proxied 500 px thumbnail is still usable
            -- as the stored image when Brave gives no original.
            local full = _httpUrl(props.url) or thumb
            if full then
                out[#out + 1] = {
                    full  = full,
                    thumb = thumb or full,
                }
                -- Brave is asked for `count` results, but do not depend on it
                -- honouring the request; stop at the provider cap.
                if #out >= MAX_RESULTS_BRAVE then break end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Provider: Tavily
-- ---------------------------------------------------------------------------

-- Tavily Search API endpoint. A single POST with a Bearer token; asking for
-- images returns a top-level `images` list of query-related image URLs.
ImageSearch.TAVILY_URL = "https://api.tavily.com/search"

-- Tavily depth. "fast" and "basic" both cost 1 credit, but Tavily documents
-- "fast" as lower latency. Tavily is the slowest provider here, so use "fast".
-- Image descriptions are also off in buildTavilyBody: they run a captioner over
-- every image, and the picker shows no captions.
local TAVILY_SEARCH_DEPTH = "fast"

-- Build the JSON request body for a Tavily image search.
function ImageSearch.buildTavilyBody(query, num)
    if not json_ok then return nil end
    return json.encode({
        query = tostring(query or ""),
        search_depth = TAVILY_SEARCH_DEPTH,
        include_images = true,
        include_image_descriptions = false,
        max_results = num or MAX_RESULTS_TAVILY,
    })
end

-- Parse a Tavily response body. The `images` field is a list of URL strings.
-- Tavily can also send { url, description } objects when descriptions are
-- asked for; that shape is still accepted, but the description is discarded.
-- Returns a list of { full=<url>, thumb=<url> } or nil, err.
function ImageSearch.parseTavily(body)
    if not json_ok then return nil, "json module unavailable" end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then return nil, "parse error" end
    local detail = ImageSearch._errorDetailFromData(data)
    if detail then return nil, detail end
    local out = {}
    for _, item in ipairs(data.images or {}) do
        local url
        if type(item) == "string" then
            url = _httpUrl(item)
        elseif type(item) == "table" then
            url = _httpUrl(item.url)
        end
        if url then
            -- Tavily gives one URL per image (no separate thumbnail), so the
            -- same URL serves both the preview and the full download.
            out[#out + 1] = { full = url, thumb = url }
            -- `max_results` bounds Tavily's search hits, not the image list it
            -- derives from them, so cap the list here as well.
            if #out >= MAX_RESULTS_TAVILY then break end
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

-- A browser-like User-Agent, used only when downloading an image file. Many
-- image hosts (fan wikis, CDNs) hotlink-block non-browser agents on download.
local BROWSER_UA =
    "Mozilla/5.0 (X11; Linux x86_64; rv:115.0) Gecko/20100101 Firefox/115.0"

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
--   Brave-style  : { "error": { "detail": "...", "code": "..." } } (sent with
--                  HTTP 422, not 401, for a bad subscription token)
--   Tavily-style : { "detail": "..." } or { "detail": { "error": "..." } }
--   SerpApi-style: a top-level { "error": "..." } string.
-- Returns a trimmed string or nil when the body carries no error message.
-- Takes an ALREADY-DECODED table. The parsers decode the body once and call
-- this, so a large SerpApi body is never decoded twice.
function ImageSearch._errorDetailFromData(data)
    if type(data) ~= "table" then return nil end
    local msg
    if type(data.error) == "table" then
        msg = data.error.message or data.error.detail
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

-- Body-level wrapper for callers that hold a raw response string (the HTTP
-- helpers, which never decode it themselves).
function ImageSearch._errorDetail(body)
    if type(body) ~= "string" or #body == 0 or not json_ok then return nil end
    local ok, data = pcall(json.decode, body)
    if not ok then return nil end
    return ImageSearch._errorDetailFromData(data)
end

-- GET a URL and return the body, or nil plus an error string.
-- follow_redirect defaults to true. Pass false when the URL itself is a secret:
-- luasocket replays the WHOLE url (query string included) to the redirect
-- target, and an https -> http redirect would send it in cleartext.
function ImageSearch.httpGetString(url, timeout, extra_headers, follow_redirect)
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
        redirect = (follow_redirect ~= false),
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

-- Per-provider request timeout, in seconds. The first (highest-priority)
-- provider gets the full budget; a later one in the chain gets less, so two
-- hung providers cannot hold the reader for minutes before the third is tried.
-- A provider marked `slow` in PROVIDERS keeps the full budget wherever it sits
-- in the chain, because the short budget would time out a working key.
-- socketutil doubles each value for the total timeout.
ImageSearch.TIMEOUT_FIRST = 20
ImageSearch.TIMEOUT_NEXT  = 10

-- SerpApi provider: one GET, key in the query string. Returns results or nil, err.
-- Redirects are NOT followed here: the URL carries the key, and luasocket would
-- replay it in full to whatever host the redirect names. SerpApi answers
-- /search directly, so nothing is lost.
function ImageSearch.searchSerpApi(query, api_key, timeout)
    local resp, err = ImageSearch.httpGetString(
        ImageSearch.buildSerpApiUrl(query, api_key), timeout or ImageSearch.TIMEOUT_FIRST,
        nil, false)
    if not resp then return nil, err end
    return ImageSearch.parseSerpApi(resp)
end

-- Brave provider: one GET with a subscription-token header. Returns results
-- or nil, err.
-- Redirects are NOT followed here, for the same reason as SerpApi: luasocket
-- rebuilds the request with the original headers, so an off-host redirect would
-- receive the subscription token. Brave answers the endpoint directly.
function ImageSearch.searchBrave(query, api_key, timeout)
    local resp, err = ImageSearch.httpGetString(
        ImageSearch.buildBraveUrl(query), timeout or ImageSearch.TIMEOUT_FIRST, {
        ["X-Subscription-Token"] = tostring(api_key),
        ["Accept"]               = "application/json",
    }, false)
    if not resp then return nil, err end
    return ImageSearch.parseBrave(resp)
end

-- Tavily provider: one POST with a Bearer token. Returns results or nil, err.
function ImageSearch.searchTavily(query, api_key, timeout)
    local body = ImageSearch.buildTavilyBody(query)
    if not body then return nil, "json module unavailable" end
    local resp, err = ImageSearch.httpPostString(ImageSearch.TAVILY_URL, body, {
        ["Authorization"] = "Bearer " .. tostring(api_key),
    }, timeout or ImageSearch.TIMEOUT_FIRST)
    if not resp then return nil, err end
    return ImageSearch.parseTavily(resp)
end

-- Keyed providers, in the order they are tried. This table is the ONLY list of
-- providers: xray_ui builds both its keys table and its settings submenu from
-- it, so the two files cannot drift on order, names, or config fields.
--   name         picker/source label used across the UI, and the field name
--                in the keys table doSearch is given
--   config_field key name in xray_config.lua / on the AI helper
--   loc_key      .po key for the settings row title. The UI reads it as
--                loc:t(p.loc_key); tools/sync_translations.py reads the key
--                straight from this field, and takes its English text from
--                the hardcoded fallbacks table in localization_xray.lua, so
--                keep that table entry too.
--   brand        English label fallback when the .po key is missing
--   search       dispatches through ImageSearch at call time, so the test suite
--                can replace an individual provider function
--   slow         when set, the provider always gets TIMEOUT_FIRST, even as a
--                fallback (Tavily runs a web search plus image extraction, so
--                the shorter fallback budget reads a working key as a timeout)
ImageSearch.PROVIDERS = {
    {
        name = "serpapi", brand = "SerpApi",
        config_field = "serpapi_api_key", loc_key = "img_key_serpapi",
        search = function(q, k, t) return ImageSearch.searchSerpApi(q, k, t) end,
    },
    {
        name = "brave", brand = "Brave Search",
        config_field = "brave_api_key", loc_key = "img_key_brave",
        search = function(q, k, t) return ImageSearch.searchBrave(q, k, t) end,
    },
    {
        name = "tavily", brand = "Tavily",
        config_field = "tavily_api_key", loc_key = "img_key_tavily",
        slow = true,
        search = function(q, k, t) return ImageSearch.searchTavily(q, k, t) end,
    },
}

-- Human-readable name for a source string, for the picker label and the
-- fallback notice. Returns nil for an unknown source.
function ImageSearch.brandFor(source)
    for _, p in ipairs(ImageSearch.PROVIDERS) do
        if p.name == source then return p.brand end
    end
    return nil
end

-- Setting value that means "no pick: use PROVIDERS order as it is".
ImageSearch.AUTO_PROVIDER = "auto"

-- True when `name` is the name of a provider in PROVIDERS.
function ImageSearch.isProviderName(name)
    if type(name) ~= "string" then return false end
    for _, p in ipairs(ImageSearch.PROVIDERS) do
        if p.name == name then return true end
    end
    return false
end

-- Providers in the order a search tries them. `preferred` is the user's pick
-- from the settings: a provider name moves that provider to the front and
-- leaves the rest in PROVIDERS order behind it. "auto", nil, or an unknown
-- name (a provider removed in an update) leaves PROVIDERS order untouched, so
-- a stale setting can never turn image search off.
function ImageSearch.providerOrder(preferred)
    local order = {}
    if ImageSearch.isProviderName(preferred) then
        for _, p in ipairs(ImageSearch.PROVIDERS) do
            if p.name == preferred then order[1] = p end
        end
    end
    for _, p in ipairs(ImageSearch.PROVIDERS) do
        if p.name ~= preferred then order[#order + 1] = p end
    end
    return order
end

-- Name of the first provider in providerOrder(preferred) that has a key, or
-- nil when none has one. The caller uses this to tell whether the search fell
-- back. A nil or malformed `keys` reads as "no keys". A picked provider with
-- no key is skipped the same as under "auto", so the next keyed one is
-- returned; the settings card marks such a pick "(no key)".
function ImageSearch.preferredProvider(keys, preferred)
    if type(keys) ~= "table" then keys = {} end
    for _, p in ipairs(ImageSearch.providerOrder(preferred)) do
        local k = keys[p.name]
        if type(k) == "string" and #k > 0 then return p.name end
    end
    return nil
end

-- Error returned when the user has configured no image-search key at all.
-- The UI checks for this case up front, so it should be rare.
ImageSearch.ERR_NO_KEY = "no image search key configured"

-- Run the search. Try each keyed provider in providerOrder(preferred) and take
-- the first one that returns at least one image. Every provider needs a key,
-- so a setup with no keys cannot search at all.
--
-- Returns results, source, err. Two "nothing to show" cases are kept apart:
--   * a provider ANSWERED with no image -> an empty list plus its name, no err,
--     so the caller can show its own localized "no images found" text;
--   * a provider FAILED -> nil plus the error, which the caller reports.
function ImageSearch.doSearch(query, keys, preferred)
    -- The keys table is { serpapi=, brave=, tavily= }; nil or malformed reads
    -- as "no keys".
    if type(keys) ~= "table" then keys = {} end

    -- Keep the outcome of the FIRST provider that came up short. It names the
    -- highest-priority provider the user actually configured, which is the
    -- useful thing to report when every provider comes up empty.
    local first_source, first_err, first_was_empty
    -- Also keep the LAST failure seen. When the top provider answers empty and
    -- a lower one then fails (bad key, quota exhausted), reporting only the
    -- empty answer would hide the broken key behind "No images found."
    local last_err, last_err_source
    local tried = 0
    for _, p in ipairs(ImageSearch.providerOrder(preferred)) do
        local api_key = keys[p.name]
        if type(api_key) == "string" and #api_key > 0 then
            tried = tried + 1
            -- Only the first provider gets the full timeout; later ones in the
            -- chain get less, so a hung chain cannot run for minutes. A `slow`
            -- provider is the exception -- see TIMEOUT_NEXT above.
            local timeout = (tried == 1 or p.slow)
                and ImageSearch.TIMEOUT_FIRST or ImageSearch.TIMEOUT_NEXT
            local results, err = p.search(query, api_key, timeout)
            if results and #results > 0 then return results, p.name end
            if type(results) ~= "table" then
                last_err = err or "provider returned no data"
                last_err_source = p.name
            end
            if not first_source then
                first_source = p.name
                if type(results) == "table" then
                    first_was_empty = true
                else
                    first_err = last_err
                end
            end
        end
    end

    if tried == 0 then return nil, nil, ImageSearch.ERR_NO_KEY end
    if first_was_empty then
        -- The top provider answered with no image, but a lower one FAILED.
        -- Report the failure: a broken key must not read as "no images found".
        if last_err then return nil, last_err_source, last_err end
        return {}, first_source
    end
    return nil, first_source, first_err
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

-- Download one candidate thumbnail into tmp_dir. Returns the local path, or
-- nil when there is no thumbnail URL, no tmp_dir, or the download failed.
local function _fetchThumb(r, i, tmp_dir)
    if not (tmp_dir and r and r.thumb) then return nil end
    local ext = ImageSearch.extFromUrl(r.thumb)
    local thumb_path = tmp_dir .. "/thumb_" .. i .. "." .. ext
    if not ImageSearch.httpGetToFile(r.thumb, thumb_path, 15) then return nil end
    -- When the provider has no separate thumbnail (thumb URL equals the full
    -- URL, e.g. Tavily), the downloaded "thumbnail" is a full-size image.
    -- Shrink it here in the subprocess so the picker does not decode a large
    -- file on the UI thread each tap. SerpApi and Brave give a real thumbnail,
    -- so they skip this decode entirely.
    if r.thumb == r.full then
        local shrunk = ImageSearch.shrinkPreviewFile(thumb_path)
        if shrunk then thumb_path = shrunk end
    end
    return thumb_path
end

-- Download the thumbnails for results[first..last] into tmp_dir. Returns
-- { [index] = <local path> } holding only the downloads that succeeded. It
-- does not write into `results`: this runs in a subprocess, and the parent
-- never sees a child's mutations, only what it returns.
-- Designed to be the body of a Trapper:dismissableRunInSubprocess call.
function ImageSearch.fetchThumbPage(results, first, last, tmp_dir)
    local paths = {}
    for i = first, math.min(last, #results) do
        local p = _fetchThumb(results[i], i, tmp_dir)
        if p then paths[i] = p end
    end
    return paths
end

-- Search, then download the first page of candidate thumbnails into tmp_dir so
-- the picker can render local files with no per-page network. `keys` is the
-- keys table taken by doSearch. Returns a list of
-- { local_thumb=<path|nil>, thumb=<url|nil>, full=<url> }, source, err.
-- Entries past THUMB_PAGE keep their thumb URL for a later fetchThumbPage call.
-- `preferred` is the provider pick from the settings; see providerOrder.
-- Designed to be the body of a Trapper:dismissableRunInSubprocess call.
function ImageSearch.searchAndFetchThumbs(query, keys, tmp_dir, preferred)
    local results, source, err = ImageSearch.doSearch(query, keys, preferred)
    if not results then return nil, source, err end

    -- Prune leftovers from a previous search so old extensions do not pile up.
    if tmp_dir then _clearDir(tmp_dir) end

    local out = {}
    for i, r in ipairs(results) do
        if i > MAX_RESULTS then break end
        out[i] = { full = r.full, thumb = r.thumb }
    end
    local paths = ImageSearch.fetchThumbPage(out, 1, THUMB_PAGE, tmp_dir)
    for i, p in pairs(paths) do out[i].local_thumb = p end
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
ImageSearch.THUMB_PAGE = THUMB_PAGE
ImageSearch.MAX_RESULTS_SERPAPI = MAX_RESULTS_SERPAPI
ImageSearch.MAX_RESULTS_BRAVE = MAX_RESULTS_BRAVE
ImageSearch.MAX_RESULTS_TAVILY = MAX_RESULTS_TAVILY
ImageSearch.BRAVE_COUNT_HEADROOM = BRAVE_COUNT_HEADROOM
ImageSearch.DISPLAY_MAX_EDGE = DISPLAY_MAX_EDGE
ImageSearch.THUMB_MIN_EDGE = THUMB_MIN_EDGE
ImageSearch.PREVIEW_MAX_EDGE = PREVIEW_MAX_EDGE

return ImageSearch
