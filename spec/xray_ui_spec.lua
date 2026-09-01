-- xray_ui_spec.lua
require("spec/spec_helper")
local xray_ui = require("xray_ui")

describe("xray_ui", function()
    local plugin

    before_each(function()
        plugin = createMockPlugin()
        -- Mix in UI methods
        for k, v in pairs(xray_ui) do
            plugin[k] = v
        end
        -- Reset UI tracker
        _G.ui_tracker.shown = {}
        _G.ui_tracker.last_shown = nil
        _G.ui_tracker.closed = {}
    end)

    describe("showLanguageSelection", function()
        it("should show a Menu with language options and correctly marked default checkbox", function()
            plugin:showLanguageSelection()
            local last = _G.ui_tracker.last_shown
            assert.is_not_nil(last)
            assert.are.equal("Menu", last.type)
            assert.are.equal("menu_language", last.args.title)
            
            -- Verify that the default option (Follow System) is checked [✓] and others are unchecked [  ]
            local follow_system_option = last.args.item_table[1]
            assert.truthy(follow_system_option.text:find("^%[✓%]"))
            
            local english_option
            for _, item in ipairs(last.args.item_table) do
                if item.text:find("English") then english_option = item; break end
            end
            assert.is_not_nil(english_option)
            assert.truthy(english_option.text:find("^%[%s*%]"))
        end)
    end)

    describe("closeAllMenus", function()
        it("should close active menus and set them to nil", function()
            plugin.char_menu = { type = "MockMenu" }
            plugin.xray_menu = { type = "MockMenu" }
            
            plugin:closeAllMenus()
            
            assert.is_nil(plugin.char_menu)
            assert.is_nil(plugin.xray_menu)
            -- Should have called UIManager:close twice for our menus
            -- Plus others in the list
            assert.is_true(#_G.ui_tracker.closed >= 2)
        end)
    end)

    describe("showCharacters", function()
        it("should show a Menu even if no characters, containing Fetch More", function()
            plugin.characters = {}
            plugin:showCharacters()
            local last = _G.ui_tracker.last_shown
            assert.are.equal("Menu", last.type)
            assert.truthy(last.args.title:find("menu_characters"))
            assert.are.equal(1, #last.args.item_table)
            assert.truthy(last.args.item_table[1].text:find("menu_fetch_more_chars"))
        end)

        it("should show a Menu if characters exist", function()
            plugin.characters = { { name = "Alice", description = "Test" } }
            plugin:showCharacters()
            local last = _G.ui_tracker.last_shown
            assert.are.equal("Menu", last.type)
            assert.truthy(last.args.title:find("menu_characters"))
            -- Verify Alice is in the menu
            local found = false
            for _, item in ipairs(last.args.item_table) do
                if item.text:find("Alice") then found = true; break end
            end
            assert.is_true(found)
        end)
    end)

    describe("showCharacterDetails", function()
        it("should show details dialog when popup toggles are false", function()
            plugin.ai_helper.settings.ui_popup_intext = false
            plugin.ai_helper.settings.ui_popup_menu = false
            plugin.ai_helper.settings.entity_ui_mode = nil
            local char = { name = "Bob", description = "A builder" }
            plugin:showCharacterDetails(char)
            local last = _G.ui_tracker.last_shown
            assert.is_not_nil(last)
            assert.are.equal("ButtonDialog", last.type)
            
            local function find_texts(w)
                local texts = {}
                local seen = {}
                local function traverse(node)
                    if not node or type(node) ~= "table" or seen[node] then return end
                    seen[node] = true
                    if node.type == "TextBoxWidget" and node.args and node.args.text then
                        table.insert(texts, node.args.text)
                    end
                    for k, v in pairs(node) do
                        if type(v) == "table" and k ~= "parent" then traverse(v) end
                    end
                    if node.args and type(node.args) == "table" then
                        for _, v in ipairs(node.args) do
                            if type(v) == "table" then traverse(v) end
                        end
                    end
                end
                traverse(w)
                return texts
            end

            local texts = find_texts(last)
            local name_found = false
            local desc_found = false
            for _, t in ipairs(texts) do
                if t:find("Bob") then name_found = true end
                if t:find("A builder") then desc_found = true end
            end
            assert.is_true(name_found)
            assert.is_true(desc_found)
        end)

        it("should show bottom popup when ui_popup toggles are true", function()
            plugin.ai_helper.settings.ui_popup_intext = true
            plugin.ai_helper.settings.ui_popup_menu = true
            plugin.ai_helper.settings.entity_ui_mode = nil
            local char = { name = "Bob", description = "A builder" }
            plugin:showCharacterDetails(char)
            local last = _G.ui_tracker.last_shown
            assert.is_not_nil(last)
            assert.are.equal("InputContainer", last.type)
        end)

        it("should show bottom popup and buttons when both linked_entries and mentions are enabled", function()
            plugin.ai_helper.settings.ui_popup_intext = true
            plugin.ai_helper.settings.ui_popup_menu = true
            plugin.ai_helper.settings.linked_entries_enabled = true
            plugin.ai_helper.settings.mentions_enabled = true
            plugin.findRelatedEntities = function() return { { name = "Related" } } end
            
            local char = { name = "Bob", description = "A builder" }
            -- This should not crash (RightContainer bug)
            plugin:showCharacterDetails(char)
            local last = _G.ui_tracker.last_shown
            assert.is_not_nil(last)
            assert.are.equal("InputContainer", last.type)
        end)

        it("should migrate legacy entity_ui_mode setting properly", function()
            plugin.ai_helper.settings.ui_popup_intext = nil
            plugin.ai_helper.settings.ui_popup_menu = nil
            plugin.ai_helper.settings.entity_ui_mode = "both"
            local char = { name = "Bob", description = "A builder" }
            plugin:showCharacterDetails(char)
            assert.is_true(plugin.ai_helper.settings.ui_popup_intext)
            assert.is_true(plugin.ai_helper.settings.ui_popup_menu)
            assert.is_nil(plugin.ai_helper.settings.entity_ui_mode)
        end)

        it("should format attributes horizontally without labels, except Alias", function()
            -- 1. Test modern footnote popup layout
            plugin.ai_helper.settings.ui_popup_intext = true
            plugin.ai_helper.settings.ui_popup_menu = true
            local char = {
                name = "Bob",
                aliases = { "Bobby" },
                role = "Protagonist",
                occupation = "Detective",
                gender = "Female",
                description = "A builder"
            }
            plugin:showCharacterDetails(char, { source = "in_text" })
            local last = _G.ui_tracker.last_shown
            assert.is_not_nil(last)
            
            -- Traverse and find text labels
            local function find_texts(w)
                local texts = {}
                local seen = {}
                local function traverse(node)
                    if not node or type(node) ~= "table" or seen[node] then return end
                    seen[node] = true
                    if node.type == "TextBoxWidget" and node.args and node.args.text then
                        table.insert(texts, node.args.text)
                    end
                    for k, v in pairs(node) do
                        if type(v) == "table" and k ~= "parent" then traverse(v) end
                    end
                    if node.args and type(node.args) == "table" then
                        for _, v in ipairs(node.args) do
                            if type(v) == "table" then traverse(v) end
                        end
                    end
                end
                traverse(w)
                return texts
            end

            local texts = find_texts(last)
            local combined_found = false
            local aliases_found = false
            for _, t in ipairs(texts) do
                if t:find("Protagonist | Detective | Female") then combined_found = true end
                if t:find("label_aliases: Bobby") then aliases_found = true end
                -- Verify individual labels are NOT present
                assert.is_nil(t:find("ROLE:"))
                assert.is_nil(t:find("GENDER:"))
                assert.is_nil(t:find("OCCUPATION:"))
            end
            assert.is_true(combined_found)
            assert.is_true(aliases_found)

            -- 2. Test classic full-screen dialog details view layout
            plugin.ai_helper.settings.ui_popup_menu = false
            plugin:showCharacterDetails(char, { source = "menu" })
            local dialog = _G.ui_tracker.last_shown
            assert.is_not_nil(dialog)
            assert.are.equal("ButtonDialog", dialog.type)
            
            local texts_classic = find_texts(dialog)
            local combined_found_classic = false
            local aliases_found_classic = false
            for _, t in ipairs(texts_classic) do
                if t:find("Protagonist | Detective | Female") then combined_found_classic = true end
                if t:find("label_aliases: Bobby") then aliases_found_classic = true end
                -- Verify individual labels are NOT present
                assert.is_nil(t:find("ROLE:"))
                assert.is_nil(t:find("GENDER:"))
                assert.is_nil(t:find("OCCUPATION:"))
            end
            assert.is_true(combined_found_classic)
            assert.is_true(aliases_found_classic)
        end)
    end)

    describe("showMergeFlow", function()
        it("should show primary picker dialog", function()
            plugin.characters = { { name = "A" }, { name = "B" } }
            plugin:showMergeFlow(plugin.characters, "characters")
            local last = _G.ui_tracker.last_shown
            assert.are.equal("ButtonDialog", last.type)
            assert.are.equal("merge_pick_primary", last.args.title)
        end)
    end)

    describe("showAIFindDuplicatesFlow", function()
        before_each(function()
            plugin.ai_helper = {
                hasApiKey = function() return true end,
                findDuplicates = function()
                    return {
                        { primary = "Jon", secondary = "John", reason = "Similar spelling" },
                        { primary = "Alice", secondary = "Bob", reason = "Different" }
                    }
                end,
                settings = {}
            }
            plugin.characters = {
                { name = "Jon", description = "Character 1" },
                { name = "John", description = "Character 2" },
                { name = "Alice", description = "Character 3" },
                { name = "Bob", description = "Character 4" }
            }
            plugin.ui = {
                document = {
                    file = "test_book.epub",
                    getProps = function() return { title = "Test", authors = "Author" } end,
                    getPageCount = function() return 100 end
                }
            }
            plugin.ui.getCurrentPage = function() return 10 end
            plugin.book_data = {}
            local loc_xray = require("localization_xray")
            plugin.loc = {
                t = function(self, key, ...)
                    return loc_xray:t(key, ...)
                end
            }
        end)

        it("should show ButtonDialog for duplicate pairs and support Reject", function()
            plugin:showAIFindDuplicatesFlow(plugin.characters, "characters", "characters")
            local last = _G.ui_tracker.last_shown
            assert.are.equal("ButtonDialog", last.type)
            
            -- Verify buttons: Merge, Skip, Reject, Stop
            local buttons = last.args.buttons[1]
            assert.are.equal(4, #buttons)
            assert.are.equal("Merge", buttons[1].text)
            assert.are.equal("Skip", buttons[2].text)
            assert.are.equal("Reject", buttons[3].text)
            assert.are.equal("Stop", buttons[4].text)

            -- Tap Reject
            local reject_cb = buttons[3].callback
            reject_cb()

            -- Verify it added the pair to rejected_merge_pairs in book_data
            assert.is_not_nil(plugin.book_data.rejected_merge_pairs)
            assert.is_true(plugin.book_data.rejected_merge_pairs["john|jon"])

            -- Run duplicate check again, the rejected pair should be filtered out
            _G.ui_tracker.shown = {}
            plugin:showAIFindDuplicatesFlow(plugin.characters, "characters", "characters")
            
            -- Only Alice vs Bob should be shown
            local dialog = _G.ui_tracker.last_shown
            assert.are.equal("ButtonDialog", dialog.type)
            assert.truthy(dialog.args.title:find("Alice") and dialog.args.title:find("Bob"))
        end)

        it("should walk pre-scanned duplicate pairs directly without calling AI", function()
            local called_ai = false
            plugin.ai_helper.findDuplicates = function()
                called_ai = true
                return {}
            end
            
            local pairs = {
                { primary = "Jon", secondary = "John", reason = "Similar spelling" }
            }
            plugin:walkDuplicatePairs(plugin.characters, "characters", pairs)
            
            assert.is_false(called_ai)
            local last = _G.ui_tracker.last_shown
            assert.are.equal("ButtonDialog", last.type)
            assert.truthy(last.args.title:find("Jon") and last.args.title:find("John"))
        end)
    end)

    describe("showTerms", function()
        it("should show a Menu even if no terms, containing Fetch More", function()
            plugin.terms = {}
            plugin:showTerms()
            local last = _G.ui_tracker.last_shown
            assert.are.equal("Menu", last.type)
            assert.truthy(last.args.title:find("menu_terms"))
            assert.are.equal(1, #last.args.item_table)
            assert.truthy(last.args.item_table[1].text:find("menu_fetch_more_terms"))
        end)

        it("should show a Menu if terms exist", function()
            plugin.terms = { { name = "Muggle", definition = "Non-magical person" } }
            plugin:showTerms()
            local last = _G.ui_tracker.last_shown
            assert.are.equal("Menu", last.type)
            assert.truthy(last.args.title:find("menu_terms"))
            -- Verify Muggle is in the menu
            local found = false
            for _, item in ipairs(last.args.item_table) do
                if item.text:find("Muggle") then found = true; break end
            end
            assert.is_true(found)
        end)
    end)

    describe("checkSeriesContext", function()
        it("should show ButtonDialog with three options if online and series detected", function()
            -- Mock NetworkMgr
            package.loaded["ui/network/manager"] = {
                isConnected = function() return true end,
                isOnline = function() return true end
            }
            -- Mock series manager detectSeries
            plugin.series_manager = {
                detectSeries = function()
                    return { name = "Mistborn", index = 2, slug = "mistborn" }
                end
            }
            plugin.ai_helper = {
                settings = {
                    series_context_enabled = true
                }
            }
            plugin.book_data = {}

            plugin:checkSeriesContext()

            local last = _G.ui_tracker.last_shown
            assert.is_not_nil(last)
            assert.are.equal("ButtonDialog", last.type)
            assert.is_true(last.args.title:find("series_context_prompt_title") ~= nil)
            
            -- Verify buttons structure (three options: Yes, Later, Don't ask again)
            local buttons = last.args.buttons[1]
            assert.are.equal(3, #buttons)
            assert.are.equal("yes", buttons[1].text)
            assert.are.equal("later", buttons[2].text)
            assert.are.equal("dont_ask_again", buttons[3].text)
        end)

        it("should cache check outcome and not show prompt if series index is 1", function()
            -- Mock NetworkMgr
            package.loaded["ui/network/manager"] = {
                isConnected = function() return true end,
                isOnline = function() return true end
            }
            -- Mock series manager detectSeries
            plugin.series_manager = {
                detectSeries = function()
                    return { name = "Mistborn", index = 1, slug = "mistborn" }
                end
            }
            plugin.ai_helper = {
                settings = {
                    series_context_enabled = true
                }
            }
            plugin.book_data = {}

            -- Mock cache_manager
            local asyncSave_called = false
            plugin.cache_manager = {
                loadCache = function() return {} end,
                asyncSaveCache = function(self_cm, file, data)
                    asyncSave_called = true
                end
            }

            plugin:checkSeriesContext()

            -- Dialog shouldn't have been shown since index <= 1
            local last = _G.ui_tracker.last_shown
            assert.is_nil(last)
            -- Verify cache was saved with series_context_dismissed = true
            assert.is_true(asyncSave_called)
            assert.is_true(plugin.book_data.series_context_dismissed)
        end)

        it("should automatically merge series context offline if all prior books are cached", function()
            -- Mock NetworkMgr as offline
            package.loaded["ui/network/manager"] = {
                isConnected = function() return false end,
                isOnline = function() return false end
            }
            local merge_called = false
            plugin.mergeSeriesContext = function(self_p, cache_data, series_info)
                merge_called = true
            end
            plugin.series_manager = {
                detectSeries = function()
                    return { name = "Mistborn", index = 2, slug = "mistborn" }
                end,
                loadSeriesCache = function(self_sm, slug)
                    return {
                        books = {
                            [1] = {
                                title = "The Final Empire",
                                timeline = { { chapter = "Ch 1", event = "Kelsier" } }
                            }
                        }
                    }
                end
            }
            plugin.ai_helper = {
                settings = {
                    series_context_enabled = true
                }
            }
            plugin.book_data = {}

            plugin:checkSeriesContext()

            assert.is_true(merge_called)
            -- Verify no popup prompt shown because it was merged automatically offline
            local last = _G.ui_tracker.last_shown
            assert.is_nil(last)
        end)
    end)

    describe("clearCache and clearSeriesCache", function()
        it("should reset all in-memory tables and flags on clearCache", function()
            plugin.characters = { { name = "Vin" } }
            plugin.locations = { { name = "Luthadel" } }
            plugin.timeline = { { chapter = "Ch 1", event = "Event" } }
            plugin.historical_figures = { { name = "Person" } }
            plugin.terms = { { name = "Allomancy" } }
            plugin.terms_fetched = true
            plugin.author_info = { name = "Author" }
            plugin.book_data = { series_context_loaded = true, series_slug = "mistborn" }
            plugin.series_context_loaded = true
            plugin.xray_mode_enabled = true

            local clear_file_called = false
            plugin.cache_manager = {
                clearCache = function(self_cm, file)
                    clear_file_called = true
                    return true
                end
            }

            plugin:clearCache()

            assert.is_true(clear_file_called)
            assert.are.equal(0, #plugin.characters)
            assert.are.equal(0, #plugin.locations)
            assert.are.equal(0, #plugin.timeline)
            assert.are.equal(0, #plugin.historical_figures)
            assert.are.equal(0, #plugin.terms)
            assert.is_false(plugin.terms_fetched)
            assert.is_nil(plugin.author_info)
            assert.is_false(plugin.series_context_loaded)
            assert.is_false(plugin.xray_mode_enabled)
            assert.are.same({}, plugin.book_data)
        end)

        it("should clear series cache file and flags on clearSeriesCache", function()
            plugin.series_manager = {
                detectSeries = function()
                    return { name = "Mistborn", index = 2, slug = "mistborn" }
                end,
                getSeriesCachePath = function(self_sm, slug)
                    return "/tmp/koreader/settings/xray/series/mistborn.lua"
                end
            }
            plugin.book_data = {
                series_context_loaded = true,
                series_context_dismissed = true,
                series_slug = "mistborn"
            }
            plugin.series_context_loaded = true

            plugin:clearSeriesCache()

            assert.is_false(plugin.series_context_loaded)
            assert.is_nil(plugin.book_data.series_context_loaded)
            assert.is_nil(plugin.book_data.series_context_dismissed)
        end)
    end)

    describe("scanBookForUnits", function()
        before_each(function()
            os.remove("spec/test_book.epub.sdr/xray_unit_cache.cache")
        end)

        after_each(function()
            os.remove("spec/test_book.epub.sdr/xray_unit_cache.cache")
        end)

        it("should successfully scan document and populate unit_xp_matches", function()
            local xray_unitscanner = require("xray_unitscanner")
            for k, v in pairs(xray_unitscanner) do
                plugin[k] = v
            end
            
            plugin.ai_helper = {
                settings = {
                    unit_converter_enabled = true,
                    unit_underline_enabled = true,
                    unit_underline_style = "solid",
                    unit_conversion_direction = "to_imperial",
                }
            }
            
            local mock_hits = {
                {
                    matched_text = "meters",
                    start = "xp1",
                    ["end"] = "xp2",
                    prev_text = "he walked five ",
                    next_text = " today."
                }
            }
            plugin.ui.document.findAllText = function(self_doc, pat, regex, contextWords, maxResults, returnXPointers)
                -- Only match when it queries the exact meters/metres batch regex pattern
                if pat:find("met") then
                    return mock_hits
                end
                return {}
            end
            plugin.ui.document.getPrevVisibleWordStart = function(self_doc, cand)
                if cand == "xp1" then return "xp_five" end
                return cand
            end
            plugin.ui.document.getTextFromXPointers = function(self_doc, cand, unit_end)
                if cand == "xp_five" and unit_end == "xp2" then return "five meters" end
                if cand == "xp_five" then return "five" end
                return ""
            end
            
            plugin:scanBookForUnits()
            assert.are.equal(1, #plugin.unit_xp_matches)
            assert.are.equal("xp_five", plugin.unit_xp_matches[1].start_xp)
            assert.are.equal("xp2", plugin.unit_xp_matches[1].end_xp)
            assert.are.equal("five meters", plugin.unit_xp_matches[1].original)
        end)

        it("should NOT match false positive '4 will' as a unit conversion", function()
            local xray_unitscanner = require("xray_unitscanner")
            for k, v in pairs(xray_unitscanner) do
                plugin[k] = v
            end
            
            plugin.ai_helper = {
                settings = {
                    unit_converter_enabled = true,
                    unit_underline_enabled = true,
                    unit_underline_style = "solid",
                    unit_conversion_direction = "to_imperial",
                }
            }
            
            local mock_hits = {
                {
                    matched_text = "l",
                    start = "xp1",
                    ["end"] = "xp2",
                    prev_text = "4 wil",
                    next_text = " "
                }
            }
            plugin.ui.document.findAllText = function(self_doc, pat, regex, contextWords, maxResults, returnXPointers)
                return mock_hits
            end
            plugin.ui.document.getPrevVisibleWordStart = function(self_doc, cand)
                if cand == "xp1" then return "xp_four" end
                return cand
            end
            plugin.ui.document.getTextFromXPointers = function(self_doc, cand, unit_end)
                if cand == "xp_four" and unit_end == "xp2" then return "4 will" end
                if cand == "xp_four" then return "4" end
                return ""
            end
            
            plugin:scanBookForUnits()
            assert.are.equal(0, #plugin.unit_xp_matches)
        end)

        it("should successfully scan '80 degrees Celcius' and populate unit_xp_matches", function()
            local xray_unitscanner = require("xray_unitscanner")
            for k, v in pairs(xray_unitscanner) do
                plugin[k] = v
            end
            
            plugin.ai_helper = {
                settings = {
                    unit_converter_enabled = true,
                    unit_underline_enabled = true,
                    unit_underline_style = "solid",
                    unit_conversion_direction = "to_imperial",
                }
            }
            
            local mock_hits = {
                {
                    matched_text = "degrees Celcius",
                    start = "xp1",
                    ["end"] = "xp2",
                    prev_text = "The liquid is at 80 ",
                    next_text = " today."
                }
            }
             plugin.ui.document.findAllText = function(self_doc, pat, regex, contextWords, maxResults, returnXPointers)
                 return mock_hits
             end
            plugin.ui.document.getPrevVisibleWordStart = function(self_doc, cand)
                if cand == "xp1" then return "xp_80" end
                return cand
            end
            plugin.ui.document.getTextFromXPointers = function(self_doc, cand, unit_end)
                if cand == "xp_80" and unit_end == "xp2" then return "80 degrees Celcius" end
                if cand == "xp_80" then return "80" end
                return ""
            end
            
            plugin:scanBookForUnits()
            assert.are.equal(1, #plugin.unit_xp_matches)
            assert.are.equal("xp_80", plugin.unit_xp_matches[1].start_xp)
            assert.are.equal("xp2", plugin.unit_xp_matches[1].end_xp)
            assert.are.equal("80 degrees Celcius", plugin.unit_xp_matches[1].original)
            assert.are.equal("176 °F", plugin.unit_xp_matches[1].converted)
        end)

        it("should successfully scan 'Two 25-liter' and treat it as 25 liters, not 2 liters", function()
            local xray_unitscanner = require("xray_unitscanner")
            for k, v in pairs(xray_unitscanner) do
                plugin[k] = v
            end
            
            plugin.ai_helper = {
                settings = {
                    unit_converter_enabled = true,
                    unit_underline_enabled = true,
                    unit_underline_style = "solid",
                    unit_conversion_direction = "to_imperial",
                }
            }
            
            local mock_hits = {
                {
                    matched_text = "liter",
                    start = "xp1",
                    ["end"] = "xp2",
                    prev_text = "He bought Two 25-",
                    next_text = " bottles."
                }
            }
            plugin.ui.document.findAllText = function(self_doc, pat, regex, contextWords, maxResults, returnXPointers)
                if pat:find("liter") or pat:find("litre") or pat:find("l") then
                    return mock_hits
                end
                return {}
            end
            plugin.ui.document.getPrevVisibleWordStart = function(self_doc, cand)
                if cand == "xp1" then return "xp_25" end
                return cand
            end
            plugin.ui.document.getTextFromXPointers = function(self_doc, cand, unit_end)
                if cand == "xp_25" and unit_end == "xp2" then return "25-liter" end
                if cand == "xp_25" then return "25" end
                return ""
            end
            
            plugin:scanBookForUnits()
            assert.are.equal(1, #plugin.unit_xp_matches)
            assert.are.equal("25-liter", plugin.unit_xp_matches[1].original)
            assert.are.equal("6.6 gallons", plugin.unit_xp_matches[1].converted)
        end)

        it("should successfully scan '37°C' with degree symbol", function()
            local xray_unitscanner = require("xray_unitscanner")
            for k, v in pairs(xray_unitscanner) do
                plugin[k] = v
            end
            
            plugin.ai_helper = {
                settings = {
                    unit_converter_enabled = true,
                    unit_underline_enabled = true,
                    unit_underline_style = "solid",
                    unit_conversion_direction = "to_imperial",
                }
            }
            
            local mock_hits = {
                {
                    matched_text = "°C",
                    start = "xp1",
                    ["end"] = "xp2",
                    prev_text = "The temperature is 37",
                    next_text = "."
                }
            }
            plugin.ui.document.findAllText = function(self_doc, pat, regex, contextWords, maxResults, returnXPointers)
                -- Verify regex pattern allows °C matching without leading word boundary
                assert.is_true(pat:find("°c") ~= nil)
                return mock_hits
            end
            plugin.ui.document.getPrevVisibleWordStart = function(self_doc, cand)
                if cand == "xp1" then return "xp_37" end
                return cand
            end
            plugin.ui.document.getTextFromXPointers = function(self_doc, cand, unit_end)
                if cand == "xp_37" and unit_end == "xp2" then return "37°C" end
                if cand == "xp_37" then return "37" end
                return ""
            end
            
            plugin:scanBookForUnits()
            assert.are.equal(1, #plugin.unit_xp_matches)
            assert.are.equal("37°C", plugin.unit_xp_matches[1].original)
            assert.are.equal("98.6 °F", plugin.unit_xp_matches[1].converted)
        end)

        it("should successfully scan and underline negative temperatures: '-37°C', '−37°C', '- 37°C'", function()
            local xray_unitscanner = require("xray_unitscanner")
            for k, v in pairs(xray_unitscanner) do
                plugin[k] = v
            end
            
            plugin.ai_helper = {
                settings = {
                    unit_converter_enabled = true,
                    unit_underline_enabled = true,
                    unit_underline_style = "solid",
                    unit_conversion_direction = "to_imperial",
                }
            }
            
            -- Test 1: ASCII minus
            local mock_hits1 = {
                {
                    matched_text = "°C",
                    start = "xp1",
                    ["end"] = "xp2",
                    prev_text = "The temperature is -37",
                    next_text = "."
                }
            }
            plugin.ui.document.findAllText = function(self_doc, pat)
                if pat:find("°c") then
                    return mock_hits1
                end
                return {}
            end
            plugin.ui.document.getPrevVisibleWordStart = function(self_doc, cand)
                if cand == "xp1" then return "xp_minus37" end
                return cand
            end
            plugin.ui.document.getTextFromXPointers = function(self_doc, cand, unit_end)
                if cand == "xp_minus37" and unit_end == "xp2" then return "-37°C" end
                if cand == "xp_minus37" then return "-37" end
                return ""
            end
            plugin:scanBookForUnits()
            assert.are.equal(1, #plugin.unit_xp_matches)
            assert.are.equal("-37°C", plugin.unit_xp_matches[1].original)
            assert.are.equal("-34.6 °F", plugin.unit_xp_matches[1].converted)

            -- Test 2: Unicode minus
            local mock_hits2 = {
                {
                    matched_text = "°C",
                    start = "xp1",
                    ["end"] = "xp2",
                    prev_text = "The temperature is −37",
                    next_text = "."
                }
            }
            plugin.ui.document.findAllText = function(self_doc, pat)
                if pat:find("°c") then
                    return mock_hits2
                end
                return {}
            end
            plugin.ui.document.getPrevVisibleWordStart = function(self_doc, cand)
                if cand == "xp1" then return "xp_uni37" end
                return cand
            end
            plugin.ui.document.getTextFromXPointers = function(self_doc, cand, unit_end)
                if cand == "xp_uni37" and unit_end == "xp2" then return "−37°C" end
                if cand == "xp_uni37" then return "−37" end
                return ""
            end
            plugin:scanBookForUnits()
            assert.are.equal(1, #plugin.unit_xp_matches)
            assert.are.equal("−37°C", plugin.unit_xp_matches[1].original)
            assert.are.equal("-34.6 °F", plugin.unit_xp_matches[1].converted)

            -- Test 3: Space after minus
            local mock_hits3 = {
                {
                    matched_text = "°C",
                    start = "xp1",
                    ["end"] = "xp2",
                    prev_text = "The temperature is - 37",
                    next_text = "."
                }
            }
            plugin.ui.document.findAllText = function(self_doc, pat)
                if pat:find("°c") then
                    return mock_hits3
                end
                return {}
            end
            plugin.ui.document.getPrevVisibleWordStart = function(self_doc, cand)
                if cand == "xp1" then return "xp_space37" end
                return cand
            end
            plugin.ui.document.getTextFromXPointers = function(self_doc, cand, unit_end)
                if cand == "xp_space37" and unit_end == "xp2" then return "- 37°C" end
                if cand == "xp_space37" then return "- 37" end
                return ""
            end
            plugin:scanBookForUnits()
            assert.are.equal(1, #plugin.unit_xp_matches)
            assert.are.equal("- 37°C", plugin.unit_xp_matches[1].original)
            assert.are.equal("-34.6 °F", plugin.unit_xp_matches[1].converted)
        end)

        it("should successfully convert 100 kg and 100 g correctly without collisions", function()
            local xray_unitscanner = require("xray_unitscanner")
            for k, v in pairs(xray_unitscanner) do
                plugin[k] = v
            end
            
            plugin.ai_helper = {
                settings = {
                    unit_converter_enabled = true,
                    unit_underline_enabled = true,
                    unit_underline_style = "solid",
                    unit_conversion_direction = "to_imperial",
                }
            }
            
            local mock_hits = {
                {
                    matched_text = "kg",
                    start = "xp1",
                    ["end"] = "xp2",
                    prev_text = "The package weighs 100 ",
                    next_text = " on scale."
                }
            }
            plugin.ui.document.findAllText = function(self_doc, pat, regex, contextWords, maxResults, returnXPointers)
                if pat:find("kg") or pat:find("kilo") then
                    return mock_hits
                end
                if pat:find("g\\b") or pat:find("gram") then
                    return {
                        {
                            matched_text = "g",
                            start = "xp_g",
                            ["end"] = "xp2",
                            prev_text = "The package weighs 100 k",
                            next_text = " on scale."
                        }
                    }
                end
                return {}
            end
            plugin.ui.document.getPrevVisibleWordStart = function(self_doc, cand)
                if cand == "xp1" then return "xp_100" end
                if cand == "xp_g" then return "xp_100_k" end
                return cand
            end
            plugin.ui.document.getTextFromXPointers = function(self_doc, cand, unit_end)
                if cand == "xp_100" and unit_end == "xp2" then return "100 kg" end
                if cand == "xp_100" then return "100" end
                if cand == "xp_100_k" and unit_end == "xp2" then return "100 kg" end
                if cand == "xp_100_k" then return "100 k" end
                return ""
            end
            
            plugin:scanBookForUnits()
            assert.are.equal(1, #plugin.unit_xp_matches)
            assert.are.equal("100 kg", plugin.unit_xp_matches[1].original)
            assert.are.equal("220.46 lb", plugin.unit_xp_matches[1].converted)
        end)

        it("should successfully convert 10 centimetres and .965 kg/l correctly", function()
            local xray_unitscanner = require("xray_unitscanner")
            for k, v in pairs(xray_unitscanner) do
                plugin[k] = v
            end
            
            plugin.ai_helper = {
                settings = {
                    unit_converter_enabled = true,
                    unit_underline_enabled = true,
                    unit_underline_style = "solid",
                    unit_conversion_direction = "to_imperial",
                }
            }
            
            plugin.ui.document.findAllText = function(self_doc, pat, regex, contextWords, maxResults, returnXPointers)
                return {
                    {
                        matched_text = "centimetres",
                        start = "xp_cm_start",
                        ["end"] = "xp_cm_end",
                        prev_text = "The line is 10 ",
                        next_text = " long."
                    },
                    {
                        matched_text = "kg",
                        start = "xp_kg_start",
                        ["end"] = "xp_kg_end",
                        prev_text = "The density is .965 ",
                        next_text = "/l."
                    }
                }
            end
            plugin.ui.document.getPrevVisibleWordStart = function(self_doc, cand)
                if cand == "xp_cm_start" then return "xp_10" end
                if cand == "xp_kg_start" then return "xp_965" end
                return cand
            end
            plugin.ui.document.compareXPointers = function(self_doc, xp1, xp2)
                if xp1 == xp2 then return 0 end
                local pos = {
                    xp_10 = 30,
                    xp_cm_end = 40,
                    xp_965 = 50,
                    xp_kg_end = 60,
                }
                local p1 = pos[xp1] or 0
                local p2 = pos[xp2] or 0
                if p1 < p2 then return 1 end
                if p1 > p2 then return -1 end
                if xp1 < xp2 then return 1 end
                return -1
            end
            plugin.ui.document.getTextFromXPointers = function(self_doc, cand, unit_end)
                if cand == "xp_10" and unit_end == "xp_cm_end" then return "10 centimetres" end
                if cand == "xp_10" then return "10" end
                if cand == "xp_965" and unit_end == "xp_kg_end" then return ".965 kg" end
                if cand == "xp_965" then return ".965" end
                return ""
            end
            
            plugin:scanBookForUnits()
            
            assert.are.equal(2, #plugin.unit_xp_matches)
            
            table.sort(plugin.unit_xp_matches, function(a, b) return a.original < b.original end)
            
            assert.are.equal(".965 kg", plugin.unit_xp_matches[1].original)
            assert.are.equal("2.13 lb", plugin.unit_xp_matches[1].converted)
            
            assert.are.equal("10 centimetres", plugin.unit_xp_matches[2].original)
            assert.are.equal("3.94 inches", plugin.unit_xp_matches[2].converted)
        end)
    end)
    describe("cache operations", function()
        local test_cache_file = "spec/tmp_test_cache.cache"

        before_each(function()
            os.remove(test_cache_file .. "_to_imperial")
            os.remove(test_cache_file .. "_to_metric")
        end)

        after_each(function()
            os.remove(test_cache_file .. "_to_imperial")
            os.remove(test_cache_file .. "_to_metric")
        end)

        it("should correctly save and load the tab-separated cache format", function()
            local xray_unitscanner = require("xray_unitscanner")
            for k, v in pairs(xray_unitscanner) do
                plugin[k] = v
            end

            plugin.ai_helper = {
                settings = {
                    unit_converter_enabled = true,
                    unit_underline_enabled = true,
                    unit_conversion_direction = "to_imperial",
                }
            }

            -- Mock _getUnitCachePath
            local original_getUnitCachePath = plugin._getUnitCachePath
            rawset(plugin, "_getUnitCachePath", function(this, resolved_dir)
                resolved_dir = resolved_dir or _getResolvedDirection(this)
                return test_cache_file .. "_" .. resolved_dir
            end)

            plugin.unit_xp_matches = {
                {
                    start_xp = "xp_1",
                    end_xp = "xp_2",
                    original = "10 cm",
                    converted = "3.94 inches",
                    category = "length"
                },
                {
                    start_xp = "xp_3",
                    end_xp = "xp_4",
                    original = "100\nkg",
                    converted = "220.46\r\nlb",
                    category = "weight"
                }
            }

            -- Save cache
            plugin:saveUnitCache()

            -- Verify file contents exist
            local f = io.open(test_cache_file .. "_to_imperial", "r")
            assert.is_not_nil(f)
            local lines = {}
            for line in f:lines() do
                table.insert(lines, line)
            end
            f:close()

            -- Signature version 31 + settings categories + 2 entries
            assert.are.equal(3, #lines)
            assert.is_true(lines[1]:find("^v30|") ~= nil)
            assert.are.equal("xp_1\txp_2\t10 cm\t3.94 inches\tlength", lines[2])
            assert.are.equal("xp_3\txp_4\t100 kg\t220.46  lb\tweight", lines[3])

            -- Clear and load cache
            plugin.unit_xp_matches = {}
            local loaded = plugin:loadUnitCache()
            assert.is_true(loaded)
            assert.are.equal(2, #plugin.unit_xp_matches)
            assert.are.equal("xp_1", plugin.unit_xp_matches[1].start_xp)
            assert.are.equal("3.94 inches", plugin.unit_xp_matches[1].converted)
            assert.are.equal("100 kg", plugin.unit_xp_matches[2].original)
            assert.are.equal("220.46  lb", plugin.unit_xp_matches[2].converted)
            assert.are.equal("weight", plugin.unit_xp_matches[2].category)

            -- Test signature mismatch invalidation (by checking file path mismatch)
            plugin.ai_helper.settings.unit_conversion_direction = "to_metric"
            local loaded_invalid = plugin:loadUnitCache()
            assert.is_false(loaded_invalid)
        end)
    end)

    describe("showAbout", function()
        it("should successfully initialize M.showAbout card overlay without throwing errors", function()
            local xray_settings_card = require("xray_settings_card")
            local success, err = pcall(function()
                xray_settings_card.showAbout(plugin, "Test Title", "This is a [B]test[/B] about text.")
            end)
            if not success then
                error(err)
            end
            
        end)
    end)

    describe("getAIModelSelectionMenu", function()
        it("should include new models at top of their provider lists", function()
            local menu_items = plugin:getAIModelSelectionMenu("primary")
            assert.is_not_nil(menu_items)
            assert.is_true(#menu_items > 0)

            -- Check for provider sub-menus
            local gemini_item, chatgpt_item, claude_item
            for _, item in ipairs(menu_items) do
                if item.text and item.text:find("Gemini") then gemini_item = item end
                if item.text and item.text:find("ChatGPT") then chatgpt_item = item end
                if item.text and item.text:find("Claude") then claude_item = item end
            end

            assert.is_not_nil(gemini_item)
            assert.is_not_nil(chatgpt_item)
            assert.is_not_nil(claude_item)

            local gemini_menu = gemini_item.sub_item_table_func()
            assert.is_not_nil(gemini_menu[1].text:find("gemini%-3%.7%-flash"))
            assert.is_not_nil(gemini_menu[2].text:find("gemini%-3%.6%-flash"))

            local chatgpt_menu = chatgpt_item.sub_item_table_func()
            assert.is_not_nil(chatgpt_menu[1].text:find("gpt%-5%.6%-terra"))
            assert.is_not_nil(chatgpt_menu[2].text:find("gpt%-5%.6%-luna"))

            local claude_menu = claude_item.sub_item_table_func()
            assert.is_not_nil(claude_menu[1].text:find("claude%-sonnet%-5"))
        end)
    end)

    describe("Welcome Screen & Onboarding Flow", function()
        it("should route showQuickXRayMenu to showWelcomeCard when no API key is set and cache is empty", function()
            plugin.ai_helper.hasApiKey = function() return false end
            plugin.book_data = nil
            plugin:showQuickXRayMenu()
            local last = _G.ui_tracker.last_shown
            assert.is_not_nil(last)
            assert.are.equal("InputContainer", last.type)
        end)

        it("should route showQuickXRayMenu to showFullXRayMenu when key is present", function()
            plugin.ai_helper.hasApiKey = function() return true end
            plugin:showQuickXRayMenu()
            local last = _G.ui_tracker.last_shown
            assert.is_not_nil(last)
            assert.are.equal("Menu", last.type)
        end)

        it("should render showConfigFileGuide dialog with import and wiki options", function()
            plugin:showConfigFileGuide()
            local last = _G.ui_tracker.last_shown
            assert.is_not_nil(last)
            assert.are.equal("InputContainer", last.type)
        end)

        it("should handle welcome actions appropriately", function()
            plugin:handleWelcomeAction("phone_pc")
            local last = _G.ui_tracker.last_shown
            assert.is_not_nil(last)

            plugin:handleWelcomeAction("ereader")
            local last_ereader = _G.ui_tracker.last_shown
            assert.is_not_nil(last_ereader)
            assert.are.equal("ButtonDialog", last_ereader.type)

            -- Test clicking a provider from the picker
            local gemini_btn = last_ereader.args.buttons[1][1]
            assert.is_not_nil(gemini_btn)
            gemini_btn.callback()
            local input_dlg = _G.ui_tracker.last_shown
            assert.is_not_nil(input_dlg)
            assert.are.equal("InputDialog", input_dlg.type)
        end)
    end)

    describe("Clear API Keys Menu", function()
        it("should validate all menu items in getAPIKeysMenu have valid non-nil text and working callbacks", function()
            local items = plugin:getAPIKeysMenu()
            assert.is_not_nil(items)
            
            for idx, item in ipairs(items) do
                assert.is_not_nil(item.text, "Item " .. idx .. " is missing a required text string")
                assert.are.equal("string", type(item.text), "Item " .. idx .. " text is not a string")
                assert.is_true(#item.text > 0, "Item " .. idx .. " has an empty text string")
                if item.text_func then
                    assert.are.equal("function", type(item.text_func))
                    local dynamic_text = item.text_func()
                    assert.is_not_nil(dynamic_text)
                    assert.are.equal("string", type(dynamic_text))
                    assert.is_true(#dynamic_text > 0)
                end
            end

            local clear_item = nil
            for _, item in ipairs(items) do
                if item.text:find("menu_clear_all_keys") or item.text:find("Clear All API Keys") then
                    clear_item = item
                    break
                end
            end
            assert.is_not_nil(clear_item)
            
            -- Trigger callback and check ButtonDialog is shown
            clear_item.callback()
            local last = _G.ui_tracker.last_shown
            assert.is_not_nil(last)
            assert.are.equal("ButtonDialog", last.type)
            local buttons = last.args.buttons[1]
            assert.is_not_nil(buttons)
            local clear_btn = buttons[2]
            assert.is_not_nil(clear_btn)
            assert.are.equal("function", type(clear_btn.callback))

            -- Execute clear button callback to ensure no crashes during clearing
            local ok, err = pcall(clear_btn.callback)
            assert.is_true(ok, "clear_all_keys callback failed: " .. tostring(err))
        end)

        it("should validate all menu items in getProviderKeySubMenu have valid non-nil text and working clear callback", function()
            local items = plugin:getProviderKeySubMenu("gemini", "Google Gemini")
            assert.is_not_nil(items)

            for idx, item in ipairs(items) do
                assert.is_not_nil(item.text, "Provider sub-item " .. idx .. " is missing a required text string")
                assert.are.equal("string", type(item.text), "Provider sub-item " .. idx .. " text is not a string")
                assert.is_true(#item.text > 0, "Provider sub-item " .. idx .. " has an empty text string")
                if item.text_func then
                    assert.are.equal("function", type(item.text_func))
                    local dynamic_text = item.text_func()
                    assert.is_not_nil(dynamic_text)
                    assert.are.equal("string", type(dynamic_text))
                    assert.is_true(#dynamic_text > 0)
                end
            end

            local clear_item = nil
            for _, item in ipairs(items) do
                if item.text:find("Clear") or item.text:find("menu_clear_single_key") then
                    clear_item = item
                    break
                end
            end
            assert.is_not_nil(clear_item)

            -- Trigger callback and check ButtonDialog is shown
            clear_item.callback()
            local last = _G.ui_tracker.last_shown
            assert.is_not_nil(last)
            assert.are.equal("ButtonDialog", last.type)
            local buttons = last.args.buttons[1]
            assert.is_not_nil(buttons)
            local clear_btn = buttons[2]
            assert.is_not_nil(clear_btn)
            assert.are.equal("function", type(clear_btn.callback))

            -- Execute clear button callback to ensure no crashes during clearing
            local ok, err = pcall(clear_btn.callback)
            assert.is_true(ok, "clear_single_key callback failed: " .. tostring(err))
        end)
    end)

    describe("findRelatedEntities with mention snippets", function()
        before_each(function()
            plugin.characters = {
                { name = "Madge Undersee", aliases = { "Madge" } },
                { name = "Mayor of District 12", aliases = { "Madge's father" } },
                { name = "Gale", aliases = {} },
            }
            plugin.locations = {}
            plugin.historical_figures = {}
            plugin.terms = {}
        end)

        it("still links a rewritten description via cached mention snippets", function()
            -- The rewritten description no longer names the Mayor, so the
            -- description alone finds nothing.
            local desc = "The daughter of District 12's mayor who gives Katniss a pin."
            local none = plugin:findRelatedEntities(desc, "Madge Undersee")
            local has_mayor = false
            for _, r in ipairs(none) do
                if r.item.name == "Mayor of District 12" then has_mayor = true end
            end
            assert.is_false(has_mayor)

            -- With the entity's snippets (which say "Madge's father"), the link
            -- comes back.
            local madge = plugin.characters[1]
            madge.mentions = {
                { snippet = "Two of the three chairs fill with Madge's father, Mayor Undersee." },
            }
            local extra = plugin:_mentionScanText(madge)
            local rel = plugin:findRelatedEntities(desc, "Madge Undersee", extra)
            has_mayor = false
            for _, r in ipairs(rel) do
                if r.item.name == "Mayor of District 12" then has_mayor = true end
            end
            assert.is_true(has_mayor)
        end)

        it("returns nil scan text when the entity has no mentions", function()
            assert.is_nil(plugin:_mentionScanText({ name = "X" }))
            assert.is_nil(plugin:_mentionScanText({ name = "X", mentions = {} }))
        end)

        it("accepts sparse and plain-string mention rows", function()
            local ent = { name = "Y", mentions = { [3] = { snippet = "meets Gale" }, [9] = "and Gale again" } }
            local text = plugin:_mentionScanText(ent)
            assert.is_not_nil(text)
            assert.is_truthy(text:find("Gale"))
        end)

        it("does not link the entity to itself through its own snippets", function()
            local madge = plugin.characters[1]
            madge.mentions = { { snippet = "Madge walks straight to me." } }
            local rel = plugin:findRelatedEntities("", "Madge Undersee", plugin:_mentionScanText(madge))
            for _, r in ipairs(rel) do
                assert.are_not.equal("Madge Undersee", r.item.name)
            end
        end)
    end)

    describe("auto-enrich on card open", function()
        local hook_calls

        local function find_texts(w)
            local texts = {}
            local seen = {}
            local function traverse(node)
                if not node or type(node) ~= "table" or seen[node] then return end
                seen[node] = true
                if node.args and node.args.text then
                    table.insert(texts, tostring(node.args.text))
                end
                if node.args and node.args.buttons then
                    for _, row in ipairs(node.args.buttons) do
                        for _, btn in ipairs(row) do
                            if btn.text then table.insert(texts, tostring(btn.text)) end
                        end
                    end
                end
                for k, v in pairs(node) do
                    if type(v) == "table" and k ~= "parent" then traverse(v) end
                end
                if node.args and type(node.args) == "table" then
                    for _, v in ipairs(node.args) do
                        if type(v) == "table" then traverse(v) end
                    end
                end
            end
            traverse(w)
            return texts
        end

        before_each(function()
            hook_calls = {}
            plugin._maybeAutoEnrichEntity = function(_, entity, entity_type)
                table.insert(hook_calls, { entity = entity, entity_type = entity_type })
            end
        end)

        it("triggers the hook with the original entity for the bottom popup", function()
            plugin.ai_helper.settings.ui_popup_intext = true
            local char = { name = "Bob", description = "A builder" }
            plugin:showCharacterDetails(char, { source = "in_text" })
            assert.are.equal(1, #hook_calls)
            assert.are.equal(char, hook_calls[1].entity)
            assert.are.equal("character", hook_calls[1].entity_type)
        end)

        it("triggers the hook for the classic dialog too", function()
            plugin.ai_helper.settings.ui_popup_intext = false
            plugin.ai_helper.settings.ui_popup_menu = false
            local char = { name = "Bob", description = "A builder" }
            plugin:showCharacterDetails(char)
            assert.are.equal(1, #hook_calls)
            assert.are.equal(char, hook_calls[1].entity)
        end)

        it("passes each entity type through its own card", function()
            plugin.ai_helper.settings.ui_popup_intext = false
            plugin.ai_helper.settings.ui_popup_menu = false
            plugin:showLocationDetails({ name = "District 12", description = "d" })
            plugin:showTermDetails({ name = "Tessera", definition = "d" })
            plugin:showHistoricalFigureDetails({ name = "Snow", biography = "b" })
            assert.are.equal("location", hook_calls[1].entity_type)
            assert.are.equal("term", hook_calls[2].entity_type)
            assert.are.equal("historical_figure", hook_calls[3].entity_type)
        end)

        it("renders no Fetch More button on either card style", function()
            local char = { name = "Bob", description = "A builder" }

            plugin.ai_helper.settings.ui_popup_intext = false
            plugin.ai_helper.settings.ui_popup_menu = false
            plugin:showCharacterDetails(char)
            for _, t in ipairs(find_texts(_G.ui_tracker.last_shown)) do
                assert.is_nil(t:find("fetch_more"))
            end

            plugin.ai_helper.settings.ui_popup_intext = true
            plugin:showCharacterDetails(char, { source = "in_text" })
            for _, t in ipairs(find_texts(_G.ui_tracker.last_shown)) do
                assert.is_nil(t:find("fetch_more"))
            end
        end)

        it("tracks the shown entity so a finished enrich can find the card", function()
            plugin.ai_helper.settings.ui_popup_intext = false
            plugin.ai_helper.settings.ui_popup_menu = false
            local char = { name = "Bob", description = "A builder" }
            plugin:showCharacterDetails(char)
            assert.are.equal(char, plugin.active_details_entity)
            assert.are.equal("character", plugin.active_details_entity_type)
        end)
    end)

    describe("_refreshOpenEntityCard", function()
        local reopened

        before_each(function()
            reopened = {}
            plugin._maybeAutoEnrichEntity = function() end
            plugin.showCharacterDetails = function(_, entity, opts)
                table.insert(reopened, { entity = entity, opts = opts })
            end
        end)

        it("re-shows the card when it still shows the enriched entity", function()
            local char = { name = "Bob", description = "Enriched." }
            plugin.active_details_dialog = { type = "ButtonDialog" }
            plugin.active_details_entity = char
            plugin.active_details_entity_type = "character"
            plugin.active_details_opts = { source = "menu" }

            plugin:_refreshOpenEntityCard(char, "character")

            assert.are.equal(1, #reopened)
            assert.are.equal(char, reopened[1].entity)
            assert.are.equal("menu", reopened[1].opts.source)
            assert.is_nil(plugin.active_details_dialog)
        end)

        it("matches by name when the merge landed on a reloaded object", function()
            plugin.active_details_dialog = { type = "ButtonDialog" }
            plugin.active_details_entity = { name = "Bob", description = "old" }
            plugin.active_details_entity_type = "character"

            plugin:_refreshOpenEntityCard({ name = "bob", description = "new" }, "character")

            assert.are.equal(1, #reopened)
        end)

        it("does nothing when the card is closed", function()
            plugin.active_details_dialog = nil
            plugin.active_details_entity = { name = "Bob" }
            plugin.active_details_entity_type = "character"
            plugin:_refreshOpenEntityCard({ name = "Bob" }, "character")
            assert.are.equal(0, #reopened)
        end)

        it("does nothing when the card shows a different entity", function()
            plugin.active_details_dialog = { type = "ButtonDialog" }
            plugin.active_details_entity = { name = "Someone Else" }
            plugin.active_details_entity_type = "character"
            plugin:_refreshOpenEntityCard({ name = "Bob" }, "character")
            assert.are.equal(0, #reopened)
            -- The open card must stay open.
            assert.is_not_nil(plugin.active_details_dialog)
        end)

        it("does nothing when the card shows a different entity type", function()
            plugin.active_details_dialog = { type = "ButtonDialog" }
            plugin.active_details_entity = { name = "Bob" }
            plugin.active_details_entity_type = "location"
            plugin:_refreshOpenEntityCard({ name = "Bob" }, "character")
            assert.are.equal(0, #reopened)
        end)

        it("does nothing when a non-entity card is open (fields cleared)", function()
            -- Author-info and timeline-event cards clear the entity tracking, so
            -- a late enrich for a previously open entity must not pop its card
            -- over the non-entity card the reader now has open.
            plugin.active_details_dialog = { type = "ButtonDialog" }
            plugin.active_details_entity = nil
            plugin.active_details_entity_type = nil
            plugin:_refreshOpenEntityCard({ name = "Bob" }, "character")
            assert.are.equal(0, #reopened)
            assert.is_not_nil(plugin.active_details_dialog)
        end)
    end)

    describe("_persistEntityImage", function()
        local saved

        before_each(function()
            saved = nil
            -- Fake cache manager: capture the saved cache, never touch disk.
            plugin.cache_manager = {
                asyncSaveCache = function(_, _file, cache) saved = cache end,
                loadCache = function() return {} end,
            }
        end)

        it("sets image_path on the exact entity object (identity hit)", function()
            local alice = { name = "Alice" }
            plugin.book_data = { characters = { alice, { name = "Bob" } } }

            local ok = plugin:_persistEntityImage(alice, "character", "/img/alice.jpg")

            assert.is_true(ok)
            assert.are.equal("/img/alice.jpg", alice.image_path)
            assert.is_not_nil(saved)
            assert.are.equal("/img/alice.jpg", saved.characters[1].image_path)
        end)

        it("falls back to a case-insensitive name match on a different object", function()
            plugin.book_data = { locations = { { name = "The Shire" } } }
            -- A distinct entity object with the same name (e.g. from a stale card).
            local card_entity = { name = "the shire" }

            local ok = plugin:_persistEntityImage(card_entity, "location", "/img/shire.png")

            assert.is_true(ok)
            -- The cached list entry (not the passed object) receives the path.
            assert.are.equal("/img/shire.png", saved.locations[1].image_path)
        end)

        it("still saves and keeps the live path when no cache entry matches", function()
            plugin.book_data = { terms = { { name = "Mithril" } } }
            local orphan = { name = "Unknown Term" }

            local ok = plugin:_persistEntityImage(orphan, "term", "/img/orphan.jpg")

            assert.is_true(ok)
            -- Live object keeps the path so the current card renders it...
            assert.are.equal("/img/orphan.jpg", orphan.image_path)
            -- ...but no cached entry was mutated (path is lost on reload).
            assert.is_nil(saved.terms[1].image_path)
        end)

        it("does not attach to an arbitrary entry when the name match is ambiguous", function()
            -- Two cached entries share a name (case-insensitive). A name-only
            -- fallback must not silently pick one, or the image mis-attaches.
            plugin.book_data = { characters = { { name = "John" }, { name = "john" } } }
            local card_entity = { name = "John" }

            local ok = plugin:_persistEntityImage(card_entity, "character", "/img/john.jpg")

            assert.is_true(ok)
            -- Neither same-named cache entry receives the path.
            assert.is_nil(saved.characters[1].image_path)
            assert.is_nil(saved.characters[2].image_path)
            -- The live object still keeps it so the current card renders.
            assert.are.equal("/img/john.jpg", card_entity.image_path)
        end)

        it("returns false when there is no open document", function()
            plugin.ui.document = nil
            local ok = plugin:_persistEntityImage({ name = "Alice" }, "character", "/img/a.jpg")
            assert.is_false(ok)
        end)
    end)

    describe("_isFictionForImage", function()
        it("is true when the book type is fiction", function()
            plugin.book_type = "fiction"
            assert.is_true(plugin:_isFictionForImage())
        end)

        it("is false when the book type is non_fiction", function()
            plugin.book_type = "non_fiction"
            assert.is_false(plugin:_isFictionForImage())
        end)

        it("uses the finer format label when the type is auto/unset", function()
            plugin.book_type = nil
            plugin.getEffectiveBookType = function() return "manga" end
            assert.is_true(plugin:_isFictionForImage())

            plugin.getEffectiveBookType = function() return "textbook" end
            assert.is_false(plugin:_isFictionForImage())
        end)
    end)

    describe("image attach flow", function()
        local ImageSearch = require("xray_imagesearch")
        local saved = {}

        -- Find the first button with the given text across the nested
        -- ButtonDialog rows.
        local function findButton(dialog, text)
            local rows = (dialog and dialog.args and dialog.args.buttons) or {}
            for _, row in ipairs(rows) do
                for _, btn in ipairs(row) do
                    if btn.text == text then return btn end
                end
            end
            return nil
        end

        -- Every shown widget of a given type, in show order.
        local function shownOfType(t)
            local out = {}
            for _, w in ipairs(_G.ui_tracker.shown) do
                if w.type == t then out[#out + 1] = w end
            end
            return out
        end

        before_each(function()
            saved.destPathFor = ImageSearch.destPathFor
            saved.download = ImageSearch.download
            saved.makeVariants = ImageSearch.makeVariants
            saved.searchAndFetchThumbs = ImageSearch.searchAndFetchThumbs
            saved.clearTempDir = ImageSearch.clearTempDir
            saved.getTempDir = ImageSearch.getTempDir
            -- Neutralize disk/network by default; each test overrides as needed.
            ImageSearch.destPathFor = function() return "/sc/character_frodo_1.jpg" end
            ImageSearch.clearTempDir = function() end
            ImageSearch.getTempDir = function() return "/tmp/xray_test" end
            -- Persistence and card refresh are covered elsewhere; keep them inert.
            plugin._reopenEntityCard = function() end
            plugin._persistEntityImage = function(_, entity, etype, img, thumb)
                plugin._persisted = { entity = entity, etype = etype, img = img, thumb = thumb }
                return true
            end
        end)

        after_each(function()
            ImageSearch.destPathFor = saved.destPathFor
            ImageSearch.download = saved.download
            ImageSearch.makeVariants = saved.makeVariants
            ImageSearch.searchAndFetchThumbs = saved.searchAndFetchThumbs
            ImageSearch.clearTempDir = saved.clearTempDir
            ImageSearch.getTempDir = saved.getTempDir
            plugin._persisted = nil
        end)

        describe("showImageAttachFlow", function()
            it("opens a search dialog prefilled with the entity name", function()
                plugin.book_type = "non_fiction"   -- do not append the book title
                plugin:showImageAttachFlow({ name = "Frodo" }, "character")
                local dlg = _G.ui_tracker.last_shown
                assert.are.equal("InputDialog", dlg.type)
                assert.are.equal("Frodo", dlg.args.input)
            end)

            it("does nothing when the entity is missing", function()
                plugin:showImageAttachFlow(nil, "character")
                assert.is_nil(_G.ui_tracker.last_shown)
            end)
        end)

        describe("_runImageSearch", function()
            it("shows a candidate picker when the search returns results", function()
                ImageSearch.searchAndFetchThumbs = function()
                    return { { full = "http://x/a.jpg", title = "A" } }, "duckduckgo"
                end
                plugin:_runImageSearch({ name = "Frodo" }, "character", "Frodo")
                assert.are.equal("ButtonDialog", _G.ui_tracker.last_shown.type)
            end)

            it("shows an error notice when the search fails", function()
                ImageSearch.searchAndFetchThumbs = function()
                    return nil, "duckduckgo", "HTTP 500"
                end
                plugin:_runImageSearch({ name = "Frodo" }, "character", "Frodo")
                local msgs = shownOfType("InfoMessage")
                assert.is_true(#msgs >= 1)
                assert.is_truthy(msgs[#msgs].args.text:find("img_error", 1, true))
            end)

            it("warns when a configured Tavily key fell back to DuckDuckGo", function()
                plugin.ai_helper.tavily_api_key = "tvly-KEY"
                ImageSearch.searchAndFetchThumbs = function()
                    return { { full = "http://x/a.jpg", title = "A" } }, "duckduckgo"
                end
                plugin:_runImageSearch({ name = "Frodo" }, "character", "Frodo")
                local warned = false
                for _, w in ipairs(shownOfType("InfoMessage")) do
                    if w.args.text:find("img_tavily_fallback", 1, true) then warned = true end
                end
                assert.is_true(warned)
            end)

            it("does not warn about fallback when no Tavily key is set", function()
                plugin.ai_helper.tavily_api_key = ""
                ImageSearch.searchAndFetchThumbs = function()
                    return { { full = "http://x/a.jpg", title = "A" } }, "duckduckgo"
                end
                plugin:_runImageSearch({ name = "Frodo" }, "character", "Frodo")
                for _, w in ipairs(shownOfType("InfoMessage")) do
                    assert.is_falsy(w.args.text:find("img_tavily_fallback", 1, true))
                end
            end)
        end)

        describe("_showImageCandidates", function()
            it("wires 'Use This Image' to attach the shown candidate", function()
                local attached
                plugin._attachChosenImage = function(_, entity, etype, url) attached = url end
                local results = {
                    { full = "http://x/a.jpg", title = "A" },
                    { full = "http://x/b.jpg", title = "B" },
                }
                plugin:_showImageCandidates({ name = "Frodo" }, "character", results, "duckduckgo")
                local dlg = plugin._img_candidates_dialog
                assert.is_not_nil(dlg)
                local use = findButton(dlg, plugin.loc:t("img_use_this"))
                assert.is_not_nil(use)
                use.callback()
                assert.are.equal("http://x/a.jpg", attached)
            end)

            it("offers Next but not Previous on the first result", function()
                local results = {
                    { full = "http://x/a.jpg", title = "A" },
                    { full = "http://x/b.jpg", title = "B" },
                }
                plugin:_showImageCandidates({ name = "Frodo" }, "character", results, "duckduckgo")
                local dlg = plugin._img_candidates_dialog
                assert.is_not_nil(findButton(dlg, plugin.loc:t("img_next")))
                assert.is_nil(findButton(dlg, plugin.loc:t("img_prev")))
            end)
        end)

        describe("_attachChosenImage", function()
            it("stores the downscaled variants the resize produced", function()
                ImageSearch.download = function() return true end
                ImageSearch.makeVariants = function()
                    return "/sc/frodo.jpg", "/sc/frodo.thumb.jpg"
                end
                plugin:_attachChosenImage({ name = "Frodo" }, "character", "http://x/a.jpg")
                assert.is_not_nil(plugin._persisted)
                assert.are.equal("/sc/frodo.jpg", plugin._persisted.img)
                assert.are.equal("/sc/frodo.thumb.jpg", plugin._persisted.thumb)
            end)

            it("falls back to the full download when resizing fails", function()
                ImageSearch.download = function() return true end
                ImageSearch.makeVariants = function() return nil, "decode failed" end
                plugin:_attachChosenImage({ name = "Frodo" }, "character", "http://x/a.jpg")
                assert.are.equal("/sc/character_frodo_1.jpg", plugin._persisted.img)
                assert.is_nil(plugin._persisted.thumb)
            end)

            it("shows an error and stores nothing when the download fails", function()
                ImageSearch.download = function() return nil, "HTTP 500" end
                ImageSearch.makeVariants = function()
                    error("must not resize after a failed download")
                end
                plugin:_attachChosenImage({ name = "Frodo" }, "character", "http://x/a.jpg")
                assert.is_nil(plugin._persisted)
                local msgs = shownOfType("InfoMessage")
                assert.is_true(#msgs >= 1)
                assert.is_truthy(msgs[#msgs].args.text:find("img_download_failed", 1, true))
            end)
        end)
    end)
end)

