-- X-Ray AI Fetching and Network Functions

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local logger = require("logger")
local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local utils = require(plugin_path .. "xray_utils")

local function _truncateSafe(text, limit)
    return (utils:getTruncatedText(text, limit))
end


local M = {}

function M:isRequestTimedOut(started_at, timeout_seconds)
    return os.difftime(os.time(), started_at or os.time()) >= timeout_seconds
end

function M:cancelActiveAIRequest(reason)
    if self._active_ai_cancel then
        local ok, err = pcall(self._active_ai_cancel, reason or "AI request cancelled")
        if not ok then
            self:log("XRayPlugin: Active AI cancellation callback failed: " .. tostring(err))
        end
    end
    -- The registered callback may be stale or may have failed before reaching
    -- its owned child. A global lifecycle cancellation must not leave whatever
    -- child the helper currently owns running.
    if self.ai_helper and self.ai_helper._async_child_pid then
        self.ai_helper:cancelAsyncChild()
    end
    self._active_ai_cancel = nil
    if self._active_ai_dialog then
        UIManager:close(self._active_ai_dialog)
        self._active_ai_dialog = nil
    end
    self._active_fetch_generation = nil
    self.bg_fetch_active = false
    self.bg_fetch_pending = false
end

local function sanitizeMetadata(val)
    if type(val) == "string" then return val
    elseif type(val) == "table" then return table.concat(val, ", ")
    else return "Unknown" end
end

function M:fetchFromAI()
    require("ui/network/manager"):runWhenOnline(function() 
        if self.destroyed or not self.ui or not self.ui.document then return end
        local current_page = self.ui:getCurrentPage()
        local total_pages = (type(self.ui.document.getPageCount) == "function" and self.ui.document:getPageCount()) or 1
        local reading_percent = math.floor((current_page / total_pages) * 100)
        local spoiler_setting = self.ai_helper.settings and self.ai_helper.settings.spoiler_setting or "spoiler_free"
        
        if spoiler_setting == "full_book" then
            self:continueWithFetch(100)
        else
            self:continueWithFetch(reading_percent)
        end
    end)
end

function M:updateFromAI()
    require("ui/network/manager"):runWhenOnline(function() 
        if self.destroyed or not self.ui or not self.ui.document then return end
        local current_page = self.ui:getCurrentPage()
        local total_pages = (type(self.ui.document.getPageCount) == "function" and self.ui.document:getPageCount()) or 1
        local reading_percent = math.floor((current_page / total_pages) * 100)
        local spoiler_setting = self.ai_helper.settings and self.ai_helper.settings.spoiler_setting or "spoiler_free"
        
        local last_fetch_page = nil
        if self.book_data and self.book_data.last_fetch_page then
            last_fetch_page = self.book_data.last_fetch_page
        end
        self:log("XRayPlugin: updateFromAI - last_fetch_page=" .. tostring(last_fetch_page))
        
        if spoiler_setting == "full_book" then
            self:continueWithFetch(100, true)
        else
            self:continueWithFetch(reading_percent, true, last_fetch_page)
        end
    end)
end

