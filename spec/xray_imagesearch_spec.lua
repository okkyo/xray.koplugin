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
        it("requests images with descriptions for the query", function()
            local body = ImageSearch.buildTavilyBody("Peeta Mellark", 6)
            local data = dk.decode(body)
            assert.are.equal("Peeta Mellark", data.query)
            assert.is_true(data.include_images)
            assert.is_true(data.include_image_descriptions)
            assert.are.equal(6, data.max_results)
            assert.are.equal("basic", data.search_depth)   -- 1-credit search
        end)
    end)

    describe("parseTavily", function()
        it("parses an images list of {url, description} objects", function()
            local body = [[{"images":[
                {"url":"https://x.com/a.jpg","description":"Peeta"},
                {"url":"https://x.com/b.png","description":"Peeta 2"}
            ]}]]
            local results = ImageSearch.parseTavily(body)
            assert.are.equal(2, #results)
            assert.are.equal("https://x.com/a.jpg", results[1].full)
            assert.are.equal("https://x.com/a.jpg", results[1].thumb)   -- same URL
            assert.are.equal("Peeta", results[1].title)
        end)

        it("parses an images list of plain URL strings", function()
            local body = [[{"images":["https://x.com/c.jpg","https://x.com/d.jpg"]}]]
            local results = ImageSearch.parseTavily(body)
            assert.are.equal(2, #results)
            assert.are.equal("https://x.com/c.jpg", results[1].full)
            assert.are.equal("", results[1].title)
        end)

        it("surfaces an API error message (Tavily 'detail' shape)", function()
            local body = [[{"detail":"Unauthorized: missing or invalid API key."}]]
            local results, err = ImageSearch.parseTavily(body)
            assert.is_nil(results)
            assert.are.equal("Unauthorized: missing or invalid API key.", err)
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

    describe("DuckDuckGo helpers", function()
        it("builds the token page URL with the encoded query", function()
            local url = ImageSearch.buildDdgTokenUrl("Katniss Everdeen")
            assert.is_truthy(url:find("duckduckgo.com", 1, true))
            assert.is_truthy(url:find("q=Katniss%%20Everdeen"))
            assert.is_truthy(url:find("ia=images", 1, true))
        end)

        it("builds the i.js search URL with the vqd token", function()
            local url = ImageSearch.buildDdgSearchUrl("District 12", "4-123.456")
            assert.is_truthy(url:find("duckduckgo.com/i.js", 1, true))
            assert.is_truthy(url:find("o=json", 1, true))
            assert.is_truthy(url:find("q=District%%2012"))
            assert.is_truthy(url:find("vqd=4%-123%.456"))
        end)

        it("extracts the vqd token in each known shape", function()
            assert.are.equal("4-abc", ImageSearch.extractVqd([[vqd='4-abc'&foo]]))
            assert.are.equal("4-def", ImageSearch.extractVqd([[vqd="4-def"]]))
            assert.are.equal("4-ghi", ImageSearch.extractVqd([[{"vqd":"4-ghi"}]]))
            assert.are.equal("4-123", ImageSearch.extractVqd([[?q=x&vqd=4-123&p=1]]))
        end)

        it("returns nil when no vqd token is present", function()
            assert.is_nil(ImageSearch.extractVqd("no token here"))
            assert.is_nil(ImageSearch.extractVqd(nil))
        end)
    end)

    describe("parseDdg", function()
        it("maps results to full image, thumbnail and title", function()
            local body = [[{"results":[
                {"image":"https://x.com/a.jpg","thumbnail":"https://x.com/a_t.jpg","title":"Pic A"},
                {"image":"https://x.com/b.png","thumbnail":"https://x.com/b_t.png","title":"Pic B"}
            ]}]]
            local results = ImageSearch.parseDdg(body)
            assert.are.equal(2, #results)
            assert.are.equal("https://x.com/a.jpg", results[1].full)
            assert.are.equal("https://x.com/a_t.jpg", results[1].thumb)
            assert.are.equal("Pic A", results[1].title)
        end)

        it("falls back to the full image when no thumbnail is present", function()
            local body = [[{"results":[{"image":"https://x.com/c.jpg","source":"Some Wiki"}]}]]
            local results = ImageSearch.parseDdg(body)
            assert.are.equal("https://x.com/c.jpg", results[1].thumb)
            assert.are.equal("Some Wiki", results[1].title)   -- title falls back to source
        end)

        it("returns an empty list when there are no results", function()
            local results = ImageSearch.parseDdg([[{"results":[]}]])
            assert.are.equal(0, #results)
        end)

        it("returns nil on malformed JSON", function()
            local results, err = ImageSearch.parseDdg("not json")
            assert.is_nil(results)
            assert.is_truthy(err)
        end)

        it("returns nil, err when the response has no results key (schema break)", function()
            -- Valid JSON, but not the shape we expect: treat as a provider break
            -- (nil, err) instead of a genuine empty result set.
            local results, err = ImageSearch.parseDdg([[{"nores":true}]])
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

    describe("doSearch provider selection", function()
        -- Stub the two provider functions so doSearch's routing/fallback logic
        -- can be checked without real network I/O.
        local saved_tavily, saved_ddg
        before_each(function()
            saved_tavily = ImageSearch.searchTavily
            saved_ddg = ImageSearch.searchDdg
        end)
        after_each(function()
            ImageSearch.searchTavily = saved_tavily
            ImageSearch.searchDdg = saved_ddg
        end)

        it("uses DuckDuckGo when no Tavily key is set", function()
            ImageSearch.searchTavily = function() error("must not call Tavily") end
            ImageSearch.searchDdg = function() return { { full = "d" } } end
            local results, source = ImageSearch.doSearch("q", "")
            assert.are.equal("duckduckgo", source)
            assert.are.equal(1, #results)
        end)

        it("uses Tavily when a key is set", function()
            ImageSearch.searchTavily = function() return { { full = "t" } } end
            ImageSearch.searchDdg = function() error("must not fall back") end
            local results, source = ImageSearch.doSearch("q", "tvly-KEY")
            assert.are.equal("tavily", source)
            assert.are.equal("t", results[1].full)
        end)

        it("falls back to DuckDuckGo when Tavily returns nothing", function()
            ImageSearch.searchTavily = function() return {} end
            ImageSearch.searchDdg = function() return { { full = "d" } } end
            local results, source = ImageSearch.doSearch("q", "tvly-KEY")
            assert.are.equal("duckduckgo", source)
            assert.are.equal("d", results[1].full)
        end)

        it("falls back to DuckDuckGo when Tavily errors", function()
            ImageSearch.searchTavily = function() return nil, "HTTP 401" end
            ImageSearch.searchDdg = function() return { { full = "d" } } end
            local results, source = ImageSearch.doSearch("q", "tvly-KEY")
            assert.are.equal("duckduckgo", source)
            assert.are.equal("d", results[1].full)
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
            }
            package.loaded["socket"] = { skip = function(d, ...) return select(d + 1, ...) end }
            package.loaded["socket/http"] = { request = function(reqt) return fake_request(reqt) end }
            package.loaded["socketutil"] = { set_timeout = function() end, reset_timeout = function() end }
            dest = os.tmpname()
        end)

        after_each(function()
            package.loaded["socket"] = saved.socket
            package.loaded["socket/http"] = saved.http
            package.loaded["socketutil"] = saved.socketutil
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
