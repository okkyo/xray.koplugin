-- xray_imagesearch_spec.lua
require("spec/spec_helper")

-- The module tries require("json") / require("rapidjson"); in this test env only
-- dkjson is installed, so provide it under the "json" name before loading.
package.loaded["json"] = require("dkjson")

describe("xray_imagesearch", function()
    local ImageSearch

    setup(function()
        ImageSearch = require("xray_imagesearch")
    end)

    describe("urlencode", function()
        it("percent-encodes spaces and reserved characters", function()
            assert.are.equal("Katniss%20Everdeen", ImageSearch.urlencode("Katniss Everdeen"))
            assert.are.equal("a%26b%3Dc", ImageSearch.urlencode("a&b=c"))
        end)

        it("leaves unreserved characters untouched", function()
            assert.are.equal("Abc-1_2.3~", ImageSearch.urlencode("Abc-1_2.3~"))
        end)
    end)

    describe("slugify", function()
        it("lowercases and replaces non-word runs with underscores", function()
            assert.are.equal("katniss_everdeen", ImageSearch.slugify("Katniss Everdeen"))
            assert.are.equal("st_john_s_wood", ImageSearch.slugify("St. John's Wood"))
        end)

        it("falls back to 'entity' for empty input", function()
            assert.are.equal("entity", ImageSearch.slugify(""))
            assert.are.equal("entity", ImageSearch.slugify(nil))
        end)

        it("caps the length at 40 characters", function()
            local long = string.rep("a", 100)
            assert.is_true(#ImageSearch.slugify(long) <= 40)
        end)
    end)

    describe("extFromUrl", function()
        it("extracts a known image extension", function()
            assert.are.equal("jpg", ImageSearch.extFromUrl("https://x.com/a/b.jpg"))
            assert.are.equal("png", ImageSearch.extFromUrl("https://x.com/a/b.PNG"))
        end)

        it("ignores query strings and fragments", function()
            assert.are.equal("png", ImageSearch.extFromUrl("https://x.com/pic.png?width=200"))
            assert.are.equal("gif", ImageSearch.extFromUrl("https://x.com/pic.gif#frag"))
        end)

        it("defaults to jpg for unknown or missing extensions", function()
            assert.are.equal("jpg", ImageSearch.extFromUrl("https://x.com/image"))
            assert.are.equal("jpg", ImageSearch.extFromUrl("https://x.com/a.aspx"))
            assert.are.equal("jpg", ImageSearch.extFromUrl(nil))
        end)
    end)

    describe("buildTavilyBody", function()
        local dk = require("dkjson")
        -- Descriptions are off and the depth is "fast": both cut the latency
        -- that made Tavily the slowest provider. See xray_imagesearch.
        it("requests images for the query at the low-latency depth", function()
            local body = ImageSearch.buildTavilyBody("Peeta Mellark", 6)
            local data = dk.decode(body)
            assert.are.equal("Peeta Mellark", data.query)
            assert.is_true(data.include_images)
            assert.is_false(data.include_image_descriptions)
            assert.are.equal(6, data.max_results)
            assert.are.equal("fast", data.search_depth)    -- 1-credit search
        end)

        -- Tavily charges per search and sends no separate thumbnail, so its
        -- default cap is lower than the other providers'.
        it("defaults to the Tavily result cap", function()
            local data = dk.decode(ImageSearch.buildTavilyBody("Katniss"))
            assert.are.equal(ImageSearch.MAX_RESULTS_TAVILY, data.max_results)
        end)
    end)

    describe("parseTavily", function()
        it("parses an images list of {url, description} objects, ignoring the description", function()
            local body = [[{"images":[
                {"url":"https://x.com/a.jpg","description":"Peeta"},
                {"url":"https://x.com/b.png","description":"Peeta 2"}
            ]}]]
            local results = ImageSearch.parseTavily(body)
            assert.are.equal(2, #results)
            assert.are.equal("https://x.com/a.jpg", results[1].full)
            assert.are.equal("https://x.com/a.jpg", results[1].thumb)   -- same URL
            assert.is_nil(results[1].title)   -- captions are not kept
        end)

        it("parses an images list of plain URL strings", function()
            local body = [[{"images":["https://x.com/c.jpg","https://x.com/d.jpg"]}]]
            local results = ImageSearch.parseTavily(body)
            assert.are.equal(2, #results)
            assert.are.equal("https://x.com/c.jpg", results[1].full)
            assert.are.equal("https://x.com/c.jpg", results[1].thumb)
            assert.is_nil(results[1].title)
        end)

        it("surfaces an API error message (Tavily 'detail' shape)", function()
            local body = [[{"detail":"Unauthorized: missing or invalid API key."}]]
            local results, err = ImageSearch.parseTavily(body)
            assert.is_nil(results)
            assert.are.equal("Unauthorized: missing or invalid API key.", err)
        end)

        -- The downloader speaks HTTP only, so a data: URI or a relative path
        -- must be dropped, not stored as a candidate with no preview.
        it("drops an image entry whose URL is not http(s)", function()
            local body = [[{"images":[
                "data:image/png;base64,AAAA",
                "/relative/e.jpg",
                "https://x.com/f.jpg"
            ]}]]
            local results = ImageSearch.parseTavily(body)
            assert.are.equal(1, #results)
            assert.are.equal("https://x.com/f.jpg", results[1].full)
        end)

        it("returns an empty list when there are no images", function()
            local results = ImageSearch.parseTavily([[{"results":[]}]])
            assert.are.equal(0, #results)
        end)

        it("returns nil on malformed JSON", function()
            local results, err = ImageSearch.parseTavily("not json")
            assert.is_nil(results)
            assert.is_truthy(err)
        end)
    end)

    describe("_errorDetail", function()
        it("extracts the nested message from a Google-style error body", function()
            local body = [[{"error":{"code":403,"message":"Requests are blocked.","errors":[{"reason":"forbidden"}]}}]]
            assert.are.equal("Requests are blocked.", ImageSearch._errorDetail(body))
        end)
        it("extracts a Tavily 'detail' string", function()
            assert.are.equal("Invalid API key.",
                ImageSearch._errorDetail([[{"detail":"Invalid API key."}]]))
        end)
        it("extracts a nested Tavily 'detail.error' string", function()
            assert.are.equal("Quota exceeded.",
                ImageSearch._errorDetail([[{"detail":{"error":"Quota exceeded."}}]]))
        end)
        it("extracts a top-level 'error' string", function()
            assert.are.equal("Bad request.",
                ImageSearch._errorDetail([[{"error":"Bad request."}]]))
        end)
        it("returns nil for a non-error body or garbage", function()
            assert.is_nil(ImageSearch._errorDetail([[{"images":[]}]]))
            assert.is_nil(ImageSearch._errorDetail("not json"))
            assert.is_nil(ImageSearch._errorDetail(""))
        end)
    end)

    describe("buildSerpApiUrl", function()
        it("selects the light engine and carries the key in the query string", function()
            local url = ImageSearch.buildSerpApiUrl("Katniss Everdeen", "serp KEY")
            assert.is_truthy(url:find("engine=google_images_light", 1, true))
            assert.is_truthy(url:find("q=Katniss%20Everdeen", 1, true))
            assert.is_truthy(url:find("api_key=serp%20KEY", 1, true))
        end)
    end)

    describe("parseSerpApi", function()
        it("maps images_results to full plus a separate thumbnail", function()
            local body = [[{"images_results":[
                {"original":"https://h/full.jpg","thumbnail":"https://h/thumb.jpg",
                 "title":"Katniss","source":"wiki"}]}]]
            local out = ImageSearch.parseSerpApi(body)
            assert.are.equal(1, #out)
            assert.are.equal("https://h/full.jpg", out[1].full)
            assert.are.equal("https://h/thumb.jpg", out[1].thumb)
            assert.is_nil(out[1].title)   -- captions are not kept
        end)

        it("uses serpapi_thumbnail when the plain thumbnail is not an http URL", function()
            local body = [[{"images_results":[
                {"original":"https://h/full.jpg","thumbnail":"data:image/jpeg;base64,AAAA",
                 "serpapi_thumbnail":"https://serpapi.com/t.jpg"}]}]]
            local out = ImageSearch.parseSerpApi(body)
            assert.are.equal("https://serpapi.com/t.jpg", out[1].thumb)
        end)

        it("falls back to the full URL when no usable thumbnail is given", function()
            local body = [[{"images_results":[{"original":"https://h/full.jpg"}]}]]
            local out = ImageSearch.parseSerpApi(body)
            assert.are.equal("https://h/full.jpg", out[1].thumb)
        end)

        it("skips entries whose original is missing or not http", function()
            local body = [[{"images_results":[
                {"thumbnail":"https://h/t.jpg"},
                {"original":"data:image/png;base64,AAAA"},
                {"original":"https://h/ok.jpg"}]}]]
            local out = ImageSearch.parseSerpApi(body)
            assert.are.equal(1, #out)
            assert.are.equal("https://h/ok.jpg", out[1].full)
        end)

        it("reports an API error body as an error, not as no images", function()
            local out, err = ImageSearch.parseSerpApi([[{"error":"Invalid API key."}]])
            assert.is_nil(out)
            assert.are.equal("Invalid API key.", err)
        end)

        it("treats SerpApi's 'no results' error body as an empty search", function()
            local out, err = ImageSearch.parseSerpApi(
                [[{"search_metadata":{"status":"Success"},"error":"Google hasn't returned any results for this query."}]])
            assert.is_nil(err)
            assert.are.equal(0, #out)
        end)

        it("treats the 'no results' message as empty even without a status", function()
            local out, err = ImageSearch.parseSerpApi(
                [[{"error":"Google hasn't returned any results for this query."}]])
            assert.is_nil(err)
            assert.are.equal(0, #out)
        end)

        it("still reports an error body that came with a failed status", function()
            local out, err = ImageSearch.parseSerpApi(
                [[{"search_metadata":{"status":"Error"},"error":"Invalid API key."}]])
            assert.is_nil(out)
            assert.are.equal("Invalid API key.", err)
        end)

        it("reports a missing images_results key as a provider error", function()
            local out, err = ImageSearch.parseSerpApi([[{"search_metadata":{}}]])
            assert.is_nil(out)
            assert.are.equal("unexpected SerpApi response", err)
        end)

        it("returns an empty list for a genuinely empty result set", function()
            local out = ImageSearch.parseSerpApi([[{"images_results":[]}]])
            assert.are.equal(0, #out)
        end)

        it("stops parsing at the SerpApi result cap", function()
            -- SerpApi sends ~100 entries per request; only the capped few are
            -- ever shown, so the rest must not become table entries.
            local entries = {}
            for i = 1, 40 do
                entries[i] = ([[{"original":"https://h/%d.jpg"}]]):format(i)
            end
            local body = [[{"images_results":[]] .. table.concat(entries, ",") .. [[]}]]
            local out = ImageSearch.parseSerpApi(body)
            assert.are.equal(ImageSearch.MAX_RESULTS_SERPAPI, #out)
            assert.are.equal("https://h/1.jpg", out[1].full)
        end)
    end)

    describe("parseTavily result cap", function()
        it("stops at the Tavily cap even when the images list is longer", function()
            -- `max_results` bounds Tavily's search hits, not the image list it
            -- derives from them, so the parser must cap it too.
            local urls = {}
            for i = 1, 30 do
                urls[i] = ([["https://h/%d.jpg"]]):format(i)
            end
            local body = [[{"images":[]] .. table.concat(urls, ",") .. [[]}]]
            local out = ImageSearch.parseTavily(body)
            assert.are.equal(ImageSearch.MAX_RESULTS_TAVILY, #out)
            assert.are.equal("https://h/1.jpg", out[1].full)
        end)
    end)

    describe("thumbnail paging", function()
        -- Stub the search and the download so only the paging logic runs.
        local saved_search, saved_get, fetched

        before_each(function()
            saved_search, saved_get = ImageSearch.doSearch, ImageSearch.httpGetToFile
            fetched = {}
            ImageSearch.httpGetToFile = function(url, dest)
                fetched[#fetched + 1] = url
                return true
            end
            ImageSearch.doSearch = function()
                local out = {}
                for i = 1, 12 do
                    out[i] = { full = "https://h/" .. i .. ".jpg", thumb = "https://t/" .. i .. ".jpg" }
                end
                return out, "serpapi"
            end
        end)
        after_each(function()
            ImageSearch.doSearch, ImageSearch.httpGetToFile = saved_search, saved_get
        end)

        it("downloads only the first page of thumbnails with the search", function()
            local out, source = ImageSearch.searchAndFetchThumbs("q", { serpapi = "k" }, "/tmp/x")
            assert.are.equal("serpapi", source)
            assert.are.equal(12, #out)
            assert.are.equal(ImageSearch.THUMB_PAGE, #fetched)
            assert.are.equal("https://t/1.jpg", fetched[1])
            -- First page has local files; the rest keep their URL for later.
            assert.is_truthy(out[ImageSearch.THUMB_PAGE].local_thumb)
            assert.is_nil(out[ImageSearch.THUMB_PAGE + 1].local_thumb)
            assert.are.equal("https://t/6.jpg", out[6].thumb)
            assert.are.equal("https://h/12.jpg", out[12].full)
        end)

        it("fetches a later page and stops at the end of the list", function()
            local out = ImageSearch.searchAndFetchThumbs("q", { serpapi = "k" }, "/tmp/x")
            fetched = {}
            local paths = ImageSearch.fetchThumbPage(out, 11, 15, "/tmp/x")
            assert.are.equal(2, #fetched)
            assert.are.equal("https://t/11.jpg", fetched[1])
            assert.is_truthy(paths[11])
            assert.is_truthy(paths[12])
            assert.is_nil(paths[13])
            -- The page fetch reports paths; it does not touch the list itself.
            assert.is_nil(out[11].local_thumb)
        end)

        it("leaves out entries whose download failed", function()
            ImageSearch.httpGetToFile = function(url)
                return not url:find("/7.jpg", 1, true)
            end
            local out = ImageSearch.searchAndFetchThumbs("q", { serpapi = "k" }, "/tmp/x")
            local paths = ImageSearch.fetchThumbPage(out, 6, 10, "/tmp/x")
            assert.is_truthy(paths[6])
            assert.is_nil(paths[7])
            assert.is_truthy(paths[8])
        end)
    end)

    describe("buildBraveUrl", function()
        it("asks for the picker size plus headroom for discarded entries", function()
            local url = ImageSearch.buildBraveUrl("Frodo")
            local want = ImageSearch.MAX_RESULTS + ImageSearch.BRAVE_COUNT_HEADROOM
            assert.is_truthy(url:find("q=Frodo", 1, true))
            assert.is_truthy(url:find("count=" .. tostring(want), 1, true))
        end)
    end)

    describe("parseBrave", function()
        it("takes the full image from properties and the thumbnail from thumbnail.src", function()
            local body = [[{"results":[
                {"title":"Frodo","source":"wiki","url":"https://page/frodo",
                 "thumbnail":{"src":"https://imgs.search.brave.com/t.jpg"},
                 "properties":{"url":"https://cdn/frodo.jpg",
                               "placeholder":"https://imgs.search.brave.com/p.jpg"}}]}]]
            local out = ImageSearch.parseBrave(body)
            assert.are.equal(1, #out)
            assert.are.equal("https://cdn/frodo.jpg", out[1].full)
            assert.are.equal("https://imgs.search.brave.com/t.jpg", out[1].thumb)
            assert.is_nil(out[1].title)   -- captions are not kept
        end)

        it("never treats the source page url as the image", function()
            local body = [[{"results":[
                {"url":"https://page/frodo","properties":{},"thumbnail":{}}]}]]
            local out = ImageSearch.parseBrave(body)
            assert.are.equal(0, #out)
        end)

        it("uses the proxied thumbnail as the full image when no original is given", function()
            local body = [[{"results":[
                {"thumbnail":{"src":"https://imgs.search.brave.com/t.jpg"},"properties":{}}]}]]
            local out = ImageSearch.parseBrave(body)
            assert.are.equal("https://imgs.search.brave.com/t.jpg", out[1].full)
            assert.are.equal("https://imgs.search.brave.com/t.jpg", out[1].thumb)
        end)

        it("reports a bad subscription token as an error", function()
            local body = [[{"error":{"code":"SUBSCRIPTION_TOKEN_INVALID",
                "detail":"The provided subscription token is invalid."},"type":"ErrorResponse"}]]
            local out, err = ImageSearch.parseBrave(body)
            assert.is_nil(out)
            assert.are.equal("The provided subscription token is invalid.", err)
        end)

        it("reports a missing results key as a provider error", function()
            local out, err = ImageSearch.parseBrave([[{"type":"images"}]])
            assert.is_nil(out)
            assert.are.equal("unexpected Brave response", err)
        end)
    end)

    describe("brandFor", function()
        it("names every provider it can return as a source", function()
            assert.are.equal("SerpApi", ImageSearch.brandFor("serpapi"))
            assert.are.equal("Brave Search", ImageSearch.brandFor("brave"))
            assert.are.equal("Tavily", ImageSearch.brandFor("tavily"))
            assert.is_nil(ImageSearch.brandFor("duckduckgo"))
            assert.is_nil(ImageSearch.brandFor("nope"))
        end)
    end)

    describe("preferredProvider", function()
        it("picks the highest-priority provider that has a key", function()
            assert.are.equal("serpapi", ImageSearch.preferredProvider({
                serpapi = "s", brave = "b", tavily = "t" }))
            assert.are.equal("brave", ImageSearch.preferredProvider({
                serpapi = "", brave = "b", tavily = "t" }))
            assert.are.equal("tavily", ImageSearch.preferredProvider({ tavily = "t" }))
        end)

        it("returns nil when no key is set", function()
            assert.is_nil(ImageSearch.preferredProvider({ serpapi = "", brave = "", tavily = "" }))
            assert.is_nil(ImageSearch.preferredProvider(nil))
        end)

        it("returns nil for a keys value that is not a table", function()
            assert.is_nil(ImageSearch.preferredProvider("tvly-KEY"))
        end)

        it("honours a picked provider that has a key", function()
            assert.are.equal("tavily", ImageSearch.preferredProvider({
                serpapi = "s", brave = "b", tavily = "t" }, "tavily"))
        end)

        it("skips a picked provider with no key and takes the next in fixed order", function()
            assert.are.equal("serpapi", ImageSearch.preferredProvider({
                serpapi = "s", brave = "b", tavily = "" }, "tavily"))
        end)
    end)

    describe("providerOrder", function()
        local function names(order)
            local out = {}
            for i, p in ipairs(order) do out[i] = p.name end
            return out
        end
        local FIXED = { "serpapi", "brave", "tavily" }

        it("keeps the fixed order for auto, nil, or an unknown pick", function()
            assert.are.same(FIXED, names(ImageSearch.providerOrder(ImageSearch.AUTO_PROVIDER)))
            assert.are.same(FIXED, names(ImageSearch.providerOrder(nil)))
            assert.are.same(FIXED, names(ImageSearch.providerOrder("bing")))
            assert.are.same(FIXED, names(ImageSearch.providerOrder(42)))
        end)

        it("moves the picked provider to the front and keeps the rest in order", function()
            assert.are.same({ "tavily", "serpapi", "brave" }, names(ImageSearch.providerOrder("tavily")))
            assert.are.same({ "brave", "serpapi", "tavily" }, names(ImageSearch.providerOrder("brave")))
            assert.are.same(FIXED, names(ImageSearch.providerOrder("serpapi")))
        end)

        it("returns every provider exactly once", function()
            assert.are.equal(#ImageSearch.PROVIDERS, #ImageSearch.providerOrder("brave"))
        end)

        it("knows which names are providers", function()
            assert.is_true(ImageSearch.isProviderName("brave"))
            assert.is_false(ImageSearch.isProviderName(ImageSearch.AUTO_PROVIDER))
            assert.is_false(ImageSearch.isProviderName(nil))
            assert.is_false(ImageSearch.isProviderName({}))
        end)
    end)

    describe("doSearch provider selection", function()
        -- Stub each provider function so doSearch's routing and fallback logic
        -- can be checked without real network I/O.
        local saved = {}
        local NAMES = { "searchSerpApi", "searchBrave", "searchTavily" }

        before_each(function()
            for _, n in ipairs(NAMES) do saved[n] = ImageSearch[n] end
            -- Default every provider to "must not be called", so each test has
            -- to opt in to the ones it expects to run.
            for _, n in ipairs(NAMES) do
                ImageSearch[n] = function() error("must not call " .. n) end
            end
        end)
        after_each(function()
            for _, n in ipairs(NAMES) do ImageSearch[n] = saved[n] end
        end)

        it("uses SerpApi first when every key is set", function()
            ImageSearch.searchSerpApi = function() return { { full = "s" } } end
            local results, source = ImageSearch.doSearch("q", {
                serpapi = "s-KEY", brave = "b-KEY", tavily = "tvly-KEY" })
            assert.are.equal("serpapi", source)
            assert.are.equal("s", results[1].full)
        end)

        it("skips a provider whose key is empty", function()
            ImageSearch.searchBrave = function() return { { full = "b" } } end
            local results, source = ImageSearch.doSearch("q", {
                serpapi = "", brave = "b-KEY", tavily = "tvly-KEY" })
            assert.are.equal("brave", source)
            assert.are.equal("b", results[1].full)
        end)

        it("walks the whole chain down to the last keyed provider", function()
            ImageSearch.searchSerpApi = function() return nil, "HTTP 401" end
            ImageSearch.searchBrave = function() return nil, "HTTP 422" end
            ImageSearch.searchTavily = function() return { { full = "t" } } end
            local results, source = ImageSearch.doSearch("q", {
                serpapi = "s-KEY", brave = "b-KEY", tavily = "tvly-KEY" })
            assert.are.equal("tavily", source)
            assert.are.equal("t", results[1].full)
        end)

        it("reports the top provider's error when nothing found anything", function()
            ImageSearch.searchSerpApi = function() return nil, "HTTP 401" end
            ImageSearch.searchBrave = function() return nil, "HTTP 422" end
            local results, source, err = ImageSearch.doSearch("q", {
                serpapi = "s-KEY", brave = "b-KEY" })
            assert.is_nil(results)
            assert.are.equal("serpapi", source)
            assert.are.equal("HTTP 401", err)
        end)

        it("reports an empty provider answer as an empty search, not an error", function()
            ImageSearch.searchBrave = function() return {} end
            local results, source, err = ImageSearch.doSearch("q", { brave = "b-KEY" })
            assert.are.same({}, results)
            assert.are.equal("brave", source)
            assert.is_nil(err)
        end)

        it("prefers the top provider's error over a lower provider's empty answer", function()
            ImageSearch.searchSerpApi = function() return nil, "HTTP 401" end
            ImageSearch.searchBrave = function() return {} end
            local results, source, err = ImageSearch.doSearch("q", {
                serpapi = "s-KEY", brave = "b-KEY" })
            assert.is_nil(results)
            assert.are.equal("serpapi", source)
            assert.are.equal("HTTP 401", err)
        end)

        -- A lower provider's failure must survive the top provider's empty
        -- answer, or a dead key hides behind "No images found."
        it("reports a lower provider's error even when the top one answered empty", function()
            ImageSearch.searchSerpApi = function() return {} end
            ImageSearch.searchBrave = function() return nil, "HTTP 401" end
            local results, source, err = ImageSearch.doSearch("q", {
                serpapi = "s-KEY", brave = "b-KEY" })
            assert.is_nil(results)
            assert.are.equal("brave", source)
            assert.are.equal("HTTP 401", err)
        end)

        it("gives the first provider the full timeout and later ones less", function()
            local seen = {}
            ImageSearch.searchSerpApi = function(_, _, t) seen.serpapi = t; return nil, "HTTP 401" end
            ImageSearch.searchBrave = function(_, _, t) seen.brave = t; return { { full = "b" } } end
            ImageSearch.doSearch("q", { serpapi = "s-KEY", brave = "b-KEY" })
            assert.are.equal(ImageSearch.TIMEOUT_FIRST, seen.serpapi)
            assert.are.equal(ImageSearch.TIMEOUT_NEXT, seen.brave)
        end)

        -- Tavily runs a web search plus image extraction, so the short fallback
        -- budget would read a working key as a timeout.
        it("keeps the full timeout for a slow provider used as a fallback", function()
            local seen = {}
            ImageSearch.searchSerpApi = function(_, _, t) seen.serpapi = t; return nil, "HTTP 401" end
            ImageSearch.searchTavily = function(_, _, t) seen.tavily = t; return { { full = "t" } } end
            ImageSearch.doSearch("q", { serpapi = "s-KEY", tavily = "tvly-KEY" })
            assert.are.equal(ImageSearch.TIMEOUT_FIRST, seen.serpapi)
            assert.are.equal(ImageSearch.TIMEOUT_FIRST, seen.tavily)
        end)

        it("tries the picked provider first and gives it the full timeout", function()
            local seen = {}
            ImageSearch.searchBrave = function(_, _, t)
                seen.brave = t
                return { { full = "b" } }
            end
            local results, source = ImageSearch.doSearch("q", {
                serpapi = "s-KEY", brave = "b-KEY", tavily = "tvly-KEY" }, "brave")
            assert.are.equal("brave", source)
            assert.are.equal("b", results[1].full)
            assert.are.equal(ImageSearch.TIMEOUT_FIRST, seen.brave)
        end)

        it("falls back in fixed order, with the shorter budget, when the pick fails", function()
            local seen = {}
            ImageSearch.searchBrave = function() return nil, "HTTP 401" end
            ImageSearch.searchSerpApi = function(_, _, t)
                seen.serpapi = t
                return { { full = "s" } }
            end
            local results, source, err = ImageSearch.doSearch("q", {
                serpapi = "s-KEY", brave = "b-KEY", tavily = "tvly-KEY" }, "brave")
            assert.are.equal("serpapi", source)
            assert.are.equal("s", results[1].full)
            assert.is_nil(err)
            assert.are.equal(ImageSearch.TIMEOUT_NEXT, seen.serpapi)
        end)

        it("skips a picked provider that has no key", function()
            ImageSearch.searchSerpApi = function() return { { full = "s" } } end
            local _, source = ImageSearch.doSearch("q", {
                serpapi = "s-KEY", brave = "b-KEY" }, "tavily")
            assert.are.equal("serpapi", source)
        end)

        it("uses the fixed order for auto or an unknown pick", function()
            ImageSearch.searchSerpApi = function() return { { full = "s" } } end
            local _, source = ImageSearch.doSearch("q", {
                serpapi = "s-KEY", brave = "b-KEY" }, ImageSearch.AUTO_PROVIDER)
            assert.are.equal("serpapi", source)
            _, source = ImageSearch.doSearch("q", {
                serpapi = "s-KEY", brave = "b-KEY" }, "bing")
            assert.are.equal("serpapi", source)
        end)

        it("fails with a dedicated error when no key is set at all", function()
            local results, source, err = ImageSearch.doSearch("q", {})
            assert.is_nil(results)
            assert.is_nil(source)
            assert.are.equal(ImageSearch.ERR_NO_KEY, err)
        end)

        it("fails with the no-key error when the keys value is not a table", function()
            local results, source, err = ImageSearch.doSearch("q", "tvly-KEY")
            assert.is_nil(results)
            assert.is_nil(source)
            assert.are.equal(ImageSearch.ERR_NO_KEY, err)
        end)
    end)

    describe("httpGetToFile", function()
        -- Drive the module's HTTP path with a fake request so the byte-cap and
        -- content-type guards can be exercised without real network I/O.
        local dest, fake_request, saved

        before_each(function()
            saved = {
                socket = package.loaded["socket"],
                http = package.loaded["socket/http"],
                socketutil = package.loaded["socketutil"],
                ltn12 = package.loaded["ltn12"],
            }
            package.loaded["socket"] = { skip = function(d, ...) return select(d + 1, ...) end }
            package.loaded["socket/http"] = { request = function(reqt) return fake_request(reqt) end }
            package.loaded["socketutil"] = { set_timeout = function() end, reset_timeout = function() end }
            -- The spec helper's ltn12 is empty; httpGetString needs a table sink.
            package.loaded["ltn12"] = { sink = { table = function(t)
                return function(chunk) if chunk then t[#t + 1] = chunk end; return 1 end
            end } }
            dest = os.tmpname()
        end)

        after_each(function()
            package.loaded["socket"] = saved.socket
            package.loaded["socket/http"] = saved.http
            package.loaded["socketutil"] = saved.socketutil
            package.loaded["ltn12"] = saved.ltn12
            os.remove(dest)
        end)

        it("aborts and removes the file when the body exceeds the byte cap", function()
            fake_request = function(reqt)
                -- One oversized chunk (> the 2 MB cap) in a single write.
                reqt.sink(string.rep("x", 2 * 1024 * 1024 + 1))
                return 1, 200, { ["content-type"] = "image/jpeg" }, "OK"
            end
            local ok, err = ImageSearch.httpGetToFile("http://x.com/big.jpg", dest, 5)
            assert.is_nil(ok)
            assert.are.equal("image too large", err)
            assert.is_nil(io.open(dest, "rb"))   -- file was removed
        end)

        it("rejects a non-image content-type and removes the file", function()
            fake_request = function(reqt)
                reqt.sink("<html>not an image</html>")
                reqt.sink(nil)
                return 1, 200, { ["content-type"] = "text/html; charset=utf-8" }, "OK"
            end
            local ok, err = ImageSearch.httpGetToFile("http://x.com/notimage.jpg", dest, 5)
            assert.is_nil(ok)
            assert.is_truthy(err:find("not an image", 1, true))
            assert.is_nil(io.open(dest, "rb"))
        end)

        it("keeps the file for an image body under the cap", function()
            fake_request = function(reqt)
                reqt.sink("\255\216\255fakejpeg")
                reqt.sink(nil)
                return 1, 200, { ["content-type"] = "image/jpeg" }, "OK"
            end
            local ok = ImageSearch.httpGetToFile("http://x.com/good.jpg", dest, 5)
            assert.is_true(ok)
            local fh = io.open(dest, "rb")
            assert.is_not_nil(fh)
            if fh then fh:close() end
        end)

        -- Regression: ssl.https rejects the `redirect` option with "redirect not
        -- supported", so every https request must go through socket/http (which
        -- follows redirects). This guards against reintroducing the ssl.https path.
        it("routes https URLs through socket/http and still requests redirects", function()
            local saved_ssl = package.loaded["ssl.https"]
            package.loaded["ssl.https"] = { request = function()
                error("ssl.https must not be used for image requests")
            end }
            local seen
            fake_request = function(reqt)
                seen = reqt
                reqt.sink("\255\216\255fakejpeg")
                reqt.sink(nil)
                return 1, 200, { ["content-type"] = "image/jpeg" }, "OK"
            end
            local ok = ImageSearch.httpGetToFile("https://upload.wikimedia.org/a.jpg", dest, 5)
            package.loaded["ssl.https"] = saved_ssl
            assert.is_true(ok)
            assert.is_not_nil(seen)
            assert.is_true(seen.redirect)
        end)

        -- The SerpApi URL carries the API key, and luasocket replays the whole
        -- URL to a redirect target, so that one request must not follow them.
        it("does not follow redirects for the SerpApi request", function()
            local seen
            fake_request = function(reqt)
                seen = reqt
                reqt.sink([[{"images_results":[]}]])
                return 1, 200, {}, "OK"
            end
            ImageSearch.searchSerpApi("Frodo", "s-KEY", 5)
            assert.is_not_nil(seen)
            assert.is_false(seen.redirect)
        end)

        -- The Brave request carries the key in a header, and luasocket rebuilds
        -- a redirected request with the original headers, so an off-host
        -- redirect would receive the subscription token.
        it("does not follow redirects for the Brave request", function()
            local seen
            fake_request = function(reqt)
                seen = reqt
                reqt.sink([[{"results":[]}]])
                return 1, 200, {}, "OK"
            end
            ImageSearch.searchBrave("Frodo", "b-KEY", 5)
            assert.is_not_nil(seen)
            assert.is_false(seen.redirect)
        end)

        it("follows redirects for a GET that carries no credential", function()
            local seen
            fake_request = function(reqt)
                seen = reqt
                reqt.sink("{}")
                return 1, 200, {}, "OK"
            end
            ImageSearch.httpGetString("https://example.org/a.json", 5)
            assert.is_not_nil(seen)
            assert.is_true(seen.redirect)
        end)
    end)

    describe("thumbPathFor", function()
        it("derives a .thumb.jpg path next to the image, regardless of ext", function()
            assert.are.equal("/sc/character_x_9.thumb.jpg",
                ImageSearch.thumbPathFor("/sc/character_x_9.png"))
            assert.are.equal("/sc/loc_y_1.thumb.jpg",
                ImageSearch.thumbPathFor("/sc/loc_y_1.jpeg"))
        end)

        it("returns nil for empty or missing input", function()
            assert.is_nil(ImageSearch.thumbPathFor(nil))
            assert.is_nil(ImageSearch.thumbPathFor(""))
        end)
    end)

    describe("makeVariants", function()
        -- Drive the renderer path with fake BlitBuffers so the scaling math and
        -- file writes can be checked without KOReader's real image stack.
        local writes, native_bb, saved_ri, saved_bb

        -- Fake BlitBuffer type ids mirror ffi/blitbuffer (BB8A=2, BBRGB32=5).
        -- bbtype defaults to an opaque type so most tests skip the flatten path.
        local function makeFakeBB(w, h, bbtype)
            return {
                w = w, h = h, bbtype = bbtype or 4,
                getWidth = function(self) return self.w end,
                getHeight = function(self) return self.h end,
                getType = function(self) return self.bbtype end,
                fill = function(self) end,
                pmulalphablitFrom = function(self) end,
                writeToFile = function(self, path, fmt, q)
                    writes[#writes + 1] = { path = path, fmt = fmt, w = self.w, h = self.h }
                    return true
                end,
                free = function(self) self.freed = true end,
            }
        end

        before_each(function()
            writes = {}
            native_bb = nil
            saved_ri = package.loaded["ui/renderimage"]
            saved_bb = package.loaded["ffi/blitbuffer"]
            package.loaded["ui/renderimage"] = {
                renderImageFile = function(self, path, want_frames, w, h)
                    return native_bb
                end,
                scaleBlitBuffer = function(self, bb, w, h, free_orig)
                    if bb.w == w and bb.h == h then return bb end
                    if free_orig ~= false then bb:free() end
                    return makeFakeBB(w, h)
                end,
            }
            package.loaded["ffi/blitbuffer"] = {
                TYPE_BB8A = 2, TYPE_BBRGB32 = 5, COLOR_WHITE = 0xFF,
                new = function(w, h, t) return makeFakeBB(w, h, t) end,
            }
        end)

        after_each(function()
            package.loaded["ui/renderimage"] = saved_ri
            package.loaded["ffi/blitbuffer"] = saved_bb
        end)

        it("downscales the display image and writes a thumbnail for a large source", function()
            native_bb = makeFakeBB(3200, 2400)
            local display, thumb = ImageSearch.makeVariants("/sc/character_x_1.png", 400)
            -- Extension changes to .jpg because the display image was re-encoded.
            assert.are.equal("/sc/character_x_1.jpg", display)
            assert.are.equal("/sc/character_x_1.thumb.jpg", thumb)

            local by_path = {}
            for _, w in ipairs(writes) do by_path[w.path] = w end
            -- Display capped to the 1600 px longest edge, aspect kept.
            assert.are.equal(1600, by_path["/sc/character_x_1.jpg"].w)
            assert.are.equal(1200, by_path["/sc/character_x_1.jpg"].h)
            -- Thumbnail scaled to the 400 px card edge.
            assert.are.equal(400, by_path["/sc/character_x_1.thumb.jpg"].w)
            assert.are.equal(300, by_path["/sc/character_x_1.thumb.jpg"].h)
        end)

        it("keeps the original display bytes when the source is under the cap", function()
            native_bb = makeFakeBB(800, 600)
            local display, thumb = ImageSearch.makeVariants("/sc/character_x_2.jpg", 400)
            assert.are.equal("/sc/character_x_2.jpg", display)   -- unchanged, no re-encode
            assert.are.equal("/sc/character_x_2.thumb.jpg", thumb)
            -- Only the thumbnail was written.
            assert.are.equal(1, #writes)
            assert.are.equal("/sc/character_x_2.thumb.jpg", writes[1].path)
            assert.are.equal(400, writes[1].w)
        end)

        it("never upscales the thumbnail past the source size", function()
            native_bb = makeFakeBB(200, 150)
            local _, thumb = ImageSearch.makeVariants("/sc/character_x_3.jpg", 400)
            assert.are.equal("/sc/character_x_3.thumb.jpg", thumb)
            assert.are.equal(200, writes[1].w)   -- factor capped at 1
            assert.are.equal(150, writes[1].h)
        end)

        it("leaves the display image untouched when cap_display is false", function()
            native_bb = makeFakeBB(3200, 2400)
            local display, thumb = ImageSearch.makeVariants("/sc/character_x_4.png", 400, false)
            assert.are.equal("/sc/character_x_4.png", display)   -- not re-encoded
            assert.are.equal("/sc/character_x_4.thumb.jpg", thumb)
            assert.are.equal(1, #writes)                         -- thumbnail only
        end)

        it("returns nil and an error when the image cannot be decoded", function()
            native_bb = nil   -- renderImageFile yields nothing
            local display, err = ImageSearch.makeVariants("/sc/character_x_5.jpg", 400)
            assert.is_nil(display)
            assert.is_truthy(err)
        end)

        it("flattens a transparent source onto white and re-encodes it to jpg", function()
            native_bb = makeFakeBB(800, 600, 5)   -- BBRGB32 => has alpha
            local display, thumb = ImageSearch.makeVariants("/sc/character_x_6.png", 400)
            -- Under the 1600 px cap, but an alpha source is still re-encoded so
            -- the transparent background does not bake in as black.
            assert.are.equal("/sc/character_x_6.jpg", display)
            assert.are.equal("/sc/character_x_6.thumb.jpg", thumb)
            local by_path = {}
            for _, w in ipairs(writes) do by_path[w.path] = w end
            assert.is_not_nil(by_path["/sc/character_x_6.jpg"])   -- display re-encoded
            assert.are.equal(800, by_path["/sc/character_x_6.jpg"].w)  -- not upscaled
            assert.are.equal(600, by_path["/sc/character_x_6.jpg"].h)
        end)
    end)
end)
