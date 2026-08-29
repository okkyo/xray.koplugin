-- xray_fetch_spec.lua
require("spec.spec_helper")
local fetch = require("xray_fetch")

describe("xray_fetch", function()
    local plugin

    before_each(function()
        plugin = createMockPlugin()
        -- Mix in fetch methods
        for k, v in pairs(fetch) do
            plugin[k] = v
        end
        plugin.cache_manager = {
            saveCache = function() return true end,
            asyncSaveCache = function() return true end,
            loadCache = function() return {} end
        }
    end)

    describe("request deadlines", function()
        it("uses elapsed wall time so suspend cannot extend a timeout", function()
            local old_time = os.time
            os.time = function() return 1601 end

            local ok, timed_out = pcall(function()
                return plugin:isRequestTimedOut(1000, 600)
            end)

            os.time = old_time
            if not ok then error(timed_out) end
            assert.is_true(timed_out)
        end)

        it("keeps requests active before their wall-clock deadline", function()
            local old_time = os.time
            os.time = function() return 1299 end

            local ok, timed_out = pcall(function()
                return plugin:isRequestTimedOut(1000, 300)
            end)

            os.time = old_time
            if not ok then error(timed_out) end
            assert.is_false(timed_out)
        end)
    end)

    describe("active request cleanup", function()
        it("cancels the registered operation and clears suspend-sensitive state", function()
            local cancelled_reason
            local dialog = { type = "ButtonDialog" }
            plugin._active_ai_dialog = dialog
            plugin._active_ai_cancel = function(reason) cancelled_reason = reason end
            plugin._active_fetch_generation = 4
            plugin.bg_fetch_active = true
            plugin.bg_fetch_pending = true

            plugin:cancelActiveAIRequest("device suspended")

            assert.are.equal("device suspended", cancelled_reason)
            assert.is_nil(plugin._active_ai_dialog)
            assert.is_nil(plugin._active_ai_cancel)
            assert.is_nil(plugin._active_fetch_generation)
            assert.is_false(plugin.bg_fetch_active)
            assert.is_false(plugin.bg_fetch_pending)
        end)

        it("kills an unregistered orphan child", function()
            local cancelled = false
            plugin.ai_helper = {
                _async_child_pid = 77,
                cancelAsyncChild = function() cancelled = true end,
            }

            plugin:cancelActiveAIRequest("device suspended")

            assert.is_true(cancelled)
        end)

        it("still kills the helper child when a registered callback is stale", function()
            local callback_called = false
            local child_cancelled = false
            plugin._active_ai_cancel = function() callback_called = true end
            plugin.ai_helper = {
                _async_child_pid = 88,
                cancelAsyncChild = function(self)
                    child_cancelled = true
                    self._async_child_pid = nil
                end,
            }

            plugin:cancelActiveAIRequest("device suspended")

            assert.is_true(callback_called)
            assert.is_true(child_cancelled)
        end)
    end)

    describe("runPostFetchDuplicateCheck reader state", function()
        it("skips safely when the reader document is unavailable", function()
            local analyzer_called = false
            plugin.ui.document = nil
            plugin.ai_helper.hasApiKey = function() return true end
            plugin.chapter_analyzer = {
                getTextForAnalysis = function()
                    analyzer_called = true
                    return "text"
                end,
            }

            local ok, err = pcall(function()
                plugin:runPostFetchDuplicateCheck("Title", "Author", 50, true)
            end)

            assert.is_true(ok)
            assert.is_nil(err)
            assert.is_false(analyzer_called)
        end)

        it("continues when the reader document is available", function()
            local analyzer_called = false
            plugin.ui.getCurrentPage = function() return 10 end
            plugin.ai_helper.hasApiKey = function() return true end
            plugin.chapter_analyzer = {
                getTextForAnalysis = function(_, ui, limit, _, current_page)
                    analyzer_called = ui == plugin.ui and limit == 15000 and current_page == 10
                    return "text"
                end,
            }

            plugin:runPostFetchDuplicateCheck("Title", "Author", 50, true)

            assert.is_true(analyzer_called)
        end)

        it("skips safely when the plugin is destroyed", function()
            local analyzer_called = false
            plugin.destroyed = true
            plugin.ai_helper.hasApiKey = function() return true end
            plugin.chapter_analyzer = {
                getTextForAnalysis = function()
                    analyzer_called = true
                    return "text"
                end,
            }

            plugin:runPostFetchDuplicateCheck("Title", "Author", 50, true)

            assert.is_false(analyzer_called)
        end)
    end)

    describe("continueWithFetch cancellation", function()
        it("does not let a silent fetch replace another request's cancel handler", function()
            local original_cancel = function() end
            local scheduled = false
            local UIManager = require("ui/uimanager")
            local old_schedule = UIManager.scheduleIn
            UIManager.scheduleIn = function()
                scheduled = true
            end
            plugin._active_ai_cancel = original_cancel
            plugin.bg_fetch_pending = true

            local ok, err = pcall(function()
                plugin:continueWithFetch(50, true, nil, true)
                assert.are.equal(original_cancel, plugin._active_ai_cancel)
                assert.is_false(plugin.bg_fetch_pending)
                assert.is_false(scheduled)
            end)

            UIManager.scheduleIn = old_schedule
            if not ok then error(err) end
        end)

        it("cancels the owned child and allows a new fetch before the old poll runs", function()
            local UIManager = require("ui/uimanager")
            local old_schedule = UIManager.scheduleIn
            local old_remove = os.remove
            local scheduled = {}
            local removed_files = {}
            local started_pids = { 501, 502 }
            local start_count = 0
            local cancelled_pids = {}

            UIManager.scheduleIn = function(self, delay, callback)
                table.insert(scheduled, callback)
            end
            os.remove = function(path)
                table.insert(removed_files, path)
                return true
            end

            plugin.ui.getCurrentPage = function() return 10 end
            plugin.chapter_analyzer = {
                getEndPageForCurrentPage = function(_, _, current_page) return current_page end,
                getTextForAnalysis = function() return "enough extracted book text" end,
                getDetailedChapterSamples = function() return "chapter samples", { "Chapter 1" } end,
                getAnnotationsForAnalysis = function() return nil end,
            }
            plugin.ai_helper = {
                settings = { spoiler_setting = "spoiler_free" },
                buildComprehensiveRequest = function()
                    return { { url = "https://example.invalid" } }
                end,
                makeRequestAsync = function(self)
                    start_count = start_count + 1
                    self._async_child_pid = started_pids[start_count]
                    return self._async_child_pid
                end,
                cancelAsyncChild = function(self, expected_pid)
                    table.insert(cancelled_pids, expected_pid)
                    if self._async_child_pid ~= expected_pid then return false end
                    self._async_child_pid = nil
                    return true
                end,
                checkAsyncResult = function() return nil end,
            }

            local function runNext()
                local callback = table.remove(scheduled, 1)
                assert.is_not_nil(callback)
                callback()
            end

            local ok, err = pcall(function()
                plugin:continueWithFetch(50)
                local first_dialog = _G.ui_tracker.last_shown
                runNext() -- deferred extraction
                runNext() -- request construction and start

                assert.are.equal(501, plugin.ai_helper._async_child_pid)
                assert.is_true(plugin.bg_fetch_active)

                first_dialog.args.buttons[1][1].callback()
                assert.are.equal(501, cancelled_pids[1])
                assert.is_false(plugin.bg_fetch_active)
                assert.is_true(#removed_files > 0)
                assert.are.equal(first_dialog, _G.ui_tracker.closed[#_G.ui_tracker.closed])

                -- Start again before the cancelled fetch's queued poll runs.
                plugin:continueWithFetch(50)
                local second_dialog = _G.ui_tracker.last_shown
                assert.is_true(plugin.bg_fetch_active)

                runNext() -- stale poll from the cancelled fetch
                assert.is_true(plugin.bg_fetch_active)
                assert.are.equal(1, #cancelled_pids)

                runNext() -- second fetch extraction
                runNext() -- second request start
                assert.are.equal(2, start_count)
                assert.are.equal(502, plugin.ai_helper._async_child_pid)
                assert.is_true(plugin.bg_fetch_active)

                second_dialog.args.buttons[1][1].callback()
                assert.are.equal(502, cancelled_pids[2])
                assert.is_false(plugin.bg_fetch_active)
            end)

            UIManager.scheduleIn = old_schedule
            os.remove = old_remove
            if not ok then error(err) end
        end)

        it("clears fetch state and does not crash when self.ui.document becomes nil before scheduled callback fires", function()
            local UIManager = require("ui/uimanager")
            local old_schedule = UIManager.scheduleIn
            local scheduled = {}

            UIManager.scheduleIn = function(self, delay, callback)
                table.insert(scheduled, callback)
            end

            plugin.ui.getCurrentPage = function() return 10 end
            plugin:continueWithFetch(50)
            assert.is_true(plugin.bg_fetch_active)

            -- Simulate reader closing mid-flight
            plugin.ui.document = nil

            local callback = table.remove(scheduled, 1)
            assert.is_not_nil(callback)

            local ok, err = pcall(callback)
            assert.is_true(ok)
            assert.is_nil(err)
            assert.is_false(plugin.bg_fetch_active)

            UIManager.scheduleIn = old_schedule
        end)

        it("clears fetch state and does not crash when self.ui becomes nil before scheduled callback fires", function()
            local UIManager = require("ui/uimanager")
            local old_schedule = UIManager.scheduleIn
            local scheduled = {}

            UIManager.scheduleIn = function(self, delay, callback)
                table.insert(scheduled, callback)
            end

            plugin.ui.getCurrentPage = function() return 10 end
            plugin:continueWithFetch(50)
            assert.is_true(plugin.bg_fetch_active)

            -- Simulate reader UI closing completely mid-flight
            plugin.ui = nil

            local callback = table.remove(scheduled, 1)
            assert.is_not_nil(callback)

            local ok, err = pcall(callback)
            assert.is_true(ok)
            assert.is_nil(err)
            assert.is_false(plugin.bg_fetch_active)

            UIManager.scheduleIn = old_schedule
        end)
    end)

    describe("finalizeXRayData", function()
        it("merges new characters correctly in update mode", function()
            plugin.characters = {
                { name = "Alice", description = "Old description" }
            }
            local new_data = {
                characters = {
                    { name = "Alice", description = "New description" },
                    { name = "Bob", description = "A new character" }
                },
                locations = {},
                historical_figures = {},
                timeline = {}
            }

            plugin:finalizeXRayData(new_data, "Test Title", "Test Author", "Some text", true, true, 10)

            assert.are.equal(2, #plugin.characters)
            assert.are.equal("New description", plugin.characters[1].description)
            assert.are.equal("Bob", plugin.characters[2].name)
        end)

        it("filters non-narrative timeline entries", function()
            plugin.isNonNarrativeChapter = function(self, title)
                return title == "Table of Contents"
            end

            local new_data = {
                characters = {},
                locations = {},
                historical_figures = {},
                timeline = {
                    { chapter = "Chapter 1", text = "Event 1" },
                    { chapter = "Table of Contents", text = "Event 2" }
                }
            }

            plugin:finalizeXRayData(new_data, "Test Title", "Test Author", "Some text", false, true, 10)

            assert.are.equal(1, #plugin.timeline)
            assert.are.equal("Chapter 1", plugin.timeline[1].chapter)
        end)

        it("aborts and protects existing data when AI returns all-empty results", function()
            -- Set up existing data
            plugin.characters = { { name = "Alice", description = "Existing" } }
            plugin.locations = { { name = "Wonderland", description = "Existing" } }
            plugin.timeline = { { chapter = "Start", page = 1 } }
            plugin.historical_figures = { { name = "Lewis Carroll", biography = "Existing" } }

            local empty_data = {
                characters = {},
                locations = {},
                historical_figures = {},
                timeline = {}
            }

            -- Spy on cache save to ensure it's NOT called
            local save_called = false
            plugin.cache_manager.saveCache = function()
                save_called = true
                return true
            end

            plugin:finalizeXRayData(empty_data, "Test Title", "Test Author", "Some text", true, true, 20)

            -- Existing data should be UNTOUCHED
            assert.are.equal(1, #plugin.characters)
            assert.are.equal("Alice", plugin.characters[1].name)
            assert.are.equal(1, #plugin.locations)
            assert.are.equal(1, #plugin.timeline)
            assert.are.equal(1, #plugin.historical_figures)
            
            -- Cache save should NOT have happened
            assert.is_false(save_called)
        end)

        it("preserves series_prior timeline entries and updates matching chapter event descriptions on update", function()
            plugin.timeline = {
                { chapter = "[Book 1: Prior]", event = "Prior book summary", page = -999, source = "series_prior" },
                { chapter = "Chapter 1", event = "Old chapter 1 summary", page = 10 }
            }

            local new_data = {
                characters = {},
                locations = {},
                historical_figures = {},
                timeline = {
                    { chapter = "Chapter 1", event = "Updated chapter 1 summary", page = 10 },
                    { chapter = "Chapter 2", event = "New chapter 2 summary", page = 25 }
                }
            }

            plugin:finalizeXRayData(new_data, "Test Title", "Test Author", "Some text", true, true, 20)

            -- Should contain 3 events total: 1 prior series event, 2 current book events
            assert.are.equal(3, #plugin.timeline)

            -- Prior series event should be preserved
            local prior_found = false
            for _, ev in ipairs(plugin.timeline) do
                if ev.source == "series_prior" then
                    prior_found = true
                    assert.are.equal("[Book 1: Prior]", ev.chapter)
                end
            end
            assert.is_true(prior_found)

            -- Chapter 1 event description should be updated
            local ch1_event
            for _, ev in ipairs(plugin.timeline) do
                if ev.chapter == "Chapter 1" then
                    ch1_event = ev
                end
            end
            assert.is_not_nil(ch1_event)
            assert.are.equal("Updated chapter 1 summary", ch1_event.event)
        end)

        it("preserves series_prior timeline entries during non-merge updates", function()
            plugin.timeline = {
                { chapter = "[Book 1: Prior]", event = "Prior book summary", page = -999, source = "series_prior" },
                { chapter = "Chapter 1", event = "Old summary", page = 10 }
            }

            local new_data = {
                characters = {},
                locations = {},
                historical_figures = {},
                timeline = {
                    { chapter = "Chapter 1", event = "Fresh fetch summary", page = 10 }
                }
            }

            plugin:finalizeXRayData(new_data, "Test Title", "Test Author", "Some text", false, true, 20)

            assert.are.equal(2, #plugin.timeline)
            local prior_found = false
            for _, ev in ipairs(plugin.timeline) do
                if ev.source == "series_prior" then
                    prior_found = true
                end
            end
            assert.is_true(prior_found)
        end)
    end)

    describe("mergeSeriesContext", function()
        it("handles missing description/name fields in characters/locations/terms without crashing", function()
            plugin.characters = {
                { name = "Alice" } -- description is nil
            }
            plugin.locations = {
                { name = "Adua" } -- description is nil
            }
            plugin.terms = {
                { name = "The Union" } -- definition is nil
            }

            local cache_data = {
                books = {
                    [1] = {
                        title = "The Blade Itself",
                        characters = { { name = "Alice", description = "Prior description" } },
                        locations = { { name = "Adua", description = "Capital city" } },
                        terms = { { name = "The Union", definition = "Kingdom" } },
                        timeline = { { event = "War breaks out" } }
                    }
                }
            }

            local series_info = { index = 2, slug = "first_law" }

            -- Should merge prior series data without nil indexing error
            plugin:mergeSeriesContext(cache_data, series_info)

            assert.is_true(#plugin.characters > 0)
            assert.is_true(#plugin.timeline > 0)
            assert.is_true(plugin.series_context_loaded)
        end)
    end)

    describe("fetchSingleWord safety & edge cases", function()
        it("returns safely when reader document is unavailable", function()
            plugin.ui.document = nil
            local ok, err = pcall(function()
                plugin:fetchSingleWord("word", 1, 2)
            end)
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("unwraps table text arguments without crashing", function()
            local called_text = nil
            plugin.ai_helper = {
                hasApiKey = function() return false end,
            }
            local ok, err = pcall(function()
                plugin:fetchSingleWord({ text = "ExtractedWord" }, 1, 2)
            end)
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("cancels an active background fetch process before starting lookup", function()
            local cancelled = false
            plugin.ui.getCurrentPage = function() return 1 end
            plugin.chapter_analyzer = {
                getDetailedChapterSamples = function() return {}, {} end,
                getEndPageForCurrentPage = function() return 1 end,
                getTextFromPageRange = function() return "book text" end,
            }
            plugin.ai_helper = {
                _async_child_pid = 999,
                hasApiKey = function() return true end,
                cancelAsyncChild = function() cancelled = true end,
                lookupSingleWordAsync = function() return 1001 end,
                checkAsyncResult = function() return false, "error_api", "cancelled" end,
            }
            
            plugin:fetchSingleWord("TestTerm", 1, 2)
            assert.is_true(cancelled)
        end)

        it("shows a Cancel button that terminates the lookup child", function()
            local UIManager = require("ui/uimanager")
            local old_schedule = UIManager.scheduleIn
            local scheduled = {}
            local cancelled_pid

            UIManager.scheduleIn = function(self, delay, callback)
                table.insert(scheduled, callback)
            end
            plugin.ui.getCurrentPage = function() return 1 end
            plugin.chapter_analyzer = {
                getDetailedChapterSamples = function() return {}, {} end,
                getEndPageForCurrentPage = function() return 1 end,
                getTextFromPageRange = function() return "book text" end,
            }
            plugin.ai_helper = {
                hasApiKey = function() return true end,
                lookupSingleWordAsync = function() return 1001 end,
                cancelAsyncChild = function(_, pid) cancelled_pid = pid; return true end,
                checkAsyncResult = function() return nil end,
            }

            local ok, err = pcall(function()
                plugin:fetchSingleWord("TestTerm", 1, 2)
                assert.are.equal("ButtonDialog", plugin._active_ai_dialog.type)
                table.remove(scheduled, 1)()
                table.remove(scheduled, 1)()
                plugin._active_ai_dialog.args.buttons[1][1].callback()
                assert.are.equal(1001, cancelled_pid)
                assert.is_nil(plugin._active_ai_dialog)
                assert.is_nil(plugin._active_ai_cancel)
            end)

            UIManager.scheduleIn = old_schedule
            if not ok then error(err) end
        end)

        it("does not spawn a lookup child when cancelled before deferred analysis", function()
            local UIManager = require("ui/uimanager")
            local old_schedule = UIManager.scheduleIn
            local scheduled = {}
            local spawn_count = 0

            UIManager.scheduleIn = function(self, delay, callback)
                table.insert(scheduled, callback)
            end
            plugin.ui.getCurrentPage = function() return 1 end
            plugin.chapter_analyzer = {
                getDetailedChapterSamples = function() return {}, {} end,
                getEndPageForCurrentPage = function() return 1 end,
                getTextFromPageRange = function() return "book text" end,
            }
            plugin.ai_helper = {
                hasApiKey = function() return true end,
                lookupSingleWordAsync = function()
                    spawn_count = spawn_count + 1
                    return 1001
                end,
                cancelAsyncChild = function() return true end,
            }

            local ok, err = pcall(function()
                plugin:fetchSingleWord("TestTerm", 1, 2)
                plugin._active_ai_dialog.args.buttons[1][1].callback()
                while #scheduled > 0 do
                    table.remove(scheduled, 1)()
                end
                assert.are.equal(0, spawn_count)
            end)

            UIManager.scheduleIn = old_schedule
            if not ok then error(err) end
        end)

        it("handles invalid or non-table result in _processSingleWordResult without crashing", function()
            local ok, err = pcall(function()
                plugin:_processSingleWordResult("invalid_json", "text", "book_text", 1)
                plugin:_processSingleWordResult({ is_valid = true, item = nil }, "text", "book_text", 1)
            end)
            assert.is_true(ok)
            assert.is_nil(err)
        end)
    end)

    describe("fetch-more entity type inference", function()
        before_each(function()
            plugin.characters = { { name = "Madge Undersee" } }
            plugin.locations = { { name = "District 12" } }
            plugin.historical_figures = { { name = "President Snow", biography = "..." } }
            plugin.terms = { { name = "Tessera", definition = "..." } }
        end)

        it("classifies a term by its definition field", function()
            assert.are.equal("term", plugin:_inferEntityType({ name = "X", definition = "d" }))
        end)
        it("classifies a historical figure by its biography field", function()
            assert.are.equal("historical_figure", plugin:_inferEntityType({ name = "X", biography = "b" }))
        end)
        it("classifies a location by list membership", function()
            assert.are.equal("location", plugin:_inferEntityType({ name = "District 12" }))
        end)
        it("defaults an unknown entity to character", function()
            assert.are.equal("character", plugin:_inferEntityType({ name = "Nobody" }))
        end)
    end)

    describe("fetch-more result merge", function()
        local madge
        before_each(function()
            madge = { name = "Madge Undersee", description = "Mayor's daughter and friend." }
            plugin.characters = { madge }
            plugin.lookup_manager = { showResult = function() end }
        end)

        it("does not let an empty description wipe the entry when the text is under another key", function()
            plugin:_processSingleWordResult(
                { is_valid = true, type = "historical_figure",
                  item = { name = "Madge", description = "", biography = "Long enriched text." } },
                "Madge", "book text", 1, true, madge, "character")
            assert.are.equal("Long enriched text.", madge.description)
            assert.is_nil(madge.biography)
            assert.are.equal("Madge Undersee", madge.name)
        end)

        it("keeps the existing description when the AI returns only empty text", function()
            plugin:_processSingleWordResult(
                { is_valid = true, type = "character",
                  item = { name = "Madge", description = "" } },
                "Madge", "book text", 1, true, madge, "character")
            assert.are.equal("Mayor's daughter and friend.", madge.description)
        end)
    end)

    describe("fetch-more start errors", function()
        it("forwards the build error from lookupSingleWordAsync to the error dialog", function()
            local shown_codes = {}
            local utils = require("xray_utils")
            local orig_friendly = utils.getFriendlyError
            utils.getFriendlyError = function(_, code, msg, loc)
                table.insert(shown_codes, { code = code, msg = msg })
                return "title", tostring(msg)
            end
            plugin.ai_helper = {
                hasApiKey = function() return true end,
                settings = { spoiler_setting = "full_book" },
                lookupSingleWordAsync = function() return nil, "error_api", "No API key configured" end,
                cancelAsyncChild = function() end,
            }
            plugin.chapter_analyzer = {
                getEndPageForCurrentPage = function() return 10 end,
                getDetailedChapterSamples = function() return "samples", {} end,
                scanMentionsAsync = function(_, _, _, _, _, _, _, on_complete)
                    on_complete({})
                    return { cancel = function() end }
                end,
            }
            plugin.ui.getCurrentPage = function() return 10 end
            plugin.ui.document.getPageCount = function() return 100 end
            plugin._buildEnrichContext = function() return {}, "book text" end
            plugin._sweepStaleFetchFiles = function() end
            plugin.findRelatedEntities = function() return {} end

            plugin:fetchMoreDetailsForEntity({ name = "Madge Undersee", mentions = {} }, "character")

            utils.getFriendlyError = orig_friendly
            assert.are.equal(1, #shown_codes)
            assert.are.equal("error_api", shown_codes[1].code)
            assert.are.equal("No API key configured", shown_codes[1].msg)
        end)
    end)

    describe("fetch-more passage gathering", function()
        local entity, scan_calls, enrich_passages

        before_each(function()
            scan_calls = {}
            enrich_passages = nil
            entity = { name = "Madge Undersee" }
            plugin.ai_helper = {
                hasApiKey = function() return true end,
                settings = { spoiler_setting = "spoiler_free" },
                lookupSingleWordAsync = function() return 4242 end,
                cancelAsyncChild = function() end,
                -- The spec UIManager runs scheduled callbacks at once, so the poll
                -- must end on its first tick or it recurses forever.
                checkAsyncResult = function() return false, "error_api", "stub" end,
            }
            plugin.chapter_analyzer = {
                getEndPageForCurrentPage = function(_, _, p) return p end,
                getDetailedChapterSamples = function() return "samples", {} end,
                scanMentionsAsync = function(_, _, _, _, min_page, max_page, _, on_complete)
                    table.insert(scan_calls, { min_page = min_page, max_page = max_page })
                    on_complete({ { page = 70, snippet = "Madge waves.", chapter = "Ch 7" } })
                    return { cancel = function() end }
                end,
            }
            plugin.ui.getCurrentPage = function() return 80 end
            plugin.ui.document.getPageCount = function() return 100 end
            plugin._buildEnrichContext = function(_, _, _, passages)
                enrich_passages = passages
                return {}, "book text"
            end
            plugin._sweepStaleFetchFiles = function() end
            plugin.saveMentionsToCache = function() end
            plugin.isRequestTimedOut = function() return false end
        end)

        it("rescans from the last scanned page when the cache stops short of the reader", function()
            entity.mentions = {
                { page = 3, snippet = "a" }, { page = 5, snippet = "b" }, { page = 9, snippet = "c" },
            }
            entity.last_mention_page = 20
            plugin:fetchMoreDetailsForEntity(entity, "character")

            assert.are.equal(1, #scan_calls)
            assert.are.equal(20, scan_calls[1].min_page)
            assert.are.equal(80, scan_calls[1].max_page)
            -- The scan result is merged and persisted on the entity.
            assert.are.equal(4, #entity.mentions)
            assert.are.equal(70, entity.mentions[4].page)
            assert.are.equal(80, entity.last_mention_page)
            -- The AI receives the combined passages, not only the stale cache.
            assert.are.equal(4, #enrich_passages)
        end)

        it("reuses a cache that already covers the readable range without scanning", function()
            entity.mentions = {
                { page = 3, snippet = "a" }, { page = 5, snippet = "b" }, { page = 9, snippet = "c" },
            }
            entity.last_mention_page = math.huge
            plugin:fetchMoreDetailsForEntity(entity, "character")

            assert.are.equal(0, #scan_calls)
            assert.are.equal(3, #enrich_passages)
        end)
    end)

    describe("fetch-more context assembly", function()
        local entity = {
            name = "Madge Undersee",
            role = "Mayor's daughter and friend",
            description = "The daughter of the mayor of District 12.",
            aliases = { "Madge" },
        }

        it("focuses the prompt on the entity and includes the existing entry", function()
            local ctx, book_text = plugin:_buildEnrichContext(entity, "character",
                { { snippet = "Madge opens the door." }, { snippet = "Madge smiles at Katniss." } },
                "CHAPTER SAMPLES TEXT", 55)
            assert.is_truthy(book_text:find("FOCUS ENTITY", 1, true))
            assert.is_truthy(book_text:find("Madge Undersee", 1, true))
            assert.is_truthy(book_text:find("The daughter of the mayor", 1, true))
            assert.is_truthy(book_text:find("Madge opens the door.", 1, true))
            assert.are.equal(55, ctx.reading_percent)
            assert.are.equal("CHAPTER SAMPLES TEXT", ctx.chapter_samples)
        end)

        it("triggers merge mode for the matching entity type only", function()
            local ctx = plugin:_buildEnrichContext(entity, "character", {}, nil, 100)
            assert.is_truthy(ctx.existing_characters)
            assert.is_nil(ctx.existing_locations)
            assert.is_nil(ctx.existing_historical_figures)

            local lctx = plugin:_buildEnrichContext({ name = "District 12", description = "A district." }, "location", {}, nil, 100)
            assert.is_truthy(lctx.existing_locations)
            assert.is_nil(lctx.existing_characters)
        end)

        it("accepts plain-string passages and caps the passage budget", function()
            local big = {}
            for i = 1, 500 do big[i] = { snippet = string.rep("Madge ", 20) } end
            local ok, _, book_text = pcall(function()
                local c, bt = plugin:_buildEnrichContext(entity, "character", big, nil, 100)
                return c, bt
            end)
            assert.is_true(ok)
            -- book_text stays bounded (header + <= ~18000 chars of passages)
            local _, bt2 = plugin:_buildEnrichContext(entity, "character", big, nil, 100)
            assert.is_true(#bt2 < 20000)
        end)

        it("handles a term with a definition and no merge-mode branch", function()
            local ctx, book_text = plugin:_buildEnrichContext(
                { name = "Tessera", definition = "A ration entry in exchange for tesserae." },
                "term", { { snippet = "You can sign up for a tessera." } }, nil, 100)
            assert.is_truthy(book_text:find("A ration entry", 1, true))
            assert.is_nil(ctx.existing_characters)
        end)

        it("asks the rewrite to keep naming currently linked entities", function()
            -- Stub the link detector (defined in the UI mixin, absent here) so the
            -- preserve-names branch runs.
            plugin.findRelatedEntities = function()
                return { { item = { name = "Mayor of District 12" }, type = "character" } }
            end
            local _, book_text = plugin:_buildEnrichContext(entity, "character", {}, nil, 100)
            assert.is_truthy(book_text:find("Keep naming these related entities", 1, true))
            assert.is_truthy(book_text:find("Mayor of District 12", 1, true))
        end)

        it("omits the preserve line when nothing is linked", function()
            plugin.findRelatedEntities = function() return {} end
            local _, book_text = plugin:_buildEnrichContext(entity, "character", {}, nil, 100)
            assert.is_nil(book_text:find("Keep naming these related entities", 1, true))
        end)
    end)

    describe("enrich passage ranking", function()
        local function pagesOf(list)
            local pages = {}
            for _, m in ipairs(list) do table.insert(pages, m.page) end
            return pages
        end

        it("returns an empty list for empty or nil input", function()
            assert.are.same({}, plugin:_rankEnrichPassages(nil, {}))
            assert.are.same({}, plugin:_rankEnrichPassages({}, {}))
        end)

        it("keeps a dense cluster and drops an isolated early mention when the budget is tight", function()
            local s = string.rep("x", 100)
            local mentions = {
                { page = 4,  snippet = "A" .. s },
                { page = 10, snippet = "B" .. s },
                { page = 11, snippet = "C" .. s },
                { page = 12, snippet = "D" .. s },
            }
            local out = plugin:_rankEnrichPassages(mentions, {
                current_page = 12, total_pages = 100, budget = 310,
            })
            assert.are.same({ 10, 11, 12 }, pagesOf(out))
        end)

        it("prefers a mention near the current page over an equally dense distant one", function()
            local s = string.rep("x", 100)
            local mentions = {
                { page = 5,  snippet = "A" .. s },
                { page = 90, snippet = "B" .. s },
            }
            local out = plugin:_rankEnrichPassages(mentions, {
                current_page = 90, total_pages = 100, budget = 101,
            })
            assert.are.same({ 90 }, pagesOf(out))
        end)

        it("emits the selection in page order regardless of score order", function()
            local mentions = {
                { page = 80, snippet = "late" },
                { page = 5,  snippet = "early" },
                { page = 40, snippet = "middle" },
            }
            local out = plugin:_rankEnrichPassages(mentions, {
                current_page = 80, total_pages = 100, budget = 18000,
            })
            assert.are.same({ 5, 40, 80 }, pagesOf(out))
        end)

        it("drops duplicate snippets before spending the budget", function()
            local mentions = {
                { page = 10, snippet = "same text" },
                { page = 20, snippet = "same text" },
                { page = 30, snippet = "different" },
            }
            local out = plugin:_rankEnrichPassages(mentions, {
                current_page = 30, total_pages = 100, budget = 18000,
            })
            assert.are.equal(2, #out)
        end)

        it("ranks page-less mentions last but keeps them when budget remains", function()
            local mentions = {
                { snippet = "floating" },
                { page = 50, snippet = "anchored" },
            }
            local out = plugin:_rankEnrichPassages(mentions, {
                current_page = 50, total_pages = 100, budget = 18000,
            })
            assert.are.equal(2, #out)
            assert.are.equal("anchored", out[1].snippet)
            assert.are.equal("floating", out[2].snippet)
        end)
    end)

    describe("auto-enrich gate", function()
        it("triggers on a thin description", function()
            local ok, reason = plugin:_shouldAutoEnrich(
                { name = "Madge", description = "Short." }, "character", 10, 300)
            assert.is_true(ok)
            assert.are.equal("thin", reason)
        end)

        it("triggers when the reader moved well past the last enrich point", function()
            local ok, reason = plugin:_shouldAutoEnrich(
                { name = "Madge", description = string.rep("x", 200), last_enrich_page = 50 },
                "character", 200, 300)
            assert.is_true(ok)
            assert.are.equal("stale", reason)
        end)

        it("does not trigger for a long and fresh entry", function()
            local ok = plugin:_shouldAutoEnrich(
                { name = "Madge", description = string.rep("x", 200), last_enrich_page = 95 },
                "character", 100, 300)
            assert.is_false(ok)
        end)

        it("uses the per-type target length", function()
            -- 80 chars is thin for a character (target 200) but fine for a
            -- location (target 100, 60% = 60).
            local desc = string.rep("x", 80)
            local fresh = { name = "E", description = desc, last_enrich_page = 100 }
            assert.is_true(plugin:_shouldAutoEnrich(fresh, "character", 100, 100))
            assert.is_false(plugin:_shouldAutoEnrich(fresh, "location", 100, 100))
        end)

        it("resolves the last enrich page from field, history, then fetch position", function()
            assert.are.equal(42, plugin:_lastEnrichPage({ last_enrich_page = 42 }))
            assert.are.equal(30, plugin:_lastEnrichPage({
                history = { { page = 10 }, { page = 30 }, { page = 20 } },
            }))
            plugin.book_data = { last_fetch_page = 7 }
            assert.are.equal(7, plugin:_lastEnrichPage({ name = "X" }))
            plugin.book_data = nil
            assert.are.equal(0, plugin:_lastEnrichPage({ name = "X" }))
        end)
    end)

    describe("auto-enrich trigger", function()
        local fetch_calls

        before_each(function()
            fetch_calls = {}
            plugin.ui.getCurrentPage = function() return 100 end
            plugin.ui.document.getPageCount = function() return 300 end
            -- The mock device reports as PW1-class (low power), where auto-enrich
            -- defaults off. Opt in explicitly so these tests exercise the fetch path.
            plugin.ai_helper = { settings = { auto_enrich_cards = true } }
            plugin.fetchMoreDetailsForEntity = function(_, entity, entity_type, opts)
                table.insert(fetch_calls, { entity = entity, entity_type = entity_type, opts = opts })
            end
        end)

        it("fetches silently once per entity per session", function()
            local madge = { name = "Madge", description = "Short." }
            plugin:_maybeAutoEnrichEntity(madge, "character")
            plugin:_maybeAutoEnrichEntity(madge, "character")
            assert.are.equal(1, #fetch_calls)
            assert.are.equal(madge, fetch_calls[1].entity)
            assert.are.equal("character", fetch_calls[1].entity_type)
            assert.is_true(fetch_calls[1].opts.silent)
        end)

        it("skips while another AI request runs, without burning the attempt", function()
            local madge = { name = "Madge", description = "Short." }
            plugin._active_ai_cancel = function() end
            plugin:_maybeAutoEnrichEntity(madge, "character")
            assert.are.equal(0, #fetch_calls)
            plugin._active_ai_cancel = nil
            plugin:_maybeAutoEnrichEntity(madge, "character")
            assert.are.equal(1, #fetch_calls)
        end)

        it("skips while a mention scan runs, without burning the attempt", function()
            local madge = { name = "Madge", description = "Short." }
            plugin.active_mention_scan = { entity_name = "Other" }
            plugin:_maybeAutoEnrichEntity(madge, "character")
            assert.are.equal(0, #fetch_calls)
        end)

        it("never fires for timeline or conversion entries", function()
            plugin:_maybeAutoEnrichEntity({ name = "Event", is_timeline = true, description = "" }, "character")
            plugin:_maybeAutoEnrichEntity({ name = "3 miles", is_conversion = true, description = "" }, "character")
            assert.are.equal(0, #fetch_calls)
        end)

        it("does not fire for a long and fresh entry", function()
            plugin:_maybeAutoEnrichEntity(
                { name = "Madge", description = string.rep("x", 200), last_enrich_page = 95 },
                "character")
            assert.are.equal(0, #fetch_calls)
        end)

        it("respects an explicit opt-out setting", function()
            plugin.ai_helper.settings.auto_enrich_cards = false
            plugin:_maybeAutoEnrichEntity({ name = "Madge", description = "Short." }, "character")
            assert.are.equal(0, #fetch_calls)
        end)

        it("defaults off on a low-power device when the setting is unset", function()
            -- The mock device is PW1-class, so an unset setting must not spend a
            -- metered AI call on card open.
            plugin.ai_helper.settings.auto_enrich_cards = nil
            plugin:_maybeAutoEnrichEntity({ name = "Madge", description = "Short." }, "character")
            assert.are.equal(0, #fetch_calls)
        end)
    end)

    describe("silent fetch-more", function()
        local entity

        before_each(function()
            entity = { name = "Madge Undersee", mentions = {}, description = "Short." }
            plugin.ai_helper = {
                hasApiKey = function() return true end,
                settings = { spoiler_setting = "full_book" },
                lookupSingleWordAsync = function() return nil, "error_api", "No API key configured" end,
                cancelAsyncChild = function() end,
            }
            plugin.chapter_analyzer = {
                getEndPageForCurrentPage = function() return 10 end,
                getDetailedChapterSamples = function() return "samples", {} end,
                scanMentionsAsync = function(_, _, _, _, _, _, _, on_complete)
                    on_complete({})
                    return { cancel = function() end }
                end,
            }
            plugin.ui.getCurrentPage = function() return 10 end
            plugin.ui.document.getPageCount = function() return 100 end
            plugin._buildEnrichContext = function() return {}, "book text" end
            plugin._sweepStaleFetchFiles = function() end
            plugin.findRelatedEntities = function() return {} end
            plugin.saveMentionsToCache = function() end
        end)

        it("suppresses the error dialog on a failed start", function()
            local shown_before = #_G.ui_tracker.shown
            plugin:fetchMoreDetailsForEntity(entity, "character", { silent = true })
            assert.are.equal(shown_before, #_G.ui_tracker.shown)
        end)

        it("shows no progress dialog while running", function()
            plugin:fetchMoreDetailsForEntity(entity, "character", { silent = true })
            assert.is_nil(plugin._active_ai_dialog)
        end)

        it("skips when offline without any dialog", function()
            local net = package.loaded["ui/network/manager"]
            local old_connected = net.isConnected
            net.isConnected = function() return false end
            local started = false
            plugin.ai_helper.lookupSingleWordAsync = function() started = true; return 1 end
            local shown_before = #_G.ui_tracker.shown

            plugin:fetchMoreDetailsForEntity(entity, "character", { silent = true })

            net.isConnected = old_connected
            assert.is_false(started)
            assert.are.equal(shown_before, #_G.ui_tracker.shown)
        end)

        it("yields to an active mention scan instead of stealing its slot", function()
            plugin.active_mention_scan = { entity_name = "Other", cancel_handle = { cancel = function() end } }
            local started = false
            plugin.ai_helper.lookupSingleWordAsync = function() started = true; return 1 end

            plugin:fetchMoreDetailsForEntity(entity, "character", { silent = true })

            assert.is_false(started)
            assert.is_not_nil(plugin.active_mention_scan)
        end)
    end)

    describe("silent result processing", function()
        local madge

        before_each(function()
            madge = { name = "Madge Undersee", description = "Mayor's daughter and friend." }
            plugin.characters = { madge }
        end)

        it("refreshes the open card instead of opening a result view", function()
            local shown_result, refreshed
            plugin.lookup_manager = { showResult = function(_, item) shown_result = item end }
            plugin._refreshOpenEntityCard = function(_, item, item_type)
                refreshed = { item = item, item_type = item_type }
            end

            plugin:_processSingleWordResult(
                { is_valid = true, type = "character",
                  item = { name = "Madge", description = "Enriched long text." } },
                "Madge", "book text", 42, true, madge, "character", { silent = true })

            assert.is_nil(shown_result)
            assert.are.equal(madge, refreshed.item)
            assert.are.equal("character", refreshed.item_type)
            assert.are.equal("Enriched long text.", madge.description)
        end)

        it("records the enrich position on the entry", function()
            plugin.lookup_manager = { showResult = function() end }
            plugin:_processSingleWordResult(
                { is_valid = true, type = "character",
                  item = { name = "Madge", description = "Enriched long text." } },
                "Madge", "book text", 42, true, madge, "character", { silent = true })
            assert.are.equal(42, madge.last_enrich_page)
        end)

        it("drops an invalid result without any dialog", function()
            local shown_before = #_G.ui_tracker.shown
            plugin:_processSingleWordResult(
                { is_valid = false, error_message = "nope" },
                "Madge", "book text", 42, true, madge, "character", { silent = true })
            plugin:_processSingleWordResult(
                "not a table", "Madge", "book text", 42, true, madge, "character", { silent = true })
            assert.are.equal(shown_before, #_G.ui_tracker.shown)
        end)
    end)
end)