function M:fetchSingleWord(text, pos0, pos1)
    if type(text) == "table" then
        text = text.text or text.word or text.selection_text or ""
    end
    text = tostring(text or "")

    require("ui/network/manager"):runWhenOnline(function()
        if self.destroyed or not self.ui or not self.ui.document or not self.ui.getCurrentPage then return end

        if self._active_ai_cancel or (self.ai_helper and self.ai_helper._async_child_pid) then
            self:cancelActiveAIRequest("Previous AI request replaced by single word lookup")
        end
        
        local current_page = self.ui:getCurrentPage()
        local total_pages = (type(self.ui.document.getPageCount) == "function" and self.ui.document:getPageCount()) or 1
        local reading_percent = math.floor((current_page / math.max(1, total_pages)) * 100)
        local spoiler_setting = self.ai_helper and self.ai_helper.settings and self.ai_helper.settings.spoiler_setting or "spoiler_free"
        
        local limit_percent = reading_percent
        if spoiler_setting == "full_book" then limit_percent = 100 end

        if self.ai_helper and type(self.ai_helper.hasApiKey) == "function" and not self.ai_helper:hasApiKey() then
            if self.showWelcomeCard then
                self:showWelcomeCard()
            else
                local ButtonDialog = require("ui/widget/buttondialog")
                local title, text_msg = utils:getFriendlyError("error_api", "invalid api key", self.loc)
                local err_dlg
                err_dlg = ButtonDialog:new{
                    title = title,
                    text = text_msg,
                    buttons = {{{ text = self.loc:t("ok") or "OK", callback = function() if err_dlg then UIManager:close(err_dlg) end end }}}
                }
                UIManager:show(err_dlg)
            end
            return
        end

        local ButtonDialog = require("ui/widget/buttondialog")
        local request_pid
        local result_file
        local is_cancelled = false
        local progress_msg
        local function cancelLookup(reason)
            if is_cancelled then return end
            is_cancelled = true
            if request_pid and self.ai_helper and self.ai_helper.cancelAsyncChild then
                self.ai_helper:cancelAsyncChild(request_pid)
            end
            if result_file then pcall(function() os.remove(result_file) end) end
            if progress_msg then UIManager:close(progress_msg) end
            if self._active_ai_dialog == progress_msg then self._active_ai_dialog = nil end
            if self._active_ai_cancel == cancelLookup then self._active_ai_cancel = nil end
            self:log("XRayPlugin: " .. (reason or "Single word lookup cancelled"))
        end
        progress_msg = ButtonDialog:new{
            title = self.loc:t("looking_up_msg", _truncateSafe(text, 30)),
            text = text .. "\n\n" .. (self.loc:t("fetching_wait") or "This may take a moment.\nTap Cancel to stop."),
            tap_close_callback = function() cancelLookup("Single word lookup cancelled by user") end,
            buttons = {{{
                text = self.loc:t("cancel") or "Cancel",
                is_enter_default = true,
                callback = function() cancelLookup("Single word lookup cancelled by user") end,
            }}},
        }
        self._active_ai_dialog = progress_msg
        self._active_ai_cancel = cancelLookup
        UIManager:show(progress_msg)
        UIManager:forceRePaint()

        -- First tick: just let the dialog fully render, then yield back to event loop.
        -- Second tick: start the actual work. This two-step approach ensures the progress
        -- bar borders are fully committed to screen before the CPU starts blocking.
        UIManager:scheduleIn(0.3, function()
            if is_cancelled then return end
            if self.destroyed or not self.ui or not self.ui.document then
                cancelLookup("Single word lookup cancelled because the document or plugin is unavailable")
                return
            end
            UIManager:scheduleIn(0.3, function()
            if is_cancelled then return end
            if self.destroyed or not self.ui or not self.ui.document then
                cancelLookup("Single word lookup cancelled because the document or plugin is unavailable")
                return
            end
            if not self.chapter_analyzer then self.chapter_analyzer = require(plugin_path .. "xray_chapteranalyzer"):new() end
            
            -- 1. Distributed chapter samples (Start/Mid/End of each chapter up to current)
            local samples, chapter_titles = self.chapter_analyzer:getDetailedChapterSamples(self.ui, 100, 60000, limit_percent == 100, nil, nil, current_page)
            
            -- 2. Immediate book text (Previous and Current page for maximum context relevance)
            local end_page = self.chapter_analyzer:getEndPageForCurrentPage(self.ui, current_page)
            local book_text = self.chapter_analyzer:getTextFromPageRange(self.ui, math.max(1, current_page - 1), end_page, 25000)
            
            local context_prefix = "SEARCH TARGET: \"" .. text .. "\"\n"
                .. "IMPORTANT: The reader highlighted exactly this text. It IS a meaningful term from this book.\n"
                .. "Even if the exact phrase does not appear in the page samples below, it was highlighted on the reader's current page. Treat it as a valid term and provide its definition.\n\n"
            book_text = context_prefix .. (book_text or "")
            
            -- Always inject a direct reference to ensure the AI validates the term
            if book_text and text ~= "" then
                book_text = book_text .. "\n\n[TERM HIGHLIGHTED BY READER — MUST DEFINE]: \"" .. text .. "\""
            end
            
            self:log("fetchSingleWord: extracted book_text length: " .. tostring(book_text and #book_text or 0))
            
            local context = {
                reading_percent = limit_percent,
                chapter_samples = samples,
                book_text = book_text
            }

            local DataStorage = require("datastorage")
            local settings_xray_dir = DataStorage:getSettingsDir() .. "/xray"
            
            -- Clean up orphaned fetch files
            self:_sweepStaleFetchFiles(settings_xray_dir)

            if is_cancelled then return end
            if self.destroyed or not self.ui or not self.ui.document then
                cancelLookup("Single word lookup cancelled because the document or plugin is unavailable")
                return
            end

            -- Cancel any existing background fetch child before starting targeted inline fetch
            if self.ai_helper and self.ai_helper._async_child_pid then
                self.ai_helper:cancelAsyncChild()
            end

            result_file = settings_xray_dir .. "/sw_fetch_" .. tostring(os.time()) .. ".json"
            local start_err_code, start_err_msg
            request_pid, start_err_code, start_err_msg = self.ai_helper:lookupSingleWordAsync(text, context, result_file)
            if not request_pid then
                if progress_msg then UIManager:close(progress_msg) end
                if self._active_ai_dialog == progress_msg then self._active_ai_dialog = nil end
                if self._active_ai_cancel == cancelLookup then self._active_ai_cancel = nil end
                self:log("XRayPlugin: Failed to start async lookup: " .. tostring(start_err_msg))
                local ButtonDialog = require("ui/widget/buttondialog")
                -- Forward the build error (e.g. missing API key) when there is one;
                -- fall back to the generic process error otherwise.
                local title, text_msg = utils:getFriendlyError(start_err_code or "error_api",
                    start_err_msg or "Failed to start background process", self.loc)
                local err_dlg
                err_dlg = ButtonDialog:new{
                    title = title,
                    text = text_msg,
                    buttons = {{{ text = self.loc:t("ok") or "OK", callback = function() if err_dlg then UIManager:close(err_dlg) end end }}}
                }
                UIManager:show(err_dlg)
                return
            end

            local request_started_at = os.time()
            local request_timeout = 300
            local function poll()
                if is_cancelled then return end
                if self.destroyed or not self.ui or not self.ui.document then
                    cancelLookup("Single word lookup cancelled because the document or plugin is unavailable")
                    return
                end

                if not self.ai_helper or not self.ai_helper.checkAsyncResult then
                    cancelLookup("Single word lookup stopped because the AI helper is unavailable")
                    return
                end
                local data, p_err_code, p_err_msg = self.ai_helper:checkAsyncResult(result_file, request_pid)
                if data == nil then
                    if not self:isRequestTimedOut(request_started_at, request_timeout) then
                        UIManager:scheduleIn(2, poll)
                    else
                        cancelLookup("Single word lookup timed out")
                        local ButtonDialog = require("ui/widget/buttondialog")
                        local title, text_msg = utils:getFriendlyError("error_timeout", nil, self.loc)
                        local err_dlg
                        err_dlg = ButtonDialog:new{
                            title = title,
                            text = text_msg,
                            buttons = {{{ text = self.loc:t("ok") or "OK", callback = function() if err_dlg then UIManager:close(err_dlg) end end }}}
                        }
                        UIManager:show(err_dlg)
                    end
                elseif data == false then
                    if progress_msg then UIManager:close(progress_msg) end
                    if self._active_ai_dialog == progress_msg then self._active_ai_dialog = nil end
                    if self._active_ai_cancel == cancelLookup then self._active_ai_cancel = nil end
                    self:log("XRayPlugin: Single word lookup failed: " .. tostring(p_err_msg))
                    local ButtonDialog = require("ui/widget/buttondialog")
                    local title, text_msg = utils:getFriendlyError(p_err_code, p_err_msg, self.loc)
                    local err_dlg
                    err_dlg = ButtonDialog:new{
                        title = title,
                        text = text_msg,
                        buttons = {{{ text = self.loc:t("ok") or "OK", callback = function() if err_dlg then UIManager:close(err_dlg) end end }}}
                    }
                    UIManager:show(err_dlg)
                else
                    if progress_msg then
                        UIManager:scheduleIn(0.1, function()
                            UIManager:close(progress_msg)
                            if self._active_ai_dialog == progress_msg then self._active_ai_dialog = nil end
                            if self._active_ai_cancel == cancelLookup then self._active_ai_cancel = nil end
                            if not is_cancelled then
                                self:_processSingleWordResult(data, text, book_text, current_page)
                            end
                        end)
                    elseif not is_cancelled then
                        self:_processSingleWordResult(data, text, book_text, current_page)
                    end
                end
            end
            UIManager:scheduleIn(2, poll)
            end) -- end inner scheduleIn(0.3)
        end) -- end outer scheduleIn(0.3)
    end)
end

-- known_entity / known_type: set by Fetch More. When present, the result enriches
-- THIS existing entity. We route by the caller's type and merge into the exact
-- object, so a name variant or a reclassification from the AI cannot create a
-- duplicate entry in a different list.
function M:_processSingleWordResult(result, text, book_text, current_page, skip_resort, known_entity, known_type, opts)
    if self.destroyed or not self.ui or not self.ui.document then return end
    -- Silent mode (auto-enrich): background work must never surface a dialog.
    -- Errors are logged and dropped; success refreshes the open card in place.
    local silent = opts and opts.silent
    local safe_text = type(text) == "string" and text or tostring(text or "")
    if type(result) ~= "table" then
        local err = self.loc:t("entity_not_found", safe_text:sub(1, 20))
        if silent then return self:log("XRayPlugin: auto-enrich result invalid: " .. tostring(err)) end
        UIManager:show(InfoMessage:new{ text = err, timeout = 5 })
        return
    end

    if result.is_valid then
        local item = result.item
        local item_type = known_type or result.type
        local shown_item = item
        if type(item) ~= "table" or not item.name then
            local err = result.error_message or self.loc:t("entity_not_found", safe_text:sub(1, 20))
            if silent then return self:log("XRayPlugin: auto-enrich result missing item: " .. tostring(err)) end
            UIManager:show(InfoMessage:new{ text = err, timeout = 5 })
            return
        end
        
        -- Ensure tables exist before trying to merge
        self.characters = self.characters or {}
        self.locations = self.locations or {}
        self.historical_figures = self.historical_figures or {}
        self.terms = self.terms or {}

        -- Merge into our tables
        local target_list
        if item_type == "character" then
            target_list = self.characters
        elseif item_type == "location" then
            target_list = self.locations
        elseif item_type == "historical_figure" then
            target_list = self.historical_figures
        elseif item_type == "term" then
            target_list = self.terms
        end

        if target_list then
            -- Resolve current chapter title for history tracking
            local chapter_title = nil
            if self.ui and self.ui.document and current_page then
                local toc = utils:flattenTOC(self.ui.document:getToc())
                if toc then
                    local max_p = -1
                    for _, entry in ipairs(toc) do
                        if entry.page then
                            local p = tonumber(entry.page)
                            if p and p <= current_page and p >= max_p then
                                max_p = p
                                chapter_title = entry.title
                            end
                        end
                    end
                end
            end

            local desc_key = self:_descKeyForType(item_type)

            -- Merge the AI item into an existing entry. On Fetch More, keep the
            -- original entry name so a normalized AI name does not rename it.
            -- Treat an empty string as "no value". The AI can return the key it
            -- was shown with an empty value and the real text under another
            -- key; an empty string is truthy in Lua and would win an `or` chain.
            local function nonEmpty(v)
                if type(v) == "string" and v ~= "" then return v end
                return nil
            end

            local function mergeInto(existing)
                local preserved_name = known_entity and existing.name or nil
                -- Empty means "" or an empty table: a JSON [] decodes to {},
                -- which is truthy and would wipe e.g. a real aliases list.
                local function isEmptyValue(v)
                    return v == "" or (type(v) == "table" and next(v) == nil)
                end
                for k, v in pairs(item) do
                    -- On Fetch More never overwrite a real value with an empty one.
                    if not (known_entity and isEmptyValue(v)) then
                        existing[k] = v
                    end
                end
                if preserved_name then existing.name = preserved_name end

                -- Fetch More forces the chosen entry's own type, so desc_key is
                -- fixed. If the AI classified the word differently and returned
                -- its text under another key (description/biography/definition),
                -- copy that into the forced key. Without this the target field
                -- keeps its old value and the card looks unchanged.
                if known_entity and not nonEmpty(item[desc_key]) then
                    local new_desc = nonEmpty(item.description) or nonEmpty(item.biography) or nonEmpty(item.definition)
                    if new_desc then
                        existing[desc_key] = new_desc
                    end
                end

                -- Fetch More forces one description field for the entry's type. If
                -- the AI returned its text under a different key, drop the other
                -- description-type keys so the cached entry does not accumulate
                -- contradictory description/biography/definition text.
                if known_entity then
                    for _, k in ipairs({ "description", "biography", "definition" }) do
                        if k ~= desc_key then existing[k] = nil end
                    end
                end

                -- Record history for single word lookup
                if existing[desc_key] and existing[desc_key] ~= "" then
                    existing.history = existing.history or {}
                    local dup = false
                    for _, entry in ipairs(existing.history) do
                        if entry.page == current_page then
                            entry[desc_key] = existing[desc_key]
                            entry.chapter = chapter_title or entry.chapter
                            dup = true; break
                        end
                    end
                    if not dup then
                        local hist_entry = { page = current_page, chapter = chapter_title or "" }
                        hist_entry[desc_key] = existing[desc_key]
                        table.insert(existing.history, hist_entry)
                    end
                end

                -- Record how far the book was read when this entry was last
                -- enriched. The auto-enrich staleness gate reads this back.
                if known_entity and type(current_page) == "number" then
                    existing.last_enrich_page = current_page
                end
            end

            -- Check if already exists. On Fetch More (known_entity set), match
            -- ONLY by identity, so a name variant returned by the AI still
            -- enriches the exact chosen entry and a different entry that happens
            -- to share the name cannot be picked instead. Otherwise (single-word
            -- lookup / new entry) match by name (case-insensitive).
            local found = false
            for _, existing in ipairs(target_list) do
                local is_match
                if known_entity then
                    is_match = (existing == known_entity)
                else
                    is_match = (existing.name or ""):lower() == (item.name or ""):lower()
                end
                if is_match then
                    mergeInto(existing)
                    found = true
                    shown_item = existing
                    break
                end
            end

            -- Fetch More identity miss: the list was reloaded during the async
            -- round-trip, so the chosen entry is now a different table instance
            -- and the identity match failed. Fall back to a name match against
            -- the chosen entity so the enrichment still lands on it.
            if not found and known_entity then
                local target_name = (known_entity.name or ""):lower()
                for _, existing in ipairs(target_list) do
                    if (existing.name or ""):lower() == target_name then
                        mergeInto(existing)
                        found = true
                        shown_item = existing
                        break
                    end
                end
                -- Still no match: a known entity must never create a duplicate.
                -- Skip the insert and show the enriched AI item as-is.
                if not found then
                    self:log("XRayPlugin: Fetch More entry not found after reload; skip insert to avoid duplicate")
                    found = true
                end
            end

            if not found then
                if item[desc_key] and item[desc_key] ~= "" then
                    local hist_entry = { page = current_page, chapter = chapter_title or "" }
                    hist_entry[desc_key] = item[desc_key]
                    item.history = { hist_entry }
                end
                table.insert(target_list, item)
            end
            
            -- Sort and save cache. Skip the frequency re-sort when the caller
            -- passes synthetic text (fetch-more). That text only repeats the
            -- focused entity's name, so re-sorting would score every other
            -- entity at zero frequency and stamp a wrong sort_order into cache.
            if not skip_resort then
                self:sortDataByFrequency(target_list, book_text, "name")
            end
            if not self.cache_manager then self.cache_manager = require(plugin_path .. "xray_cachemanager"):new() end
            
            local doc_file = self.ui and self.ui.document and self.ui.document.file
            if not self.book_data then
                self.book_data = (doc_file and self.cache_manager:loadCache(doc_file)) or {}
            end
            local updated = self.book_data
            updated.characters = self.characters
            updated.locations = self.locations
            updated.historical_figures = self.historical_figures
            updated.terms = self.terms
            updated.timeline = self.timeline
            updated.book_type = self.book_type or updated.book_type
            updated.author_info = self.author_info or updated.author_info
            updated.last_fetch_page = updated.last_fetch_page
            
            if doc_file then
                self.cache_manager:asyncSaveCache(doc_file, updated)
            end
        end
        
        -- Always show result if it's valid, even if it didn't merge into a target_list.
        -- On a merge, show the enriched entry (its preserved name), not the raw AI item.
        if silent then
            -- Auto-enrich: refresh the card only if it is still open and still
            -- shows this entity; never open a new one.
            if type(self._refreshOpenEntityCard) == "function" then
                pcall(function() self:_refreshOpenEntityCard(shown_item, item_type) end)
            end
        else
            self.lookup_manager:showResult(shown_item, item_type)
        end
    else
        local err = result.error_message or self.loc:t("entity_not_found", safe_text:sub(1, 20))
        if silent then return self:log("XRayPlugin: auto-enrich failed: " .. tostring(err)) end
        UIManager:show(InfoMessage:new{ text = err, timeout = 5 })
    end
end

-- Map an entity type to the field that holds its main text. Kept in one place
-- so single-word lookup, Fetch More, and context building stay in step.
function M:_descKeyForType(item_type)
    return (item_type == "historical_figure" and "biography")
        or (item_type == "term" and "definition")
        or "description"
end

-- Remove stale orphaned fetch result files from the xray settings directory.
-- checkAsyncResult removes the file on a normal poll, but a stale poll or an
-- app close can leave one behind. Single-word lookup and Fetch More share the
-- "sw_fetch_" prefix, so only sweep old orphans. A concurrent request's result
-- file is recent; an age gate past the request timeout (300s) keeps it while it
-- still clears real orphans.
function M:_sweepStaleFetchFiles(dir)
    pcall(function()
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        if not ok or type(lfs) ~= "table" then
            ok, lfs = pcall(require, "lfs")
        end
        if ok and lfs and lfs.dir then
            local now = os.time()
            for file in lfs.dir(dir) do
                if file:find("^sw_fetch_.*%.json$") then
                    local path = dir .. "/" .. file
                    local mtime = lfs.attributes and lfs.attributes(path, "modification")
                    if not mtime or (now - mtime) > 600 then
                        os.remove(path)
                    end
                end
            end
        end
    end)
end

-- Resolve which X-Ray list an entity belongs to. The card usually passes the
-- type; this is the fallback when it does not.
function M:_inferEntityType(entity)
    if not entity then return "character" end
    local name = (entity.name or ""):lower()
    local function inList(list)
        if type(list) ~= "table" then return false end
        for _, e in ipairs(list) do
            if type(e) == "table" and (e.name or ""):lower() == name then return true end
        end
        return false
    end
    -- Prefer the list the entity actually lives in. A character or location can
    -- carry a stray definition/biography key; that must not route it to the wrong
    -- list. Only fall back to field shape when the entity is in no list yet.
    if inList(self.terms) then return "term" end
    if inList(self.historical_figures) then return "historical_figure" end
    if inList(self.locations) then return "location" end
    if inList(self.characters) then return "character" end
    if entity.definition ~= nil then return "term" end
    if entity.biography ~= nil then return "historical_figure" end
    return "character"
end

-- Build the AI context for a Fetch More (enrich) request. Pure function so the
-- assembly logic can be tested without the UI or a live document.
--   entity        : the entity table (has name + a description/biography/definition)
--   entity_type   : "character" | "location" | "historical_figure" | "term"
--   passages      : list of mention rows ({snippet=...}) or plain strings
--   samples       : distributed chapter samples string (optional)
--   limit_percent : reading percent, for spoiler bounding downstream
-- Returns: context table, book_text string
function M:_buildEnrichContext(entity, entity_type, passages, samples, limit_percent)
    local name = tostring(entity.name or "")
    local desc_key = self:_descKeyForType(entity_type)
    local existing_desc = entity[desc_key] or entity.description or entity.biography or entity.definition or ""

    -- Targeted passages: the sentences where the entity actually appears.
    -- Bounded so a very common name cannot blow up the request size.
    local parts = {}
    local budget = 18000
    local seen = {}
    for _, m in ipairs(passages or {}) do
        local s = (type(m) == "table") and m.snippet or m
        -- Skip a snippet that does not fit; do not stop. One long early snippet
        -- must not drop every later (possibly more relevant) passage.
        -- Skip exact duplicates so a name repeated on adjacent pages does not
        -- spend the budget on the same text and crowd out distinct passages.
        if type(s) == "string" and #s > 0 and not seen[s] and budget - #s >= 0 then
            seen[s] = true
            table.insert(parts, s)
            budget = budget - #s
        end
    end
    local passage_text = table.concat(parts, "\n")

    -- Preserve links across the rewrite. Linked-entry detection keys on names in
    -- the description; a rewrite can drop a name the old entry had and hide the
    -- link. We list the currently related entities and ask the rewrite to keep
    -- naming them. Guarded because the pure helper is unit-tested without the UI
    -- mixin that defines findRelatedEntities.
    local preserve_names = {}
    if type(self.findRelatedEntities) == "function" then
        local extra = (type(self._mentionScanText) == "function") and self:_mentionScanText(entity) or nil
        local rel = self:findRelatedEntities(existing_desc or "", name, extra) or {}
        for _, r in ipairs(rel) do
            if r.item and r.item.name then table.insert(preserve_names, r.item.name) end
        end
    end

    local header = "FOCUS ENTITY: \"" .. name .. "\"\n"
        .. "TASK: Improve and expand the existing entry for this entity using the passages below, where it actually appears in the book.\n"
        .. "Combine what is already known with the new details into one cohesive summary about THIS entity.\n"
        .. "Describe other people or places only as they relate to this entity, not as the main subject.\n"
    if #preserve_names > 0 then
        header = header .. "Keep naming these related entities where they are relevant: "
            .. table.concat(preserve_names, ", ") .. ".\n"
    end
    header = header .. "\n"
    if existing_desc ~= "" then
        header = header .. "EXISTING ENTRY FOR " .. name .. ":\n" .. existing_desc .. "\n\n"
    end
    local book_text = header
    if passage_text ~= "" then
        book_text = book_text .. "PASSAGES MENTIONING " .. name .. ":\n" .. passage_text
    end

    local context = {
        reading_percent = limit_percent,
        chapter_samples = samples,
        book_text = book_text,
    }
    -- Trigger MERGE MODE for the types that support it, so the AI is told it is
    -- updating a known entry rather than defining a fresh term.
    if entity_type == "character" then
        context.existing_characters = { entity }
    elseif entity_type == "location" then
        context.existing_locations = { entity }
    elseif entity_type == "historical_figure" then
        context.existing_historical_figures = { entity }
    elseif entity_type == "term" then
        context.existing_terms = { entity }
    end

    return context, book_text
end

-- Rank mention passages by relevance before the enrich budget is spent, so the
-- best passages win the 18KB budget instead of whichever came first by page.
-- Score favors (a) dense stretches of the book where the entity appears a lot
-- and (b) recency: mentions near the entity's last appearance and near the
-- reader's current position. The selection is returned in page order because
-- the prompt reads better chronologically. Pure function so it can be tested
-- without the UI or a live document.
--   mentions : list of mention rows ({page=..., snippet=...}) or plain strings
--   opts     : { current_page, total_pages, budget }
-- Returns: budget-bounded, deduplicated, chronologically ordered mention list.
function M:_rankEnrichPassages(mentions, opts)
    if type(mentions) ~= "table" or #mentions == 0 then return {} end
    opts = opts or {}
    local total_pages = math.max(1, tonumber(opts.total_pages) or 1)
    local current_page = tonumber(opts.current_page) or 0
    local budget = tonumber(opts.budget) or 18000

    -- Bucket mentions into page windows (~2.5% of the book each) so a cluster
    -- of nearby mentions scores as one dense region.
    local window = math.max(5, math.ceil(total_pages / 40))
    local density, max_density = {}, 0
    local rows = {}
    local last_page = 0
    for i, m in ipairs(mentions) do
        local snippet = (type(m) == "table") and m.snippet or m
        local page = (type(m) == "table") and tonumber(m.page) or nil
        if type(snippet) == "string" and #snippet > 0 then
            local bucket
            if page then
                bucket = math.floor((page - 1) / window)
                density[bucket] = (density[bucket] or 0) + 1
                if density[bucket] > max_density then max_density = density[bucket] end
                if page > last_page then last_page = page end
            end
            table.insert(rows, { m = m, snippet = snippet, page = page, bucket = bucket, idx = i })
        end
    end
    if #rows == 0 then return {} end

    -- Linear proximity falloff over 15% of the book around an anchor page.
    local span = math.max(1, total_pages * 0.15)
    local function prox(p, anchor)
        return math.max(0, 1 - math.abs(p - anchor) / span)
    end
    for _, r in ipairs(rows) do
        if r.page and max_density > 0 then
            r.score = (density[r.bucket] / max_density)
                + 0.8 * prox(r.page, last_page)
                + 0.6 * prox(r.page, current_page)
        else
            -- A page-less mention cannot be placed in the book; keep it only
            -- when budget remains after every placeable passage.
            r.score = -1
        end
    end

    -- Chronological tiebreak: page ascending, page-less passages last, then the
    -- original index. Shared by the ranking sort and the final emit sort so both
    -- order equal inputs the same way.
    local function byPageThenIdx(a, b)
        local pa, pb = a.page or math.huge, b.page or math.huge
        if pa ~= pb then return pa < pb end
        return a.idx < b.idx
    end

    -- Deterministic order: score descending, then the chronological tiebreak,
    -- so equal inputs always produce the same selection.
    table.sort(rows, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return byPageThenIdx(a, b)
    end)

    -- Greedy fill: best first. Dedup on exact snippet text (the same rule as
    -- _buildEnrichContext) so a repeated sentence cannot spend the budget.
    local seen, picked = {}, {}
    for _, r in ipairs(rows) do
        if not seen[r.snippet] and budget - #r.snippet >= 0 then
            seen[r.snippet] = true
            budget = budget - #r.snippet
            table.insert(picked, r)
        end
    end

    -- Emit chronologically; page-less passages go last, in input order.
    table.sort(picked, byPageThenIdx)
    local out = {}
    for _, r in ipairs(picked) do table.insert(out, r.m) end
    return out
end

-- Fetch More: enrich ONE existing entity's entry using passages from across the
-- book where the entity actually appears. This reads wider than the reader's
-- current page, so the entity is described from its real scenes and not only
-- from wherever the reader happened to open its card.
--
-- Read scope follows the spoiler setting: spoiler-free caps the scan at the
-- current reading position; full-book scans the whole book. The improved text
-- is written back through the same merge path a single-word lookup uses, so the
-- existing entry and the new details combine into one rewritten summary.
function M:fetchMoreDetailsForEntity(entity, entity_type, opts)
    if not entity or not entity.name then return end
    -- Silent mode (auto-enrich on card open): no dialogs, no wifi prompt, no
    -- ConfirmBox; every blocked path is a logged skip. Auto-enrich is the only
    -- production caller, so it always runs silent. The non-silent branch
    -- (progress dialog, busy-slot ConfirmBox, interactive error) has no shipping
    -- caller after the Fetch More buttons were removed, but stays in place: the
    -- fetch specs still drive it, and it is the entry point if an interactive
    -- caller returns. Keep it silent-safe on any change here.
    local silent = opts and opts.silent

    -- Auto-enrich marks the entity attempted before it schedules this fetch. If a
    -- silent run bails out WITHOUT firing a request (no key, offline, slot busy),
    -- clear that mark so a later open of the same card can retry this session.
    local function allowRetry()
        local k = opts and opts.auto_enrich_key
        if k and self._auto_enrich_attempted then
            self._auto_enrich_attempted[k] = nil
        end
    end

    local function startFetch()
        if self.destroyed or not self.ui or not self.ui.document or not self.ui.getCurrentPage then return end

        entity_type = entity_type or self:_inferEntityType(entity)

        if not self.ai_helper then
            local AIHelper = require(plugin_path .. "xray_aihelper")
            self.ai_helper = AIHelper
            self.ai_helper:init(self.path)
        end

        if silent then
            -- Stricter than the interactive gate: a missing hasApiKey (partial
            -- or mocked environment) must no-op instead of proceeding.
            if not (self.ai_helper and type(self.ai_helper.hasApiKey) == "function" and self.ai_helper:hasApiKey()) then
                allowRetry()
                return self:log("XRayPlugin: auto-enrich skipped: no API key")
            end
        elseif self.ai_helper and type(self.ai_helper.hasApiKey) == "function" and not self.ai_helper:hasApiKey() then
            if self.showWelcomeCard then self:showWelcomeCard() end
            return
        end

        if self._active_ai_cancel or (self.ai_helper and self.ai_helper._async_child_pid) then
            if silent then
                allowRetry()
                return self:log("XRayPlugin: auto-enrich skipped: another AI request is active")
            end
            -- A comprehensive fetch can run for many minutes; replacing it
            -- silently would throw that work away. Ask before cancelling it.
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = self.loc:t("fetch_more_replace_confirm"),
                ok_text = self.loc:t("fetch_more"),
                ok_callback = function()
                    self:cancelActiveAIRequest("Previous AI request replaced by fetch-more")
                    self:fetchMoreDetailsForEntity(entity, entity_type, opts)
                end,
            })
            return
        end

        -- A background enrich must yield to a user-initiated Find Mentions, not
        -- steal its scan slot (the shared-slot claim below cancels the holder).
        if silent and self.active_mention_scan then
            allowRetry()
            return self:log("XRayPlugin: auto-enrich skipped: a mention scan is active")
        end

        local current_page = self.ui:getCurrentPage()
        local total_pages = (type(self.ui.document.getPageCount) == "function" and self.ui.document:getPageCount()) or 1
        local spoiler_setting = self.ai_helper and self.ai_helper.settings and self.ai_helper.settings.spoiler_setting or "spoiler_free"
        local full_book = (spoiler_setting == "full_book")
        -- limit_percent is set later from the real scan range end, which is the
        -- reader's current page, so the reading percent matches the text it sees.

        local request_pid
        local result_file
        local is_cancelled = false
        local scan_handle
        local slot_handle  -- this fetch's registration in the shared mention-scan slot
        local progress_msg

        local cancelFetch  -- forward-declared so closeProgress can reference it
        local function closeProgress()
            if progress_msg then
                UIManager:close(progress_msg)
                if self._active_ai_dialog == progress_msg then self._active_ai_dialog = nil end
                progress_msg = nil
            end
            if self._active_ai_cancel == cancelFetch then
                self._active_ai_cancel = nil
            end
            -- Release the cancel closure (and everything it captures: entity,
            -- book_text, passages, dialog, scan handle) once this fetch ends, so
            -- it does not linger on the plugin until the next Fetch More.
            if self._fetch_more_cancel == cancelFetch then
                self._fetch_more_cancel = nil
            end
        end

        local function showError(err_code, err_msg)
            if silent then
                return self:log("XRayPlugin: auto-enrich error (suppressed dialog): "
                    .. tostring(err_code) .. " " .. tostring(err_msg))
            end
            local ButtonDialog2 = require("ui/widget/buttondialog")
            local title, text_msg = utils:getFriendlyError(err_code, err_msg, self.loc)
            local err_dlg
            err_dlg = ButtonDialog2:new{
                title = title,
                text = text_msg,
                buttons = {{{ text = self.loc:t("ok") or "OK", callback = function() if err_dlg then UIManager:close(err_dlg) end end }}}
            }
            UIManager:show(err_dlg)
        end

        cancelFetch = function(reason)
            if is_cancelled then return end
            is_cancelled = true
            if scan_handle and scan_handle.cancel then
                pcall(function() scan_handle:cancel() end)
            end
            -- Release the shared mention-scan slot if this fetch holds it.
            if slot_handle and self.active_mention_scan and self.active_mention_scan.cancel_handle == slot_handle then
                self.active_mention_scan = nil
            end
            if request_pid and self.ai_helper and self.ai_helper.cancelAsyncChild then
                self.ai_helper:cancelAsyncChild(request_pid)
            end
            if result_file then pcall(function() os.remove(result_file) end) end
            closeProgress()
            self:log("XRayPlugin: " .. (reason or "Fetch-more cancelled"))
        end
        self._fetch_more_cancel = cancelFetch

        if not silent then
            progress_msg = ButtonDialog:new{
                title = self.loc:t("fetch_more_progress") or "Fetching more details...",
                text = tostring(entity.name) .. "\n\n" .. (self.loc:t("fetching_wait") or "This may take a moment.\nTap Cancel to stop."),
                buttons = {{{
                    text = self.loc:t("cancel") or "Cancel",
                    callback = function() cancelFetch("Fetch-more cancelled by user") end,
                }}},
            }
            self._active_ai_dialog = progress_msg
            UIManager:show(progress_msg)
            UIManager:forceRePaint()
        end
        -- Registered even in silent mode: destroy and suspend cancel through
        -- this handle, which is what stops a background request from running on
        -- (and draining) a sleeping device.
        self._active_ai_cancel = cancelFetch

        -- Two ticks so the dialog is painted before any blocking extraction.
        UIManager:scheduleIn(0.3, function()
            if is_cancelled then return end
            if self.destroyed or not self.ui or not self.ui.document then return cancelFetch("Fetch-more stopped: document unavailable") end
            if not self.chapter_analyzer then self.chapter_analyzer = require(plugin_path .. "xray_chapteranalyzer"):new() end

            -- Spoiler-free must have a page bound. If the helper cannot resolve one
            -- (no current page), stop instead of scanning the whole book and
            -- leaking passages past the reader's position.
            local max_page = nil
            if not full_book then
                max_page = self.chapter_analyzer:getEndPageForCurrentPage(self.ui, current_page) or current_page
                if not max_page then
                    return cancelFetch("Fetch-more stopped: cannot resolve spoiler bound")
                end
            end

            -- Spoiler bound: base the reading percent on the scan range end, which
            -- is the reader's current page (one page ahead for reflowable books),
            -- so it matches the text range the AI actually receives.
            -- For reflowable books max_page can be one past the current page and
            -- reach or pass the page count near the end, so clamp to 100.
            local limit_percent = full_book and 100
                or math.min(100, math.floor((max_page / math.max(1, total_pages)) * 100))

            -- Phase 2: build context from the gathered passages and run the AI.
            local function runEnrich(passages)
                if is_cancelled then return end
                -- Guard against a second entry (e.g. the scan's completion callback
                -- firing twice after a coroutine error). One request per fetch.
                if request_pid then return end
                if self.destroyed or not self.ui or not self.ui.document then return cancelFetch("Fetch-more stopped: document unavailable") end

                -- Rank before the samples check: ranking also dedups, so a
                -- duplicate-heavy mention list can shrink below the fallback
                -- threshold and still get chapter samples as backup signal.
                passages = self:_rankEnrichPassages(passages, {
                    current_page = current_page,
                    total_pages = total_pages,
                    budget = 18000,
                })

                -- The distributed whole-book samples are a heavy extraction (up to
                -- 100 chapters). The targeted passages are the primary signal for
                -- enriching one entry, so only pay for samples when the passages
                -- are too few to rely on.
                local samples = nil
                if not passages or #passages < 3 then
                    samples = self.chapter_analyzer:getDetailedChapterSamples(self.ui, 100, 40000, full_book, nil, nil, current_page)
                end
                local context, book_text = self:_buildEnrichContext(entity, entity_type, passages, samples, limit_percent)

                local DataStorage = require("datastorage")
                local settings_xray_dir = DataStorage:getSettingsDir() .. "/xray"

                -- Clean up orphaned fetch files. A fetch-more-only user would
                -- never hit the single-word sweep, so sweep here too.
                self:_sweepStaleFetchFiles(settings_xray_dir)

                result_file = settings_xray_dir .. "/sw_fetch_" .. tostring(os.time()) .. ".json"

                local start_err_code, start_err_msg
                request_pid, start_err_code, start_err_msg = self.ai_helper:lookupSingleWordAsync(entity.name, context, result_file)
                if not request_pid then
                    cancelFetch("Failed to start fetch-more request: " .. tostring(start_err_msg))
                    -- Forward the build error (e.g. missing API key) when there is
                    -- one; fall back to the generic process error otherwise.
                    showError(start_err_code or "error_api", start_err_msg or "Failed to start background process")
                    return
                end

                local started_at = os.time()
                local function poll()
                    if is_cancelled then return end
                    if self.destroyed or not self.ui or not self.ui.document then return cancelFetch("Fetch-more stopped: document unavailable") end
                    if not self.ai_helper or not self.ai_helper.checkAsyncResult then return cancelFetch("Fetch-more stopped: AI helper unavailable") end

                    local data, p_err_code, p_err_msg = self.ai_helper:checkAsyncResult(result_file, request_pid)
                    if data == nil then
                        if not self:isRequestTimedOut(started_at, 300) then
                            UIManager:scheduleIn(2, poll)
                        else
                            cancelFetch("Fetch-more timed out")
                            showError("error_timeout", nil)
                        end
                    elseif data == false then
                        closeProgress()
                        self:log("XRayPlugin: Fetch-more failed: " .. tostring(p_err_msg))
                        showError(p_err_code, p_err_msg)
                    else
                        closeProgress()
                        if not is_cancelled then
                            self:_processSingleWordResult(data, entity.name, book_text, current_page, true, entity, entity_type, opts)
                        end
                    end
                end
                UIManager:scheduleIn(2, poll)
            end

            -- Phase 1: gather the entity's passages. Reuse cached mentions when
            -- they already cover the range the reader can see; otherwise scan the
            -- unread remainder (spoiler-aware) and persist it, so Find Mentions
            -- and Fetch More share one scan.

            -- Cached mentions can reach further into the book than the reader's
            -- current position. In spoiler-free mode, drop any that pass max_page
            -- before reuse, mirroring the scan path's page filter in
            -- scanMentionsAsync.
            local function usableMentions(list)
                if type(list) ~= "table" then return {} end
                if full_book or not max_page then return list end
                local usable = {}
                for _, m in ipairs(list) do
                    if not (m.page and m.page > (max_page + 5)) then
                        table.insert(usable, m)
                    end
                end
                return usable
            end

            -- entity.last_mention_page records how far an earlier scan actually
            -- read (math.huge = whole book). A cache that stops short of the
            -- reader's position is a stale partial scan, not a substitute for the
            -- book-wide passage scan; scan the unread part from where it stopped.
            local last_scanned = entity.last_mention_page
            local cache_covers_range = last_scanned == math.huge
                or (max_page ~= nil and type(last_scanned) == "number" and last_scanned >= max_page)
            -- A cache that covers the range is authoritative (this mirrors the
            -- needs_scan test in xray_mentions.lua): a rescan would find the same
            -- passages. runEnrich falls back to chapter samples when there are
            -- fewer than 3 passages.
            if cache_covers_range then
                runEnrich(usableMentions(entity.mentions))
            else
                local scan_min_page = nil
                if type(last_scanned) == "number" and last_scanned ~= math.huge then
                    scan_min_page = last_scanned
                end
                local toc = utils:flattenTOC(self.ui.document.getToc and self.ui.document:getToc())
                -- Claim the mention-scan slot shared with Find Mentions
                -- (xray_mentions.lua): cancel whatever scan is running and
                -- register this one, so the two paths can never scan the same
                -- entity concurrently and each persist the same mentions.
                -- Register a wrapper handle: an outside cancel (Find Mentions
                -- switching to another entity, plugin teardown) must stop the
                -- whole fetch, or its progress dialog would wait forever on a
                -- scan that will never complete.
                if self.active_mention_scan and self.active_mention_scan.cancel_handle then
                    pcall(function() self.active_mention_scan.cancel_handle:cancel() end)
                end
                slot_handle = { cancel = function()
                    cancelFetch("Fetch-more scan cancelled by another mention scan")
                end }
                self.active_mention_scan = { entity_name = entity.name, chapter_idx = 0, total_chapters = #(toc or {}), cancel_handle = slot_handle }
                scan_handle = self.chapter_analyzer:scanMentionsAsync(
                    self.ui, entity, toc, scan_min_page, max_page,
                    function(_, chapter_idx, total_chapters)
                        local rec = self.active_mention_scan
                        if rec and rec.cancel_handle == slot_handle then
                            rec.chapter_idx = chapter_idx
                            rec.total_chapters = total_chapters
                            if self.mentions_menu and type(self.updateMentionsMenuInPlace) == "function" then
                                self:updateMentionsMenuInPlace(entity)
                            end
                        end
                    end,
                    function(found)
                        if self.active_mention_scan and self.active_mention_scan.cancel_handle == slot_handle then
                            self.active_mention_scan = nil
                        end
                        scan_handle = nil
                        if is_cancelled then return end

                        -- Persist the scan on the entity (mirrors the Find Mentions
                        -- completion in xray_mentions.lua) so the next Find Mentions
                        -- or Fetch More does not rescan the same range.
                        entity.mentions = entity.mentions or {}
                        utils:appendUniqueMentions(entity.mentions, found)
                        table.sort(entity.mentions, function(a, b) return (a.page or 0) < (b.page or 0) end)
                        entity.last_mention_page = max_page or math.huge
                        if type(self.saveMentionsToCache) == "function" then
                            pcall(function() self:saveMentionsToCache() end)
                        end

                        local passages = usableMentions(entity.mentions)

                        -- This callback runs inside the scan coroutine. If the
                        -- enrich step raised here, the scanner would report the
                        -- error and call on_complete again, starting a second
                        -- request. Defer to the next UI tick so the coroutine
                        -- finishes cleanly first.
                        UIManager:scheduleIn(0, function()
                            if is_cancelled then return end
                            runEnrich(passages)
                        end)
                    end
                )
            end
        end)
    end

    if silent then
        -- Background trigger: test connectivity without the wifi prompt, the
        -- same way the background merge fetch does in main.lua.
        local net_ok, NetworkMgr = pcall(require, "ui/network/manager")
        if not net_ok or type(NetworkMgr) ~= "table"
            or type(NetworkMgr.isConnected) ~= "function" or type(NetworkMgr.isOnline) ~= "function" then
            allowRetry()
            return
        end
        local ok, online = pcall(function() return NetworkMgr:isConnected() and NetworkMgr:isOnline() end)
        if not ok or not online then
            allowRetry()
            return self:log("XRayPlugin: auto-enrich skipped: offline")
        end
        startFetch()
    else
        require("ui/network/manager"):runWhenOnline(startFetch)
    end
end

-- Auto-enrich: opening an entity card triggers the enrich above silently when
-- the entry is thin or stale. This replaced the manual Fetch More card button.

-- The page at which this entity was last enriched. Falls back to the history
-- pages written by _processSingleWordResult, then to the comprehensive fetch
-- position, so entries from older caches are not treated as never-enriched.
function M:_lastEnrichPage(entity)
    if type(entity.last_enrich_page) == "number" then return entity.last_enrich_page end
    local max_p
    if type(entity.history) == "table" then
        for _, h in ipairs(entity.history) do
            local p = tonumber(h.page)
            if p and (not max_p or p > max_p) then max_p = p end
        end
    end
    if max_p then return max_p end
    local last_fetch = self.book_data and tonumber(self.book_data.last_fetch_page)
    return last_fetch or 0
end

-- Enrich when the entry is thin (main text well under the user's target
-- length) or stale (the reader moved well past the last enrich point, so new
-- material exists). Pure predicate; returns ok, reason ("thin"|"stale"|nil).
function M:_shouldAutoEnrich(entity, entity_type, current_page, total_pages)
    local s = self.ai_helper and self.ai_helper.settings or {}
    local target
    if entity_type == "location" then
        target = tonumber(s.loc_desc_len) or 100
    elseif entity_type == "historical_figure" then
        target = tonumber(s.hist_fig_bio_len) or 100
    elseif entity_type == "term" then
        target = tonumber(s.term_def_len) or 100
    else
        target = tonumber(s.char_desc_len) or 200
    end
    local desc = entity[self:_descKeyForType(entity_type)]
    if type(desc) ~= "string" or #desc < math.floor(target * 0.6) then
        return true, "thin"
    end
    local stale_gap = math.max(20, math.floor((tonumber(total_pages) or 0) * 0.10))
    if (tonumber(current_page) or 0) - self:_lastEnrichPage(entity) >= stale_gap then
        return true, "stale"
    end
    return false, nil
end

-- The on-card-open hook. Never shows UI; every blocked path is a silent skip.
-- Called by every entity details card in xray_ui.lua.
function M:_maybeAutoEnrichEntity(entity, entity_type)
    if not entity or not entity.name or entity.name == "" then return end
    if entity.is_timeline or entity.is_conversion then return end
    if self.destroyed or not self.ui or not self.ui.document or not self.ui.getCurrentPage then return end

    -- Auto-enrich spends a metered AI call on card open, so it must be opt-out.
    -- Honor an explicit setting; when unset, default on, but OFF on the slowest
    -- hardware (PW1-class), where an unprompted request per card open is too
    -- costly. The user can override either way from settings.
    local settings = (self.ai_helper and self.ai_helper.settings) or {}
    local enabled = settings.auto_enrich_cards
    if enabled == nil then
        enabled = not (type(utils.isLowPowerDevice) == "function" and utils:isLowPowerDevice())
    end
    if not enabled then
        return self:log("XRayPlugin: auto-enrich disabled (setting or low-power device)")
    end

    entity_type = entity_type or self:_inferEntityType(entity)

    -- One attempt per entity per session (the plugin instance dies with the
    -- document), so a failed request or a short AI answer cannot re-fire on
    -- every card open.
    self._auto_enrich_attempted = self._auto_enrich_attempted or {}
    local key = entity_type .. ":" .. tostring(entity.name):lower()
    if self._auto_enrich_attempted[key] then return end

    -- Busy: another AI request or a mention scan owns the single slot. Skip
    -- WITHOUT marking attempted, so the next card open can retry.
    if self._active_ai_cancel or (self.ai_helper and self.ai_helper._async_child_pid) or self.active_mention_scan then
        return
    end

    local ok_page, current_page = pcall(function() return self.ui:getCurrentPage() end)
    if not ok_page or type(current_page) ~= "number" then return end
    local total_pages = (type(self.ui.document.getPageCount) == "function" and self.ui.document:getPageCount()) or 1

    local should, reason = self:_shouldAutoEnrich(entity, entity_type, current_page, total_pages)
    if not should then return end

    self._auto_enrich_attempted[key] = true
    self:log("XRayPlugin: auto-enrich queued (" .. tostring(reason) .. "): " .. tostring(entity.name))
    -- Let the card paint first; e-ink repaints are slow, and the fetch itself
    -- staggers another 0.3s before any blocking extraction.
    UIManager:scheduleIn(0.8, function()
        if self.destroyed or not self.ui or not self.ui.document then return end
        if self._active_ai_cancel or (self.ai_helper and self.ai_helper._async_child_pid) or self.active_mention_scan then
            -- The slot was taken while waiting; allow a retry on the next open.
            self._auto_enrich_attempted[key] = nil
            return
        end
        self:fetchMoreDetailsForEntity(entity, entity_type, { silent = true, auto_enrich_key = key })
    end)
end

function M:continueWithFetch(reading_percent, is_update, last_fetch_page, is_silent)
    if self.destroyed or not self.ui or not self.ui.document then return end
    local doc_file = self.ui.document.file
    if not doc_file then return end

    local has_active_request = self._active_ai_cancel
        or (self.ai_helper and self.ai_helper._async_child_pid)
    if is_silent and has_active_request then
        self.bg_fetch_pending = false
        self:log("XRayPlugin: Skipping background fetch because another AI request is active")
        return
    elseif not is_silent and has_active_request then
        self:cancelActiveAIRequest("Previous AI request replaced by manual fetch")
    end
    self._fetch_generation = (self._fetch_generation or 0) + 1
    local fetch_generation = self._fetch_generation
    self._active_fetch_generation = fetch_generation
    self.bg_fetch_active = true

    local function clearFetchState()
        if self._active_fetch_generation == fetch_generation then
            self._active_fetch_generation = nil
            self.bg_fetch_active = false
        end
    end

    if not self.ai_helper then
        local AIHelper = require(plugin_path .. "xray_aihelper")
        self.ai_helper = AIHelper
        self.ai_helper:init(self.path)
    end

    -- Invalidate timeline if the current timeline length setting is greater than what was cached
    if not self.cache_manager then self.cache_manager = require(plugin_path .. "xray_cachemanager"):new() end
    local cached = self.book_data or self.cache_manager:loadCache(doc_file)
    if cached and cached.timeline and #cached.timeline > 0 then
        local s = self.ai_helper and self.ai_helper.settings or {}
        local current_len = s.timeline_event_len or 80
        local cached_len = cached.timeline_event_len or 80
        if current_len > cached_len then
            self:log("XRayPlugin: timeline_event_len increased from " .. tostring(cached_len) .. " to " .. tostring(current_len) .. ". Regenerating timeline.")
            self.timeline = {}
            cached.timeline = {}
            if self.book_data then
                self.book_data.timeline = {}
            end
        end
    end

    local props = self.ui.document:getProps() or {}
    local title = sanitizeMetadata(props.title)
    local author = sanitizeMetadata(props.authors)

    -- For manual (non-silent) fetches, show a ButtonDialog with a Cancel button.
    -- We use the async path for ALL fetches so we never need Trapper:dismissableRunInSubprocess
    -- (which requires an InfoMessage widget and breaks with ButtonDialog).
    local wait_msg
    local is_cancelled = false
    local result_file
    local request_pid
    local cancelActiveRequest

    local function finishActiveRequest()
        request_pid = nil
        result_file = nil
        clearFetchState()
        if self._active_ai_dialog == wait_msg then self._active_ai_dialog = nil end
        if self._active_ai_cancel == cancelActiveRequest then self._active_ai_cancel = nil end
    end

    cancelActiveRequest = function(reason)
        if is_cancelled then return end
        is_cancelled = true
        if request_pid and self.ai_helper and self.ai_helper.cancelAsyncChild then
            self.ai_helper:cancelAsyncChild(request_pid)
        end
        if result_file then
            pcall(function() os.remove(result_file) end)
        end
        if wait_msg then
            UIManager:close(wait_msg)
        end
        finishActiveRequest()
        self:log("XRayPlugin: " .. reason)
    end

    self._active_ai_cancel = cancelActiveRequest

    if not is_silent then
        local ButtonDialog = require("ui/widget/buttondialog")
        local fetch_text = is_update
            and (self.loc:t("updating_ai", self.ai_provider or "AI") or "Updating X-Ray...")
            or  (self.loc:t("fetching_ai",  self.ai_provider or "AI") or ("Fetching from %s..."):format(self.ai_provider or "AI"))
        wait_msg = ButtonDialog:new{
            title = fetch_text,
            text  = title .. "\n\n" .. (self.loc:t("fetching_wait") or "This may take a moment.\nTap Cancel to stop."),
            tap_close_callback = function()
                cancelActiveRequest("Fetch cancelled by user")
            end,
            buttons = {{{
                text = self.loc:t("cancel") or "Cancel",
                is_enter_default = true,
                callback = function()
                    cancelActiveRequest("Fetch cancelled by user")
                end
            }}}
        }
        self._active_ai_dialog = wait_msg
        UIManager:show(wait_msg)
    end

    UIManager:scheduleIn(0.5, function()
        if is_cancelled or self.destroyed or not self.ui or not self.ui.document then
            clearFetchState()
            cancelActiveRequest(self.destroyed
                and "Fetch stopped because plugin was destroyed"
                or "Fetch stopped because the document was closed")
            return
        end
        if not self.chapter_analyzer then self.chapter_analyzer = require(plugin_path .. "xray_chapteranalyzer"):new() end

        local current_page = self.ui:getCurrentPage()
        local first_missing_page = last_fetch_page
        if is_update then
            local toc = utils:flattenTOC(self.ui.document:getToc())
            local candidate_chapters = {}
            for i = #toc, 1, -1 do
                local entry = toc[i]
                if entry.page and entry.page <= current_page then
                    if not self:isNonNarrativeChapter(entry.title) then
                        table.insert(candidate_chapters, entry)
                        if #candidate_chapters >= 3 then break end
                    end
                end
            end
            for _, entry in ipairs(candidate_chapters) do
                local norm = self:normalizeChapterName(entry.title)
                local found = false
                for _, ev in ipairs(self.timeline or {}) do
                    if self:normalizeChapterName(ev.chapter or "") == norm then
                        if not ev.page or ev.page == entry.page then found = true; break end
                    end
                end
                if not found then
                    if not first_missing_page or entry.page < first_missing_page then
                        first_missing_page = entry.page
                        self:log("XRayPlugin: Repair mode active: recovering missing chapter '" .. tostring(entry.title) .. "' starting at page " .. tostring(entry.page))
                    end
                end
            end
        end

        local end_page_analysis = current_page
        local spoiler_setting = self.ai_helper and self.ai_helper.settings and self.ai_helper.settings.spoiler_setting or "spoiler_free"
        if spoiler_setting ~= "full_book" then
            end_page_analysis = self.chapter_analyzer:getEndPageForCurrentPage(self.ui, current_page)
        end
        local book_text = self.chapter_analyzer:getTextForAnalysis(self.ui, 20000, nil, end_page_analysis, first_missing_page)
        local known_chapters = {}
        if is_update and self.timeline then
            for _, ev in ipairs(self.timeline) do
                if ev.chapter then known_chapters[self:normalizeChapterName(ev.chapter)] = true end
            end
        end

        UIManager:scheduleIn(0, function()
            if is_cancelled or self.destroyed or not self.ui or not self.ui.document then
                clearFetchState()
                cancelActiveRequest(self.destroyed
                    and "Fetch stopped because plugin was destroyed"
                    or "Fetch stopped because the document was closed")
                return
            end

            -- A cached page can outlive pagination changes or be ahead of the
            -- reader's current position. In that case an incremental XPointer
            -- range would be empty/reversed; use the current chapter context.
            local stale_cached_position = false
            if first_missing_page and first_missing_page > end_page_analysis then
                stale_cached_position = true
                self:log("XRayPlugin: Ignoring stale last_fetch_page=" .. tostring(first_missing_page)
                    .. " beyond analysis boundary=" .. tostring(end_page_analysis))
                first_missing_page = nil
            end

            local samples, chapter_titles = self.chapter_analyzer:getDetailedChapterSamples(
                self.ui, 200, 150000, reading_percent == 100, first_missing_page, known_chapters, current_page)
            local annots = self.chapter_analyzer:getAnnotationsForAnalysis(self.ui)

            if (not book_text or #book_text < 10) and not samples then
                if wait_msg then UIManager:close(wait_msg) end
                local message = self.loc:t("error_extract_text") or "Error: Could not extract book text."
                if is_update and stale_cached_position then
                    local translated = self.loc:t("no_new_text")
                    message = (translated and translated ~= "no_new_text") and translated
                        or "No new text was available at your current position; X-Ray is already up to date here."
                end
                if not is_silent then UIManager:show(InfoMessage:new{ text = message, timeout = 5 }) end
                self:log("XRayPlugin: Text extraction failed" .. (is_silent and " (silent)" or ""))
                finishActiveRequest()
                return
            end

            local context = {
                reading_percent = reading_percent,
                spoiler_free = reading_percent < 100,
                filename = self.ui.document.file:match("([^/\\]+)$"),
                series = props.series or props.Series,
                chapter_samples = samples,
                chapter_titles = chapter_titles,
                annotations = annots,
                book_text = book_text,
                existing_characters = is_update and self.characters or nil,
                existing_locations = is_update and self.locations or nil,
                existing_historical_figures = is_update and self.historical_figures or nil,
                book_type = self.book_type,
            }

            local req_params, err_code, err_msg = self.ai_helper:buildComprehensiveRequest(title, author, context)
            if not req_params then
                if wait_msg then UIManager:close(wait_msg) end
                self:log("XRayPlugin: Failed to build request: " .. tostring(err_msg))
                finishActiveRequest()
                if not is_silent then
                    if not self.ai_helper:hasApiKey() and self.showWelcomeCard then
                        self:showWelcomeCard()
                    else
                        local ButtonDialog = require("ui/widget/buttondialog")
                        local title, text = utils:getFriendlyError(err_code, err_msg, self.loc)
                        local err_box
                        err_box = ButtonDialog:new{
                            title = title,
                            text = text,
                            buttons = {{{ text = self.loc:t("ok") or "OK", callback = function() if err_box then UIManager:close(err_box) end end }}}
                        }
                        UIManager:show(err_box)
                    end
                end
                return
            end

            local DataStorage = require("datastorage")
            local settings_xray_dir = DataStorage:getSettingsDir() .. "/xray"

            -- Clean up any orphaned fetch files from previous cancelled/timed-out fetches in this session
            pcall(function()
                local ok, lfs = pcall(require, "libs/libkoreader-lfs")
                if not ok or type(lfs) ~= "table" then
                    ok, lfs = pcall(require, "lfs")
                end
                if ok and lfs and lfs.dir then
                    for file in lfs.dir(settings_xray_dir) do
                        if file:find("^bg_fetch_.*%.json$") then
                            os.remove(settings_xray_dir .. "/" .. file)
                        end
                    end
                end
            end)

            result_file = settings_xray_dir .. "/bg_fetch_" .. tostring(os.time()) .. "_" .. tostring(fetch_generation) .. ".json"
            local started = self.ai_helper:makeRequestAsync(req_params, result_file)
            if not started then
                if wait_msg then UIManager:close(wait_msg) end
                self:log("XRayPlugin: Failed to start async fetch")
                pcall(function() os.remove(result_file) end)
                result_file = nil
                finishActiveRequest()
                return
            end
            request_pid = started

            local request_started_at = os.time()
            local request_timeout = 600
            local function poll()
                if is_cancelled then return end
                if self.destroyed then
                    cancelActiveRequest("Fetch stopped because plugin was destroyed")
                    return
                end
                if not self.ui or not self.ui.document then
                    cancelActiveRequest("Fetch stopped because the document was closed")
                    return
                end
                local data, p_err_code, p_err_msg = self.ai_helper:checkAsyncResult(result_file, request_pid)
                if data == nil then
                    if not self:isRequestTimedOut(request_started_at, request_timeout) then
                        UIManager:scheduleIn(2, poll)
                    else
                        cancelActiveRequest("Fetch timed out")
                        if not is_silent then
                            local ButtonDialog = require("ui/widget/buttondialog")
                            local title, text = utils:getFriendlyError("error_timeout", nil, self.loc)
                            local err_box
                            err_box = ButtonDialog:new{
                                title = title,
                                text = text,
                                buttons = {{{ text = self.loc:t("ok") or "OK", callback = function() if err_box then UIManager:close(err_box) end end }}}
                            }
                            UIManager:show(err_box)
                        end
                    end
                elseif data == false then
                    if wait_msg then UIManager:close(wait_msg) end
                    finishActiveRequest()
                    self:log("XRayPlugin: Fetch failed: " .. tostring(p_err_msg))
                    if not is_silent then
                        local ButtonDialog = require("ui/widget/buttondialog")
                        local title, text = utils:getFriendlyError(p_err_code, p_err_msg, self.loc)
                        local err_box
                        err_box = ButtonDialog:new{
                            title = title,
                            text = text,
                            buttons = {{{ text = self.loc:t("ok") or "OK", callback = function() if err_box then UIManager:close(err_box) end end }}}
                        }
                        UIManager:show(err_box)
                    end
                else
                    if wait_msg then UIManager:close(wait_msg) end
                    finishActiveRequest()
                    self:finalizeXRayData(data, title, author, book_text, is_update, is_silent, current_page)
                end
            end
            UIManager:scheduleIn(2, poll)
        end)
    end)
end


function M:finalizeXRayData(final_book_data, title, author, book_text, is_update, is_silent, current_page)
    if self.destroyed or not self.ui or not self.ui.document then return end
    final_book_data.book_title = title
    final_book_data.author = author

    -- Frequency Sorting
    final_book_data.characters = self:sortDataByFrequency(final_book_data.characters, book_text, "name")
    final_book_data.historical_figures = self:sortDataByFrequency(final_book_data.historical_figures, book_text, "name")
    final_book_data.locations = self:sortDataByFrequency(final_book_data.locations, book_text, "name")
    final_book_data.terms = self:deduplicateByName(final_book_data.terms or {}, "name")
    final_book_data.terms = self:sortDataByFrequency(final_book_data.terms, book_text, "name")

    -- Filter non-narrative timeline entries the AI may have hallucinated
    if final_book_data.timeline then
        local filtered_timeline = {}
        for _, ev in ipairs(final_book_data.timeline) do
            if not self:isNonNarrativeChapter(ev.chapter) then
                table.insert(filtered_timeline, ev)
            else
                self:log("XRayPlugin: Filtered non-narrative timeline entry: " .. tostring(ev.chapter))
            end
        end
        final_book_data.timeline = filtered_timeline
    end

    -- Guard: never overwrite existing data with an all-empty result
    local char_count = #(final_book_data.characters or {})
    local loc_count  = #(final_book_data.locations or {})
    local tl_count   = #(final_book_data.timeline or {})
    local hist_count = #(final_book_data.historical_figures or {})
    local term_count = #(final_book_data.terms or {})

    if char_count == 0 and loc_count == 0 and tl_count == 0 and hist_count == 0 and term_count == 0 then
        self:log("XRayPlugin: AI returned all-empty data — aborting cache write to protect existing data")
        if not is_silent then
            local msg = "The AI returned no data.\n\nThis usually means the book sample was too short. Try reading further into the book, then fetch again."
            UIManager:show(InfoMessage:new{ text = msg, timeout = 8 })
        end
        self.bg_fetch_active = false
        return  -- do NOT touch self.characters / self.locations / cache
    end

    -- Resolve current chapter title for history tracking
    local chapter_title = nil
    if self.ui and self.ui.document and current_page then
        local toc = utils:flattenTOC(self.ui.document:getToc())
        if toc then
            local max_p = -1
            for _, entry in ipairs(toc) do
                if entry.page then
                    local p = tonumber(entry.page)
                    if p and p <= current_page and p >= max_p then
                        max_p = p
                        chapter_title = entry.title
                    end
                end
            end
        end
    end

    if is_update then
        -- Ensure tables exist before attempting to merge/insert
        self.characters = self.characters or {}
        self.historical_figures = self.historical_figures or {}
        self.locations = self.locations or {}
        self.timeline = self.timeline or {}

        -- Merge characters
        for _, new_char in ipairs(final_book_data.characters or {}) do
            local found = false
            for _, existing_char in ipairs(self.characters) do
                if existing_char.name:lower() == new_char.name:lower() then
                    existing_char.role = new_char.role
                    -- Replace existing description with the AI's rewritten cohesive summary
                    if new_char.description and new_char.description ~= "" then
                        existing_char.description = new_char.description
                        
                        -- Record history
                        existing_char.history = existing_char.history or {}
                        local dup = false
                        for _, entry in ipairs(existing_char.history) do
                            if entry.page == current_page then
                                entry.description = new_char.description
                                entry.chapter = chapter_title or entry.chapter
                                dup = true
                                break
                            end
                        end
                        if not dup then
                            table.insert(existing_char.history, {
                                page = current_page,
                                chapter = chapter_title or "",
                                description = new_char.description
                            })
                        end
                    end
                    found = true
                    break
                end
            end
            if not found then
                if new_char.description and new_char.description ~= "" then
                    new_char.history = {
                        {
                            page = current_page,
                            chapter = chapter_title or "",
                            description = new_char.description
                        }
                    }
                end
                table.insert(self.characters, new_char)
            end
        end
        -- Dedup then re-sort the entire character list by frequency in the current context
        self.characters = self:deduplicateByName(self.characters, "name")
        if book_text and #book_text > 0 then
            self:sortDataByFrequency(self.characters, book_text, "name")
        end
        -- Merge historical figures
        for _, new_fig in ipairs(final_book_data.historical_figures or {}) do
            local found = false
            for _, existing_fig in ipairs(self.historical_figures or {}) do
                if existing_fig.name:lower() == new_fig.name:lower() then
                    if new_fig.biography and new_fig.biography ~= "" then
                        existing_fig.biography = new_fig.biography
                        
                        -- Record history
                        existing_fig.history = existing_fig.history or {}
                        local dup = false
                        for _, entry in ipairs(existing_fig.history) do
                            if entry.page == current_page then
                                entry.biography = new_fig.biography
                                entry.chapter = chapter_title or entry.chapter
                                dup = true
                                break
                            end
                        end
                        if not dup then
                            table.insert(existing_fig.history, {
                                page = current_page,
                                chapter = chapter_title or "",
                                biography = new_fig.biography
                            })
                        end
                    end
                    existing_fig.role = new_fig.role
                    found = true
                    break
                end
            end
            if not found then
                if new_fig.biography and new_fig.biography ~= "" then
                    new_fig.history = {
                        {
                            page = current_page,
                            chapter = chapter_title or "",
                            biography = new_fig.biography
                        }
                    }
                end
                table.insert(self.historical_figures, new_fig)
            end
        end
        self.historical_figures = self:deduplicateByName(self.historical_figures, "name")
        -- Merge locations
        for _, new_loc in ipairs(final_book_data.locations or {}) do
            local found = false
            for _, existing_loc in ipairs(self.locations or {}) do
                if existing_loc.name:lower() == new_loc.name:lower() then
                    if new_loc.description and new_loc.description ~= "" then
                        existing_loc.description = new_loc.description
                        
                        -- Record history
                        existing_loc.history = existing_loc.history or {}
                        local dup = false
                        for _, entry in ipairs(existing_loc.history) do
                            if entry.page == current_page then
                                entry.description = new_loc.description
                                entry.chapter = chapter_title or entry.chapter
                                dup = true
                                break
                            end
                        end
                        if not dup then
                            table.insert(existing_loc.history, {
                                page = current_page,
                                chapter = chapter_title or "",
                                description = new_loc.description
                            })
                        end
                    end
                    found = true
                    break
                end
            end
            if not found then
                if new_loc.description and new_loc.description ~= "" then
                    new_loc.history = {
                        {
                            page = current_page,
                            chapter = chapter_title or "",
                            description = new_loc.description
                        }
                    }
                end
                table.insert(self.locations, new_loc)
            end
        end
        self.locations = self:deduplicateByName(self.locations, "name")
        -- Merge terms
        self.terms = self.terms or {}
        for _, new_term in ipairs(final_book_data.terms or {}) do
            local found = false
            for _, existing in ipairs(self.terms) do
                if existing.name:lower() == new_term.name:lower() then
                    if new_term.definition and new_term.definition ~= "" then
                        existing.definition = new_term.definition
                    end
                    existing.expanded = new_term.expanded
                    existing.aliases = new_term.aliases
                    found = true; break
                end
            end
            if not found then table.insert(self.terms, new_term) end
        end
        self.terms = self:deduplicateByName(self.terms, "name")
        if book_text and #book_text > 0 then
            self:sortDataByFrequency(self.terms, book_text, "name")
        end
        -- Merge book_type
        if final_book_data.book_type then
            self.book_type = final_book_data.book_type
        end

        -- Segregate series_prior timeline items from current book timeline items
        local prior_timeline = {}
        local current_timeline = {}
        for _, ev in ipairs(self.timeline or {}) do
            if ev.source == "series_prior" then
                table.insert(prior_timeline, ev)
            else
                table.insert(current_timeline, ev)
            end
        end

        local toc = self.ui and self.ui.document and self.ui.document.getToc and self.ui.document:getToc() or {}
        local incoming_timeline = final_book_data.timeline or {}
        self:assignTimelinePages(incoming_timeline, toc, true)

        for _, new_event in ipairs(incoming_timeline) do
            local found = false
            local new_norm = self:normalizeChapterName(new_event.chapter or "")
            for _, existing_event in ipairs(current_timeline) do
                local exist_norm = self:normalizeChapterName(existing_event.chapter or "")
                if new_norm == exist_norm then
                    if new_event.page and existing_event.page and
                       tonumber(new_event.page) == tonumber(existing_event.page) then
                        existing_event.event = new_event.event or existing_event.event
                        existing_event.chapter = new_event.chapter or existing_event.chapter
                        found = true
                        break
                    end
                end
            end
            if not found then table.insert(current_timeline, new_event) end
        end

        self.timeline = {}
        for _, ev in ipairs(current_timeline) do table.insert(self.timeline, ev) end
        for _, ev in ipairs(prior_timeline) do table.insert(self.timeline, ev) end
        self:sortTimelineByTOC(self.timeline)
    else
        self.characters = final_book_data.characters
        for _, char in ipairs(self.characters or {}) do
            if char.description and char.description ~= "" then
                char.history = char.history or {
                    {
                        page = current_page,
                        chapter = chapter_title or "",
                        description = char.description
                    }
                }
            end
        end
        self.historical_figures = final_book_data.historical_figures
        for _, fig in ipairs(self.historical_figures or {}) do
            if fig.biography and fig.biography ~= "" then
                fig.history = fig.history or {
                    {
                        page = current_page,
                        chapter = chapter_title or "",
                        biography = fig.biography
                    }
                }
            end
        end
        self.locations = final_book_data.locations
        for _, loc in ipairs(self.locations or {}) do
            if loc.description and loc.description ~= "" then
                loc.history = loc.history or {
                    {
                        page = current_page,
                        chapter = chapter_title or "",
                        description = loc.description
                    }
                }
            end
        end
        self.terms = final_book_data.terms or {}
        self.book_type = final_book_data.book_type

        -- Preserve series_prior items when non-merge update/fetch overwrites current timeline
        local prior_timeline = {}
        for _, ev in ipairs(self.timeline or {}) do
            if ev.source == "series_prior" then
                table.insert(prior_timeline, ev)
            end
        end

        local current_timeline = final_book_data.timeline or {}
        local toc = self.ui and self.ui.document and self.ui.document.getToc and self.ui.document:getToc() or {}
        self:assignTimelinePages(current_timeline, toc, true)

        self.timeline = {}
        for _, ev in ipairs(current_timeline) do table.insert(self.timeline, ev) end
        for _, ev in ipairs(prior_timeline) do table.insert(self.timeline, ev) end
        self:sortTimelineByTOC(self.timeline)
    end

    -- If we don't have author info in memory, check if the cache already has it
    if not self.author_info then
        if not self.cache_manager then self.cache_manager = require(plugin_path .. "xray_cachemanager"):new() end
        local doc_file = (self.ui and self.ui.document) and self.ui.document.file
        local existing = (doc_file and self.cache_manager:loadCache(doc_file)) or self.book_data
        if existing and existing.author_info then
            self.author_info = existing.author_info
        end
    end

    if not self.book_data then
        local doc_file = (self.ui and self.ui.document) and self.ui.document.file
        self.book_data = (doc_file and self.cache_manager:loadCache(doc_file)) or {}
    end
    local updated_data = self.book_data
    updated_data.book_title = title
    updated_data.author = author
    updated_data.characters = self.characters
    updated_data.historical_figures = self.historical_figures
    updated_data.locations = self.locations
    updated_data.terms = self.terms
    updated_data.book_type = self.book_type or updated_data.book_type
    updated_data.timeline = self.timeline
    updated_data.author_info = self.author_info or updated_data.author_info
    updated_data.last_fetch_page = current_page
    
    local s = self.ai_helper and self.ai_helper.settings or {}
    updated_data.timeline_event_len = s.timeline_event_len or 80

    self.book_data = updated_data

    if not self.cache_manager then self.cache_manager = require(plugin_path .. "xray_cachemanager"):new() end
    local doc_file = (self.ui and self.ui.document) and self.ui.document.file
    local cache_saved = doc_file and self.cache_manager:asyncSaveCache(doc_file, updated_data)

    -- If book is part of a series, update this book's entry in SeriesCache
    if self.series_manager and (updated_data.series_slug or (self.ui and self.ui.document)) then
        pcall(function()
            local props = self.ui and self.ui.document and self.ui.document:getProps() or {}
            local series_info = self.series_manager:detectSeries(props, title, author, nil)
            local slug = updated_data.series_slug or (series_info and series_info.slug)
            local index = series_info and series_info.index
            if slug and index then
                local cache_data = self.series_manager:loadSeriesCache(slug)
                if cache_data and cache_data.books then
                    local function filterCurrentOnly(tbl)
                        local res = {}
                        for _, item in ipairs(tbl or {}) do
                            if item.source ~= "series_prior" then
                                table.insert(res, item)
                            end
                        end
                        return res
                    end
                    cache_data.books[index] = {
                        title = title,
                        author = author,
                        characters = filterCurrentOnly(self.characters),
                        locations = filterCurrentOnly(self.locations),
                        terms = filterCurrentOnly(self.terms),
                        timeline = filterCurrentOnly(self.timeline),
                    }
                    self.series_manager:saveSeriesCache(slug, cache_data)

                    local s_setting = self.ai_helper and self.ai_helper.settings and self.ai_helper.settings.series_context_enabled
                    if s_setting ~= false and index > 1 then
                        local all_priors_cached = true
                        for p_idx = 1, index - 1 do
                            if not cache_data.books[p_idx] then
                                all_priors_cached = false
                                break
                            end
                        end
                        if all_priors_cached then
                            self:log("XRayPlugin: Series: Post-fetch auto-restoring cached series context for " .. tostring(slug))
                            self:mergeSeriesContext(cache_data, series_info)
                        end
                    end
                end
            end
        end)
    end

    UIManager:scheduleIn(1, function()
        if self.destroyed or not self.ui or not self.ui.document then return end
        local reading_percent = 100
        if self.ui and self.ui.document and self.ui.document.getPageCount and current_page then
            local page_count = self.ui.document:getPageCount()
            if page_count and page_count > 0 then
                reading_percent = math.floor((current_page / page_count) * 100)
            end
        end
        local spoiler_setting = self.ai_helper and self.ai_helper.settings and self.ai_helper.settings.spoiler_setting or "spoiler_free"
        if spoiler_setting == "full_book" then reading_percent = 100 end
        self:runPostFetchDuplicateCheck(title, author, reading_percent, is_silent)
    end)

    if is_silent then
        self:log(string.format("XRayPlugin: Silent merge complete - Chars: %d, Locs: %d, Events: %d, Cache: %s",
            #self.characters, #self.locations, #self.timeline,
            cache_saved and "saved" or "failed"))
    else
        local fetch_complete = self.loc:t("ai_fetch_complete_msg") or "AI Fetch Complete!"
        local cache_success = self.loc:t("cache_save_success") or "✓ Cache updated."
        local cache_fail = self.loc:t("cache_save_failed") or "✗ Cache failed."
        local label_chars = self.loc:t("entity_label_characters") or "Characters"
        local label_locs = self.loc:t("entity_label_locations") or "Locations"
        local label_timeline = self.loc:t("menu_timeline") or "Timeline"
        local summary = string.format("%s\n\n%s: %d\n%s: %d\n%s: %d\n\n%s", 
            fetch_complete,
            label_chars, #self.characters,
            label_locs, #self.locations,
            label_timeline, #self.timeline,
            cache_saved and cache_success or cache_fail)

        local success_dialog
        local ButtonDialog = require("ui/widget/buttondialog")
        success_dialog = ButtonDialog:new{ title = (self.loc:t("fetch_successful") or "Fetch successful") .. "\n\n" .. summary, buttons = {{{ text = self.loc:t("ok"), callback = function() 
            UIManager:close(success_dialog) 
        end }}} }
        UIManager:show(success_dialog)
    end

end

function M:runPostFetchDuplicateCheck(title, author, reading_percent, is_silent)
    if self.destroyed then return end
    if not self.ui or not self.ui.document or not self.ui.getCurrentPage then
        self:log("XRayPlugin: Skipping duplicate check because the reader document is unavailable")
        return
    end
    if self._unit_scan_in_progress then
        self:log("XRayPlugin: Deferring duplicate check because unit scan is in progress")
        UIManager:scheduleIn(5, function()
            if self.destroyed or not self.ui or not self.ui.document then return end
            self:runPostFetchDuplicateCheck(title, author, reading_percent, is_silent)
        end)
        return
    end
    if not self.ai_helper or not self.ai_helper.hasApiKey or not self.ai_helper:hasApiKey() then return end
    if self.ai_helper.settings and self.ai_helper.settings.auto_dupe_check_enabled == false then return end

    local DataStorage = require("datastorage")
    local settings_xray_dir = DataStorage:getSettingsDir() .. "/xray"

    -- Gather a small book text anchor for the spoiler guard.
    -- This is done once here and shared across both list checks.
    if not self.chapter_analyzer then
        self.chapter_analyzer = require(plugin_path .. "xray_chapteranalyzer"):new()
    end
    local dup_book_text = self.chapter_analyzer:getTextForAnalysis(
        self.ui, 15000, nil, self.ui:getCurrentPage())

    -- Run checks for characters and locations in sequence using async subprocesses
    local function checkListAsync(list, list_name, entity_label, on_done)
        if not list or #list < 2 then on_done(nil); return end
        
        local unique_id = tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
        local result_file = settings_xray_dir .. "/dupe_res_" .. list_name .. "_" .. unique_id .. ".json"
        
        self:log("XRayPlugin: Starting async duplicate check for " .. list_name)
        local pid = self.ai_helper:findDuplicatesAsync(title, author, list, entity_label, reading_percent, result_file, dup_book_text)
        if not pid then
            self:log("XRayPlugin: Failed to start async duplicate check for " .. list_name)
            on_done(nil)
            return
        end
        
        local poll_count = 0
        local max_polls = 150 -- 5 minutes at 2s intervals
        local function poll()
            if self.destroyed or not self.ui or not self.ui.document then
                pcall(function() os.remove(result_file) end)
                return
            end
            poll_count = poll_count + 1
            local data, p_err_code, p_err_msg = self.ai_helper:checkAsyncResult(result_file, pid)
            if data == nil then
                if poll_count < max_polls then
                    UIManager:scheduleIn(2, poll)
                else
                    self:log("XRayPlugin: Async duplicate check for " .. list_name .. " timed out")
                    pcall(function() os.remove(result_file) end)
                    on_done(nil)
                end
            elseif data == false then
                self:log("XRayPlugin: Async duplicate check for " .. list_name .. " failed: " .. tostring(p_err_msg))
                on_done(nil)
            else
                self:log("XRayPlugin: Async duplicate check for " .. list_name .. " succeeded")
                local pairs_found = data.duplicate_pairs or data.DuplicatePairs
                on_done(pairs_found)
            end
        end
        UIManager:scheduleIn(2, poll)
    end

    checkListAsync(self.characters, "characters",
        self.loc:t("entity_label_characters") or "characters",
        function(char_pairs)
            checkListAsync(self.locations, "locations",
                self.loc:t("entity_label_locations") or "locations",
                function(loc_pairs)
                    local rejected_pairs = self.book_data and self.book_data.rejected_merge_pairs or {}
                    
                    local function filterRejected(pairs)
                        if not pairs then return nil end
                        local filtered = {}
                        for _, pair in ipairs(pairs) do
                            if pair.primary and pair.secondary then
                                local p_name = pair.primary:lower()
                                local s_name = pair.secondary:lower()
                                local key = p_name < s_name and (p_name .. "|" .. s_name) or (s_name .. "|" .. p_name)
                                if not rejected_pairs[key] then
                                    table.insert(filtered, pair)
                                end
                            end
                        end
                        return filtered
                    end

                    char_pairs = filterRejected(char_pairs)
                    loc_pairs = filterRejected(loc_pairs)

                    local has_chars = char_pairs and #char_pairs > 0
                    local has_locs  = loc_pairs  and #loc_pairs  > 0

                    if not has_chars and not has_locs then return end

                    if is_silent then
                        self.pending_duplicate_review = {
                            characters = has_chars and char_pairs or nil,
                            locations  = has_locs and loc_pairs or nil,
                        }
                        self:log("XRayPlugin: Stored " .. tostring(has_chars and #char_pairs or 0) .. " char and " .. tostring(has_locs and #loc_pairs or 0) .. " loc duplicate pairs for later review")
                    else
                        UIManager:scheduleIn(0.5, function()
                            if self.destroyed or not self.ui or not self.ui.document then return end
                            if has_chars then
                                self:showAIFindDuplicatesFlow(self.characters, "characters",
                                    self.loc:t("entity_label_characters") or "characters")
                            elseif has_locs then
                                self:showAIFindDuplicatesFlow(self.locations, "locations",
                                    self.loc:t("entity_label_locations") or "locations")
                            end
                        end)
                    end
                end
            )
        end
    )
end

function M:fetchMoreEntities(entity_type)
    require("ui/network/manager"):runWhenOnline(function() 
        if self.destroyed or not self.ui or not self.ui.document then return end
        local doc_file = self.ui.document.file
        if not doc_file then return end

        if not self.ai_helper then
            local AIHelper = require(plugin_path .. "xray_aihelper")
            self.ai_helper = AIHelper
            self.ai_helper:init(self.path)
        end
        if not self.ai_helper:hasApiKey() then
            local ButtonDialog = require("ui/widget/buttondialog")
            local key_dlg
            key_dlg = ButtonDialog:new{
                title = self.loc:t("error_no_api_key") or "API Key Required",
                buttons = {{{ text = self.loc:t("ok") or "OK", callback = function() if key_dlg then UIManager:close(key_dlg) end end }}}
            }
            UIManager:show(key_dlg)
            return
        end

        local props = self.ui.document:getProps() or {}
        local title = sanitizeMetadata(props.title)
        local author = sanitizeMetadata(props.authors)
        local current_page = self.ui:getCurrentPage()
        local reading_percent = math.floor((current_page / self.ui.document:getPageCount()) * 100)
        local spoiler_setting = self.ai_helper.settings and self.ai_helper.settings.spoiler_setting or "spoiler_free"
        
        if spoiler_setting == "full_book" then
            reading_percent = 100
        end
        
        local is_terms = (entity_type == "terms")
        local section_name = is_terms and "more_terms" or "more_characters"
        local dialog_title_text = is_terms
            and (self.loc:t("extracting_more_terms") or "Extracting additional terms...")
            or  (self.loc:t("extracting_more_characters") or "Extracting additional characters...")

        local menu_to_close = is_terms and self.terms_menu or self.char_menu
        if is_terms then self.terms_menu = nil else self.char_menu = nil end

        local wait_msg
        local request_pid
        local result_file
        local is_cancelled = false
        local ButtonDialog = require("ui/widget/buttondialog")

        local function cancelActiveRequest(reason)
            if is_cancelled then return end
            is_cancelled = true
            if request_pid and self.ai_helper and self.ai_helper.cancelAsyncChild then
                self.ai_helper:cancelAsyncChild(request_pid)
            end
            if result_file then
                pcall(function() os.remove(result_file) end)
            end
            if wait_msg then
                local dlg = wait_msg
                wait_msg = nil
                dlg.tap_close_callback = nil
                UIManager:close(dlg)
            end
            if self._active_ai_dialog == wait_msg then self._active_ai_dialog = nil end
            if self._active_ai_cancel == cancelActiveRequest then self._active_ai_cancel = nil end
            self:log("XRayPlugin: " .. (reason or "Fetch more cancelled"))
        end

        wait_msg = ButtonDialog:new{
            title = dialog_title_text .. "\n\n" .. title,
            tap_close_callback = function()
                cancelActiveRequest("Fetch cancelled by user")
            end,
            buttons = {{{
                text = self.loc:t("cancel") or "Cancel",
                is_enter_default = true,
                callback = function()
                    cancelActiveRequest("Fetch cancelled by user")
                end
            }}}
        }
        self._active_ai_dialog = wait_msg
        self._active_ai_cancel = cancelActiveRequest
        UIManager:show(wait_msg)
        
        UIManager:scheduleIn(0.5, function()
            if is_cancelled or self.destroyed or not self.ui or not self.ui.document then
                cancelActiveRequest("Fetch stopped because plugin was destroyed or document closed")
                return
            end
            if not self.chapter_analyzer then self.chapter_analyzer = require(plugin_path .. "xray_chapteranalyzer"):new() end
            
            -- EVEN SAMPLING: Divide the readable range into equal segments
            local current_page = self.ui:getCurrentPage()
            local pages_per_sample = 20
            local chars_per_sample = 10000
            local num_samples = 6
            
            -- Track call count to shift windows on each invocation
            self.more_fetch_call_count = self.more_fetch_call_count or {}
            self.more_fetch_call_count[entity_type] = (self.more_fetch_call_count[entity_type] or 0) + 1
            local call_num = self.more_fetch_call_count[entity_type]
            local offset = (call_num - 1) * pages_per_sample
            self:log("XRayPlugin: More " .. entity_type .. " call #" .. call_num .. " (offset: " .. offset .. " pages)")
            
            -- Divide readable range into equal segments
            local readable_pages = math.max(1, current_page)
            local segment_size = math.floor(readable_pages / num_samples)
            if segment_size < pages_per_sample then segment_size = pages_per_sample end
            
            local text_parts = {}
            for i = 0, num_samples - 1 do
                local segment_start = i * segment_size
                local sample_start = math.min(segment_start + offset, readable_pages - pages_per_sample)
                sample_start = math.max(1, sample_start)
                
                -- Wrap around within the segment if the offset pushes past the segment boundary
                local segment_end = (i + 1) * segment_size
                if sample_start >= segment_end and i < num_samples - 1 then
                    sample_start = segment_start + ((offset) % segment_size)
                    sample_start = math.max(1, math.min(sample_start, readable_pages - pages_per_sample))
                end
                
                if sample_start <= current_page then
                    local end_page = math.min(sample_start + pages_per_sample, current_page)
                    local sample = self.chapter_analyzer:getTextFromPageRange(self.ui, sample_start, end_page, chars_per_sample)
                    if sample and #sample > 100 then
                        table.insert(text_parts, "[SECTION " .. (i + 1) .. "]\n" .. sample)
                        self:log("XRayPlugin: More " .. entity_type .. " sample " .. (i + 1) .. " pages " .. sample_start .. "-" .. end_page .. ": " .. #sample .. " chars")
                    end
                end
            end
            local book_text = table.concat(text_parts, "\n\n---\n\n")
            
            local exclude_list = {}
            local source_list = is_terms and (self.terms or {}) or (self.characters or {})
            for _, item in ipairs(source_list) do
                if item.name then
                    table.insert(exclude_list, item.name)
                end
            end
            
            local context = { 
                reading_percent = reading_percent, 
                spoiler_free = reading_percent < 100,
                filename = doc_file:match("([^/\\]+)$"), 
                series = props.series or props.Series, 
                book_text = book_text,
                exclude_characters = not is_terms and table.concat(exclude_list, ", ") or nil,
                exclude_terms = is_terms and table.concat(exclude_list, ", ") or nil,
            }
            
            local pid, res_file = self.ai_helper:startAIRequest(title, author, context, section_name)
            if not pid then
                if wait_msg then
                    local dlg = wait_msg
                    wait_msg = nil
                    dlg.tap_close_callback = nil
                    UIManager:close(dlg)
                end
                if self._active_ai_dialog == wait_msg then self._active_ai_dialog = nil end
                if self._active_ai_cancel == cancelActiveRequest then self._active_ai_cancel = nil end
                local err_dlg
                err_dlg = ButtonDialog:new{
                    title = self.loc:t("error") or "Error",
                    text = res_file or (self.loc:t("error_api") or "API Error"),
                    buttons = {{{ text = self.loc:t("ok") or "OK", callback = function() if err_dlg then UIManager:close(err_dlg) end end }}}
                }
                UIManager:show(err_dlg)
                return
            end
            request_pid = pid
            result_file = res_file

            local request_started_at = os.time()
            local request_timeout = 600
            local function poll()
                if is_cancelled then return end
                if self.destroyed or not self.ui or not self.ui.document then
                    cancelActiveRequest("Fetch stopped because plugin was destroyed or document closed")
                    return
                end
                if os.time() - request_started_at > request_timeout then
                    cancelActiveRequest("Fetch timed out")
                    local to_dlg
                    to_dlg = ButtonDialog:new{
                        title = self.loc:t("error") or "Error",
                        text = self.loc:t("error_timeout") or "Request timed out",
                        buttons = {{{ text = self.loc:t("ok") or "OK", callback = function() if to_dlg then UIManager:close(to_dlg) end end }}}
                    }
                    UIManager:show(to_dlg)
                    return
                end
                local res, err_code, err_msg = self.ai_helper:checkAsyncResult(result_file, request_pid)
                if is_cancelled then return end
                if res == nil then
                    UIManager:scheduleIn(1, poll)
                else
                    if is_cancelled then return end
                    if self._active_ai_dialog == wait_msg then self._active_ai_dialog = nil end
                    if self._active_ai_cancel == cancelActiveRequest then self._active_ai_cancel = nil end
                    if wait_msg then
                        local dlg = wait_msg
                        wait_msg = nil
                        dlg.tap_close_callback = nil
                        UIManager:close(dlg)
                    end
                    pcall(function() os.remove(result_file) end)

                    if is_cancelled then return end

                    if not res or type(res) ~= "table" then
                        if is_cancelled then return end
                        local utils = require(plugin_path .. "xray_utils")
                        local err_title, text = utils:getFriendlyError(err_code, err_msg, self.loc)
                        local display_msg = err_title or "Error"
                        if text and text ~= "" then
                            display_msg = display_msg .. "\n\n" .. text
                        end
                        local err_box
                        err_box = ButtonDialog:new{
                            title = display_msg,
                            buttons = {{{ text = self.loc:t("ok") or "OK", callback = function() if err_box then UIManager:close(err_box) end end }}}
                        }
                        UIManager:show(err_box)
                        return
                    end

                    local items = is_terms and (res.terms or (not res.terms and res[1] and res)) or (res.characters or (not res.characters and res[1] and res))
                    if not items then
                        if is_cancelled then return end
                        local utils = require(plugin_path .. "xray_utils")
                        local err_title, text = utils:getFriendlyError(err_code, err_msg, self.loc)
                        local display_msg = err_title or "Error"
                        if text and text ~= "" then
                            display_msg = display_msg .. "\n\n" .. text
                        end
                        local err_box
                        err_box = ButtonDialog:new{
                            title = display_msg,
                            buttons = {{{ text = self.loc:t("ok") or "OK", callback = function() if err_box then UIManager:close(err_box) end end }}}
                        }
                        UIManager:show(err_box)
                        return
                    end

                    local new_count = 0
                    local target_list = is_terms and (self.terms or {}) or (self.characters or {})
                    for _, new_item in ipairs(items) do
                        if new_item.name then
                            local found = false
                            for _, existing_item in ipairs(target_list) do
                                if (existing_item.name or ""):lower() == (new_item.name or ""):lower() then
                                    found = true
                                    break
                                end
                            end
                            if not found then
                                table.insert(target_list, new_item)
                                new_count = new_count + 1
                            end
                        end
                    end
                    if is_terms then self.terms = target_list else self.characters = target_list end

                    if is_terms then
                        self.terms = self:deduplicateByName(self.terms, "name")
                    end

                    -- Re-sort by frequency based on the newly extracted samples
                    if book_text and #book_text > 0 then
                        if is_terms then
                            self:sortDataByFrequency(self.terms, book_text, "name")
                        else
                            self:sortDataByFrequency(self.characters, book_text, "name")
                        end
                    end

                    -- Save to cache
                    if not self.cache_manager then self.cache_manager = require(plugin_path .. "xray_cachemanager"):new() end
                    if not self.book_data then
                        self.book_data = self.cache_manager:loadCache(doc_file) or {}
                    end
                    local updated_data = self.book_data
                    updated_data.book_title = title
                    updated_data.author = author
                    updated_data.characters = self.characters
                    updated_data.historical_figures = self.historical_figures
                    updated_data.locations = self.locations
                    updated_data.terms = self.terms or updated_data.terms
                    updated_data.book_type = self.book_type or updated_data.book_type
                    updated_data.timeline = self.timeline or updated_data.timeline
                    updated_data.author_info = self.author_info or updated_data.author_info

                    self.cache_manager:asyncSaveCache(doc_file, updated_data)

                    if not is_terms then
                        local cur_p = self.ui and self.ui.getCurrentPage and self.ui:getCurrentPage() or 1
                        local tot_p = self.ui and self.ui.document and self.ui.document.getPageCount and self.ui.document:getPageCount() or 1
                        local r_pct = tot_p and tot_p > 0 and math.floor((cur_p / tot_p) * 100) or 100
                        local sp_set = self.ai_helper and self.ai_helper.settings and self.ai_helper.settings.spoiler_setting or "spoiler_free"
                        if sp_set == "full_book" then r_pct = 100 end

                        UIManager:scheduleIn(0.5, function()
                            if self.destroyed or not self.ui or not self.ui.document then return end
                            self:runPostFetchDuplicateCheck(title, author, r_pct, false)
                        end)
                    end

                    local added_msg = is_terms
                        and self.loc:t("msg_added_terms", new_count)
                        or  self.loc:t("msg_added_characters", new_count)
                    UIManager:show(InfoMessage:new{ text = added_msg, timeout = 3 })

                    if menu_to_close then
                        UIManager:close(menu_to_close)
                    end
                    if is_terms then
                        self:showTerms()
                    else
                        self:showCharacters()
                    end
                end
            end
            UIManager:scheduleIn(1, poll)
        end)
    end)
end

function M:fetchMoreCharacters()
    return self:fetchMoreEntities("characters")
end

function M:fetchMoreTerms()
    return self:fetchMoreEntities("terms")
end

function M:fetchAuthorInfo()
    if self.destroyed or not self.ui or not self.ui.document then return end
    local doc_file = self.ui.document.file
    if not doc_file then return end

    if not self.ai_helper then
        local AIHelper = require(plugin_path .. "xray_aihelper")
        self.ai_helper = AIHelper
        self.ai_helper:init(self.path)
    end
    if not self.ai_helper:hasApiKey() then
        local ButtonDialog = require("ui/widget/buttondialog")
        local key_dlg
        key_dlg = ButtonDialog:new{
            title = self.loc:t("error_no_api_key") or "API Key Required",
            buttons = {{{ text = self.loc:t("ok") or "OK", callback = function() if key_dlg then UIManager:close(key_dlg) end end }}}
        }
        UIManager:show(key_dlg)
        return
    end

    local props = self.ui.document:getProps() or {}
    local title = sanitizeMetadata(props.title)
    local author = sanitizeMetadata(props.authors)
    local wait_msg
    local request_pid
    local result_file
    local is_cancelled = false
    local ButtonDialog = require("ui/widget/buttondialog")

    local function cancelActiveRequest(reason)
        if is_cancelled then return end
        is_cancelled = true
        if request_pid and self.ai_helper and self.ai_helper.cancelAsyncChild then
            self.ai_helper:cancelAsyncChild(request_pid)
        end
        if result_file then
            pcall(function() os.remove(result_file) end)
        end
        if wait_msg then
            local dlg = wait_msg
            wait_msg = nil
            dlg.tap_close_callback = nil
            UIManager:close(dlg)
        end
        if self._active_ai_dialog == wait_msg then self._active_ai_dialog = nil end
        if self._active_ai_cancel == cancelActiveRequest then self._active_ai_cancel = nil end
        self:log("XRayPlugin: " .. (reason or "Author fetch cancelled"))
    end

    wait_msg = ButtonDialog:new{
        title = (self.loc:t("fetching_author", "AI") or ("Fetching author info from %s..."):format("AI")) .. "\n\n" .. title .. " - " .. author,
        tap_close_callback = function()
            cancelActiveRequest("Author fetch cancelled by user")
        end,
        buttons = {{{
            text = self.loc:t("cancel") or "Cancel",
            is_enter_default = true,
            callback = function()
                cancelActiveRequest("Author fetch cancelled by user")
            end
        }}}
    }
    self._active_ai_dialog = wait_msg
    self._active_ai_cancel = cancelActiveRequest
    UIManager:show(wait_msg)

    UIManager:scheduleIn(0.5, function()
        if is_cancelled or self.destroyed or not self.ui or not self.ui.document then
            cancelActiveRequest("Author fetch stopped because plugin was destroyed or document closed")
            return
        end
        
        if not self.chapter_analyzer then
            local ChapterAnalyzer = require(plugin_path .. "xray_chapteranalyzer")
            self.chapter_analyzer = ChapterAnalyzer:new()
        end
        local book_text = self.chapter_analyzer:getTextForAnalysis(self.ui, 1000, nil, self.ui:getCurrentPage())
        local context = { book_text = book_text }
        
        local pid, res_file = self.ai_helper:startAIRequest(title, author, context, "author_only")
        if not pid then
            if wait_msg then
                local dlg = wait_msg
                wait_msg = nil
                dlg.tap_close_callback = nil
                UIManager:close(dlg)
            end
            if self._active_ai_dialog == wait_msg then self._active_ai_dialog = nil end
            if self._active_ai_cancel == cancelActiveRequest then self._active_ai_cancel = nil end
            local err_dlg
            err_dlg = ButtonDialog:new{
                title = self.loc:t("error") or "Error",
                text = res_file or (self.loc:t("error_api") or "API Error"),
                buttons = {{{ text = self.loc:t("ok") or "OK", callback = function() if err_dlg then UIManager:close(err_dlg) end end }}}
            }
            UIManager:show(err_dlg)
            return
        end
        request_pid = pid
        result_file = res_file

        local request_started_at = os.time()
        local request_timeout = 600
        local function poll()
            if is_cancelled then return end
            if self.destroyed or not self.ui or not self.ui.document then
                cancelActiveRequest("Author fetch stopped because plugin was destroyed or document closed")
                return
            end
            if os.time() - request_started_at > request_timeout then
                cancelActiveRequest("Author fetch timed out")
                local to_dlg
                to_dlg = ButtonDialog:new{
                    title = self.loc:t("error") or "Error",
                    text = self.loc:t("error_timeout") or "Request timed out",
                    buttons = {{{ text = self.loc:t("ok") or "OK", callback = function() if to_dlg then UIManager:close(to_dlg) end end }}}
                }
                UIManager:show(to_dlg)
                return
            end
            local res, err_code, err_msg = self.ai_helper:checkAsyncResult(result_file, request_pid)
            if is_cancelled then return end
            if res == nil then
                UIManager:scheduleIn(1, poll)
            else
                if is_cancelled then return end
                if self._active_ai_dialog == wait_msg then self._active_ai_dialog = nil end
                if self._active_ai_cancel == cancelActiveRequest then self._active_ai_cancel = nil end
                if wait_msg then
                    local dlg = wait_msg
                    wait_msg = nil
                    dlg.tap_close_callback = nil
                    UIManager:close(dlg)
                end
                pcall(function() os.remove(result_file) end)

                if is_cancelled then return end

                local author_data = (type(res) == "table" and (res.author_info or res)) or nil
                if not author_data or not (author_data.author or author_data.name or author_data.author_bio or author_data.description) then
                    if is_cancelled then return end
                    local utils = require(plugin_path .. "xray_utils")
                    local err_title, text = utils:getFriendlyError(err_code, err_msg, self.loc)
                    local display_msg = err_title or "Error"
                    if text and text ~= "" then
                        display_msg = display_msg .. "\n\n" .. text
                    end
                    local err_box
                    err_box = ButtonDialog:new{
                        title = display_msg,
                        buttons = {{{ text = self.loc:t("ok") or "OK", callback = function() if err_box then UIManager:close(err_box) end end }}}
                    }
                    UIManager:show(err_box)
                    return
                end

                self.author_info = { 
                    name = sanitizeMetadata(author_data.author or author_data.name or author), 
                    description = sanitizeMetadata(author_data.author_bio or author_data.description or self.loc:t("msg_no_bio") or "No biography available."), 
                    birthDate = sanitizeMetadata(author_data.author_birth or author_data.birthDate or "---"), 
                    deathDate = sanitizeMetadata(author_data.author_death or author_data.deathDate or "---") 
                }
                if not self.cache_manager then self.cache_manager = require(plugin_path .. "xray_cachemanager"):new() end
                if not self.book_data then
                    self.book_data = self.cache_manager:loadCache(doc_file) or {}
                end
                local cache = self.book_data
                cache.author_info = self.author_info
                cache.author = self.author_info.name
                cache.author_bio = self.author_info.description
                cache.author_birth = self.author_info.birthDate
                cache.author_death = self.author_info.deathDate
                
                -- Store book_type if AI detected it during author fetch
                if author_data.book_type then
                    cache.book_type = author_data.book_type
                    self.book_type = author_data.book_type
                end
                
                self.cache_manager:asyncSaveCache(doc_file, cache)
                self:showAuthorInfo()
            end
        end
        UIManager:scheduleIn(1, poll)
    end)
end

function M:checkWeeklyUpdate()
    if not self.ai_helper or not self.ai_helper.settings then return end
    
    local last_check = self.ai_helper.settings.last_update_check or 0
    local now = os.time()
    local week_seconds = 7 * 24 * 60 * 60
    
    if (now - last_check) > week_seconds then
        local NetworkMgr = require("ui/network/manager")
        if NetworkMgr:isConnected() and NetworkMgr:isOnline() then
            self:log("XRayPlugin: Triggering weekly silent update check")
            self.ai_helper:saveSettings({ last_update_check = now })
            local updater = require(plugin_path .. "xray_updater")
            updater.checkSilentForUpdates(self.loc, self.ai_helper.settings.beta_channel_enabled)
        else
            self:log("XRayPlugin: Skipping weekly update check (offline)")
        end
    end
end

function M:mergeSeriesContext(cache_data, series_info)
    if not cache_data or not series_info then return end

    self.characters = self.characters or {}
    self.locations = self.locations or {}
    self.terms = self.terms or {}
    self.timeline = self.timeline or {}

    local function filterPrior(tbl)
        local filtered = {}
        for _, item in ipairs(tbl or {}) do
            if item and item.source ~= "series_prior" then
                table.insert(filtered, item)
            end
        end
        return filtered
    end

    self.characters = filterPrior(self.characters)
    self.locations = filterPrior(self.locations)
    self.terms = filterPrior(self.terms)
    self.timeline = filterPrior(self.timeline)

    for idx = 1, (series_info.index or 1) - 1 do
        local book_data = cache_data.books and cache_data.books[idx]
        if book_data then
            for _, new_char in ipairs(book_data.characters or {}) do
                if new_char and new_char.name and new_char.name ~= "" then
                    local found = false
                    local lower_name = new_char.name:lower()
                    for _, existing_char in ipairs(self.characters) do
                        if existing_char and existing_char.name then
                            local matches = false
                            if existing_char.name:lower() == lower_name then
                                matches = true
                            else
                                for _, alias in ipairs(existing_char.aliases or {}) do
                                    if type(alias) == "string" and alias:lower() == lower_name then
                                        matches = true
                                        break
                                    end
                                end
                            end
                            
                            if matches then
                                found = true
                                local prefix = string.format("[From Book %d] ", idx)
                                if new_char.description and new_char.description ~= "" then
                                    local exist_desc = existing_char.description or ""
                                    if not exist_desc:find(prefix, 1, true) then
                                        existing_char.description = prefix .. new_char.description .. "\n\n" .. exist_desc
                                    end
                                end
                                break
                            end
                        end
                    end
                    
                    if not found then
                        local char_copy = {}
                        for k, v in pairs(new_char) do char_copy[k] = v end
                        char_copy.source = "series_prior"
                        char_copy.source_book = idx
                        table.insert(self.characters, char_copy)
                    end
                end
            end

            for _, new_loc in ipairs(book_data.locations or {}) do
                if new_loc and new_loc.name and new_loc.name ~= "" then
                    local found = false
                    local lower_name = new_loc.name:lower()
                    for _, existing_loc in ipairs(self.locations) do
                        if existing_loc and existing_loc.name then
                            if existing_loc.name:lower() == lower_name then
                                found = true
                                local prefix = string.format("[From Book %d] ", idx)
                                if new_loc.description and new_loc.description ~= "" then
                                    local exist_desc = existing_loc.description or ""
                                    if not exist_desc:find(prefix, 1, true) then
                                        existing_loc.description = prefix .. new_loc.description .. "\n\n" .. exist_desc
                                    end
                                end
                                break
                            end
                        end
                    end
                    if not found then
                        local loc_copy = {}
                        for k, v in pairs(new_loc) do loc_copy[k] = v end
                        loc_copy.source = "series_prior"
                        loc_copy.source_book = idx
                        table.insert(self.locations, loc_copy)
                    end
                end
            end

            for _, new_term in ipairs(book_data.terms or {}) do
                if new_term and new_term.name and new_term.name ~= "" then
                    local found = false
                    local lower_name = new_term.name:lower()
                    for _, existing_term in ipairs(self.terms) do
                        if existing_term and existing_term.name then
                            if existing_term.name:lower() == lower_name then
                                found = true
                                local prefix = string.format("[From Book %d] ", idx)
                                if new_term.definition and new_term.definition ~= "" then
                                    local exist_def = existing_term.definition or ""
                                    if not exist_def:find(prefix, 1, true) then
                                        existing_term.definition = prefix .. new_term.definition .. "\n\n" .. exist_def
                                    end
                                end
                                break
                            end
                        end
                    end
                    if not found then
                        local term_copy = {}
                        for k, v in pairs(new_term) do term_copy[k] = v end
                        term_copy.source = "series_prior"
                        term_copy.source_book = idx
                        table.insert(self.terms, term_copy)
                    end
                end
            end

            local events = {}
            for _, new_event in ipairs(book_data.timeline or {}) do
                if new_event and new_event.event and new_event.event ~= "" then
                    table.insert(events, new_event.event)
                end
            end
            if #events > 0 then
                local book_title = book_data.title or (cache_data.books and cache_data.books[idx] and cache_data.books[idx].title) or ""
                local label
                if book_title and book_title ~= "" then
                    label = string.format("[Book %d: %s]", idx, book_title)
                else
                    label = string.format("[Book %d]", idx)
                end
                local consolidated_event = table.concat(events, "\n\n")
                local ev_copy = {
                    chapter = label,
                    event = consolidated_event,
                    page = -1000 + idx,
                    source = "series_prior",
                    source_book = idx
                }
                table.insert(self.timeline, ev_copy)
            end
        end
    end

    local toc = self.ui and self.ui.document and self.ui.document.getToc and utils:flattenTOC(self.ui.document:getToc()) or {}
    self:assignTimelinePages(self.timeline, toc, true)
    self:sortTimelineByTOC(self.timeline)

    self.series_context_loaded = true
    if not self.cache_manager then
        self.cache_manager = require(plugin_path .. "xray_cachemanager"):new()
    end
    local book_path = self.ui and self.ui.document and self.ui.document.file
    if book_path then
        if not self.book_data then
            self.book_data = self.cache_manager:loadCache(book_path) or {}
        end
        local cache = self.book_data
        cache.series_context_loaded = true
        cache.series_slug = series_info.slug
        cache.characters = self.characters
        cache.locations = self.locations
        cache.terms = self.terms
        cache.timeline = self.timeline
        self.cache_manager:asyncSaveCache(book_path, cache)
        self.book_data = cache
    end
end

function M:fetchSeriesContext(is_silent, init_wait_dialog, cancel_ref)
    local function closeInitWait()
        if init_wait_dialog then
            UIManager:close(init_wait_dialog)
            init_wait_dialog = nil
        end
    end

    if cancel_ref and cancel_ref.cancelled then
        self:log("XRayPlugin: Series: fetchSeriesContext early exit: cancel_ref is cancelled")
        closeInitWait()
        return
    end

    if not self.ui or not self.ui.document then
        self:log("XRayPlugin: Series: fetchSeriesContext called with no document/ui, aborting")
        closeInitWait()
        return
    end

    if not self.ai_helper or not self.ai_helper.settings or not self.ai_helper.settings.series_context_enabled then
        self:log("XRayPlugin: Series: fetchSeriesContext early exit: setting series_context_enabled is false or nil")
        closeInitWait()
        return
    end

    local props = self.ui.document:getProps() or {}
    local title = sanitizeMetadata(props.title)
    local author = sanitizeMetadata(props.authors)

    self:log("XRayPlugin: Series: fetchSeriesContext starting for: title=" .. tostring(title) .. ", author=" .. tostring(author))

    if init_wait_dialog and self.ai_helper then self.ai_helper:setTrapWidget(init_wait_dialog) end
    local series_info = self.series_manager:detectSeries(props, title, author, self.ai_helper)
    if init_wait_dialog and self.ai_helper then self.ai_helper:resetTrapWidget() end
    if cancel_ref and cancel_ref.cancelled then
        self:log("XRayPlugin: Series: fetchSeriesContext cancelled after detectSeries")
        closeInitWait()
        return
    end

    if not series_info or not series_info.name or not series_info.index or series_info.index <= 1 then
        self:log("XRayPlugin: Series: No series detected or current book is the first one in the series. series_info=" .. (series_info and ("name=" .. tostring(series_info.name) .. ", index=" .. tostring(series_info.index)) or "nil"))
        closeInitWait()
        if not is_silent then
            UIManager:show(InfoMessage:new{
                text = self.loc:t("series_no_prior_detected") or "No prior books detected for this series.",
                timeout = 5
            })
        end
        return
    end

    local slug = series_info.slug
    self:log("XRayPlugin: Series: Detected series=" .. series_info.name .. ", index=" .. tostring(series_info.index) .. ", slug=" .. tostring(slug))

    local cache_data = self.series_manager:loadSeriesCache(slug) or { books = {} }
    cache_data.books = cache_data.books or {}

    if init_wait_dialog and self.ai_helper then self.ai_helper:setTrapWidget(init_wait_dialog) end
    local prior_books = self.series_manager:getPriorBookList(series_info, author, self.ai_helper)
    if init_wait_dialog and self.ai_helper then self.ai_helper:resetTrapWidget() end
    if cancel_ref and cancel_ref.cancelled then
        self:log("XRayPlugin: Series: fetchSeriesContext cancelled after getPriorBookList")
        closeInitWait()
        return
    end

    if #prior_books == 0 then
        self:log("XRayPlugin: Series: getPriorBookList returned empty list, using generated placeholders")
        for i = 1, series_info.index - 1 do
            table.insert(prior_books, {
                index = i,
                title = string.format("%s (Book %d)", series_info.name, i),
                author = author or "Unknown Author"
            })
        end
    else
        self:log("XRayPlugin: Series: getPriorBookList returned " .. tostring(#prior_books) .. " prior books")
    end

    local missing_books = {}
    for _, book in ipairs(prior_books) do
        local idx = book.index
        if not cache_data.books[idx] then
            self:log("XRayPlugin: Series: Cache MISS for book index " .. tostring(idx) .. ": " .. tostring(book.title))
            table.insert(missing_books, book)
        else
            self:log("XRayPlugin: Series: Cache HIT for book index " .. tostring(idx) .. ": " .. tostring(book.title))
        end
    end

    if #missing_books == 0 then
        self:log("XRayPlugin: Series: All prior books are already cached. Merging context immediately.")
        closeInitWait()
        self:mergeSeriesContext(cache_data, series_info)
        if not is_silent then
            local count = series_info.index - 1
            local loaded_msg = self.loc:t("series_context_loaded", count)
            UIManager:show(InfoMessage:new{
                text = loaded_msg,
                timeout = 5
            })
        end
        return
    end

    self:log("XRayPlugin: Series: Needs to fetch " .. tostring(#missing_books) .. " missing books from AI. Running when online.")

    require("ui/network/manager"):runWhenOnline(function()
        closeInitWait()
        if cancel_ref and cancel_ref.cancelled then
            self:log("XRayPlugin: Series: runWhenOnline fired after user cancelled")
            return
        end
        local is_cancelled = cancel_ref and cancel_ref.cancelled or false
        local wait_msg

        local function showProgress(current_idx, total_count, book_title)
            if is_silent then return end
            closeInitWait()
            if wait_msg then UIManager:close(wait_msg) end

            local progress_text = self.loc:t("fetching_series_context", current_idx, total_count)
            wait_msg = ButtonDialog:new{
                title = progress_text .. "\n\n" .. book_title .. "\n\n" .. (self.loc:t("fetching_wait") or "This may take a moment.\nTap Cancel to stop."),
                buttons = {{{
                    text = self.loc:t("cancel") or "Cancel",
                    callback = function()
                        is_cancelled = true
                        self:log("XRayPlugin: Series: User tapped Cancel on progress dialog.")
                        if wait_msg then
                            if wait_msg.dismiss_callback then
                                wait_msg.dismiss_callback()
                            end
                            UIManager:close(wait_msg)
                        end
                    end
                }}}
            }
            UIManager:show(wait_msg)
        end

        local function fetchNext(step_idx)
            if is_cancelled then
                self:log("XRayPlugin: Series: fetch series context cancelled by user.")
                return
            end

            if step_idx > #missing_books then
                self:log("XRayPlugin: Series: All missing books fetched. Saving series cache and merging context.")
                if wait_msg then UIManager:close(wait_msg) end
                self.series_manager:saveSeriesCache(slug, cache_data)
                self:mergeSeriesContext(cache_data, series_info)

                if not is_silent then
                    local count = series_info.index - 1
                    local loaded_msg = self.loc:t("series_context_loaded", count)
                    UIManager:show(InfoMessage:new{
                        text = loaded_msg,
                        timeout = 5
                    })
                end
                return
            end

            local current_book = missing_books[step_idx]
            self:log("XRayPlugin: Series: Fetching AI context for book " .. tostring(current_book.index) .. " (" .. tostring(step_idx) .. "/" .. tostring(#missing_books) .. "): " .. tostring(current_book.title))
            showProgress(step_idx, #missing_books, current_book.title)

            UIManager:scheduleIn(0.5, function()
                coroutine.wrap(function()
                    if is_cancelled or self.destroyed or not self.ui or not self.ui.document then return end

                    local context = {
                        series_name = series_info.name,
                        index = current_book.index
                    }
                    local prompt = self.ai_helper:createPrompt(current_book.title, current_book.author or author, context, "series_book_summary")
                    
                    self.ai_helper:setTrapWidget(wait_msg)
                    local result, err_code, err_msg = self.ai_helper:executeUnifiedRequest(prompt)
                    self.ai_helper:resetTrapWidget()

                    if is_cancelled then return end

                    if not result then
                        self:log("XRayPlugin: Series: Failed fetching book summary for " .. tostring(current_book.title) .. ", err_code=" .. tostring(err_code) .. ", err_msg=" .. tostring(err_msg))
                        if wait_msg then UIManager:close(wait_msg) end
                        if not is_silent then
                            local ButtonDialog = require("ui/widget/buttondialog")
                            local err_title, err_text = utils:getFriendlyError(err_code, err_msg, self.loc)
                            local err_box
                            err_box = ButtonDialog:new{
                                title = err_title,
                                text = err_text,
                                buttons = {{{ text = self.loc:t("ok") or "OK", callback = function() if err_box then UIManager:close(err_box) end end }}}
                            }
                            UIManager:show(err_box)
                        end
                        return
                    end

                    self:log("XRayPlugin: Series: Fetched context for " .. tostring(current_book.title) .. ". Characters=" .. tostring(#(result.characters or {})) .. ", locations=" .. tostring(#(result.locations or {})) .. ", terms=" .. tostring(#(result.terms or {})) .. ", timeline=" .. tostring(#(result.timeline or {})))

                    cache_data.books[current_book.index] = {
                        title = current_book.title,
                        author = current_book.author,
                        characters = result.characters or {},
                        locations = result.locations or {},
                        terms = result.terms or {},
                        timeline = result.timeline or {}
                    }

                    fetchNext(step_idx + 1)
                end)()
            end)
        end

        fetchNext(1)
    end)
end

return M
