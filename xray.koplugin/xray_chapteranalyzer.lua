-- ChapterAnalyzer - Analyze which characters appear in current chapter/page
local logger = require("logger")
local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local AIHelper = require(plugin_path .. "xray_aihelper")

-- Helper function to flatten KOReader's nested TOC tree
local function flattenTOC(nodes, flat_list)
    flat_list = flat_list or {}
    if not nodes then return flat_list end
    
    for _, node in ipairs(nodes) do
        table.insert(flat_list, node)
        if type(node) == "table" then
            if #node > 0 then
                flattenTOC(node, flat_list)
            elseif node.sub_item_table then
                flattenTOC(node.sub_item_table, flat_list)
            elseif node.children then
                flattenTOC(node.children, flat_list)
            end
        end
    end
    return flat_list
end

local ChapterAnalyzer = {}

-- Keep byte budgets, but never return a partial UTF-8 code point.
local function utf8_sub(s, first, last)
    if not s or s == "" then return s or "" end
    local len = #s
    first = first or 1
    last = last or len
    if first < 0 then first = len + first + 1 end
    if last < 0 then last = len + last + 1 end
    first = math.max(1, first)
    last = math.min(len, last)
    if first > last then return "" end

    -- Scan complete code points from the beginning. This handles a requested
    -- start inside a character and an end inside a character without relying
    -- on any particular byte alignment.
    local out, i = {}, 1
    while i <= len do
        local lead = s:byte(i)
        local width = (lead < 0x80 and 1) or (lead < 0xE0 and 2)
            or (lead < 0xF0 and 3) or (lead < 0xF5 and 4) or 1
        local finish = i + width - 1
        if i >= first and finish <= last then
            out[#out + 1] = s:sub(i, finish)
        end
        i = finish + 1
    end
    return table.concat(out)
end

ChapterAnalyzer.utf8_sub = utf8_sub

function ChapterAnalyzer:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Page ranges use different end semantics across KOReader document types.
-- Reflowable extraction stops at the end XPointer, so the next page marks the
-- end of the current page. Page-based extraction is inclusive and must stop on
-- the current page to avoid reading one page ahead.
function ChapterAnalyzer:getEndPageForCurrentPage(ui, current_page)
    if not current_page then return nil end
    if ui and ui.rolling ~= nil then
        return current_page + 1
    end
    return current_page
end

-- Get current chapter/section text
function ChapterAnalyzer:getCurrentChapterText(ui)
    if not ui or not ui.document then
        logger.warn("ChapterAnalyzer: No document available")
        AIHelper:log("ChapterAnalyzer: No document available")
        return nil
    end
    
    -- Check if it's a reflowable document (EPUB, etc.) or page-based (PDF, etc.)
    local is_reflowable = ui.rolling ~= nil
    local is_paged = ui.paging ~= nil
    
    logger.info("ChapterAnalyzer: Reflowable:", is_reflowable, "Paged:", is_paged)
    AIHelper:log("ChapterAnalyzer: Reflowable: " .. tostring(is_reflowable) .. " Paged: " .. tostring(is_paged))
    
    if is_reflowable then
        return self:getReflowableText(ui)
    elseif is_paged then
        return self:getPageBasedText(ui)
    else
        logger.warn("ChapterAnalyzer: Unknown document type")
        AIHelper:log("ChapterAnalyzer: Unknown document type")
        return self:getFallbackText(ui)
    end
end

-- Get text from reflowable documents (EPUB, HTML, FB2)
function ChapterAnalyzer:getReflowableText(ui)
    -- Get current position - different methods for different versions
    local current_pos = nil
    
    -- Try different methods to get current position
    if ui.rolling.current_page then
        current_pos = ui.rolling.current_page
    elseif ui.rolling.getCurrentPos then
        current_pos = ui.rolling:getCurrentPos()
    elseif ui.document.getCurrentPos then
        current_pos = ui.document:getCurrentPos()
    elseif ui.view and ui.view.state and ui.view.state.page then
        current_pos = ui.view.state.page
    else
        -- Last resort: use page 1
        current_pos = 1
    end
    
    logger.info("ChapterAnalyzer: Current position:", current_pos)
    
    -- Try to get chapter from TOC
    local raw_toc = ui.document:getToc()
    local toc = flattenTOC(raw_toc)
    local default_chapter_title = ui.loc and ui.loc:t("this_chapter") or "This Chapter"
    if not toc or #toc == 0 then
        logger.info("ChapterAnalyzer: No TOC, using visible text")
        return self:getVisibleTextReflowable(ui), default_chapter_title
    end
    
    -- Find current chapter: select the chapter with page <= current_pos closest to current_pos
    local current_chapter = nil
    local max_chapter_page = -1
    local chapter_title = default_chapter_title
    
    for _, chapter in ipairs(toc) do
        if chapter.page then
            local p = tonumber(chapter.page)
            if p and p <= current_pos and p >= max_chapter_page then
                max_chapter_page = p
                current_chapter = chapter
                chapter_title = chapter.title or default_chapter_title
            end
        end
    end
    
    if not current_chapter then
        logger.warn("ChapterAnalyzer: No current chapter found")
        return self:getVisibleTextReflowable(ui), default_chapter_title
    end
    
    logger.info("ChapterAnalyzer: Current chapter:", chapter_title)
    
    -- For EPUB, we'll try to get text from the document
    -- Method 1: Try getTextFromPositions if available
    local text = ""
    local text_length = 50000  -- ~50k characters
    
    if ui.document.getTextFromPositions then
        local success, result = pcall(function()
            return ui.document:getTextFromPositions(current_pos, current_pos + text_length)
        end)
        
        if success and result and #result > 100 then
            text = result
            logger.info("ChapterAnalyzer: Got", #text, "characters from positions")
            collectgarbage("collect") -- Force cleanup after large string allocation
            return text, chapter_title
        end
    end
    
    -- Method 2: Try to extract text from current chapter xpointer
    if ui.document.getTextFromXPointer and current_chapter.xpointer then
        local success, result = pcall(function()
            return ui.document:getTextFromXPointer(current_chapter.xpointer)
        end)
        
        if success and result and #result > 100 then
            text = result
            logger.info("ChapterAnalyzer: Got", #text, "characters from xpointer")
            collectgarbage("collect") -- Force cleanup after large string allocation
            return text, chapter_title
        end
    end
    
    -- Method 3: Get visible text (fallback)
    text = self:getVisibleTextReflowable(ui)
    logger.info("ChapterAnalyzer: Using visible text fallback")
    collectgarbage("collect")
    
    return text, chapter_title
end

-- Get currently visible text (reflowable)
function ChapterAnalyzer:getVisibleTextReflowable(ui)
    -- Try multiple methods to get text
    local text = ""
    
    -- Method 1: Try getting text from view
    if ui.view and ui.view.document and ui.view.document.extractText then
        local success, result = pcall(function()
            return ui.view.document:extractText()
        end)
        if success and result and #result > 100 then
            logger.info("ChapterAnalyzer: Got text from view.document.extractText")
            return result
        end
    end
    
    -- Method 2: Try document getFullText
    if ui.document.getFullText then
        local success, result = pcall(function()
            return ui.document:getFullText()
        end)
        if success and result and #result > 100 then
            logger.info("ChapterAnalyzer: Got text from getFullText")
            -- Limit size
            if #result > 100000 then
                result = utf8_sub(result, 1, 100000)
            end
            return result
        end
    end
    
    -- Method 3: Try to read from pages (if document has pages)
    if ui.document.getPageCount and ui.document.getPageText then
        local page_count = ui.document:getPageCount()
        local max_pages = math.min(page_count, 50)
        
        for i = 1, max_pages do
            local success, page_text = pcall(function()
                return ui.document:getPageText(i)
            end)
            if success and page_text then
                text = text .. " " .. page_text
            end
        end
        
        if #text > 100 then
            logger.info("ChapterAnalyzer: Got text from pages")
            return text
        end
    end
    
    -- If nothing worked, return empty
    logger.warn("ChapterAnalyzer: Could not extract any text")
    return ""
end

-- Get text from page-based documents (PDF, DJVU)
function ChapterAnalyzer:getPageBasedText(ui)
    -- Try to get chapter from TOC
    local raw_toc = ui.document:getToc()
    local toc = flattenTOC(raw_toc)
    if not toc or #toc == 0 then
        logger.info("ChapterAnalyzer: No TOC, using current page only")
        return self:getCurrentPageTextPDF(ui)
    end
    
    -- Find current chapter based on page
    local current_page = ui.paging:getCurrentPage()
    local current_chapter = nil
    local max_chapter_page = -1
    
    for _, chapter in ipairs(toc) do
        if chapter.page then
            local p = tonumber(chapter.page)
            if p and p <= current_page and p >= max_chapter_page then
                max_chapter_page = p
                current_chapter = chapter
            end
        end
    end
    
    if not current_chapter then
        logger.warn("ChapterAnalyzer: No current chapter found")
        return self:getCurrentPageTextPDF(ui)
    end
    
    logger.info("ChapterAnalyzer: Current chapter:", current_chapter.title)
    
    -- Get text from current chapter start to next chapter start (or end)
    local start_page = current_chapter.page
    local end_page = next_chapter and next_chapter.page - 1 or ui.document:getPageCount()
    
    -- Limit to reasonable range (max 50 pages for performance)
    if end_page - start_page > 50 then
        end_page = start_page + 50
        logger.info("ChapterAnalyzer: Limited to 50 pages for performance")
    end
    
    logger.info("ChapterAnalyzer: Analyzing pages", start_page, "to", end_page)
    
    -- Collect text from pages
    local chapter_text = ""
    for page = start_page, end_page do
        local page_text = ui.document:getPageText(page)
        if page_text then
            chapter_text = chapter_text .. " " .. page_text
        end
    end
    
    return chapter_text, current_chapter.title
end

-- Get current page text (PDF/page-based) - fallback
function ChapterAnalyzer:getCurrentPageTextPDF(ui)
    local current_page = ui.paging:getCurrentPage()
    
    -- Try to get text from current page and next few pages
    local text = ""
    for i = 0, 4 do  -- Current + 4 pages
        local page = current_page + i
        if page <= ui.document:getPageCount() then
            local page_text = ui.document:getPageText(page)
            if page_text then
                text = text .. " " .. page_text
            end
        end
    end
    
    local default_page_title = ui.loc and ui.loc:t("this_page") or "This Page"
    return text, default_page_title
end

-- Fallback for unknown document types
function ChapterAnalyzer:getFallbackText(ui)
    logger.warn("ChapterAnalyzer: Using fallback text extraction")
    
    -- Try different methods
    local text = ""
    
    -- Method 1: Try to get selection text or visible text
    if ui.highlight and ui.highlight.selected_text then
        text = ui.highlight.selected_text.text or ""
    end
    
    -- Method 2: Try document getTextFromPositions if available
    if #text < 100 and ui.document.getTextFromPositions then
        local success, result = pcall(function()
            return ui.document:getTextFromPositions(0, 10000)
        end)
        if success and result then
            text = result
        end
    end
    
    -- Method 3: Just show a message
    if #text < 100 then
        logger.warn("ChapterAnalyzer: Could not extract text")
        return nil, nil
    end
    
    local default_page_title = ui.loc and ui.loc:t("this_page") or "This Page"
    return text, default_page_title
end

-- Find characters mentioned in text
function ChapterAnalyzer:findCharactersInText(text, characters)
    if not text or not characters then
        return {}
    end
    
    local found_characters = {}
    local text_lower = string.lower(text)
    
    for _, char in ipairs(characters) do
        local name = char.name
        if name and #name >= 1 then
            local name_lower = string.lower(name)
            
            -- Helper to check word boundaries for short names
            local function findWithBoundaries(text, needle)
                if #needle < 4 then
                    local safe_needle = needle:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
                    local pattern = "%f[%w]" .. safe_needle .. "%f[%W]"
                    return string.find(text, pattern)
                else
                    return string.find(text, needle, 1, true)
                end
            end
            
            -- Check full name
            if findWithBoundaries(text_lower, name_lower) then
                table.insert(found_characters, {
                    character = char,
                    count = self:countMentions(text_lower, name_lower)
                })
            else
                -- Check first name only
                local first_name = string.match(name, "^(%S+)")
                if first_name and #first_name >= 1 then
                    local first_name_lower = string.lower(first_name)
                    if findWithBoundaries(text_lower, first_name_lower) then
                        table.insert(found_characters, {
                            character = char,
                            count = self:countMentions(text_lower, first_name_lower)
                        })
                    end
                end
            end
        end
    end
    
    -- Sort by mention count
    table.sort(found_characters, function(a, b)
        return a.count > b.count
    end)
    
    logger.info("ChapterAnalyzer: Found", #found_characters, "characters in text")
    AIHelper:log("ChapterAnalyzer: Found " .. tostring(#found_characters) .. " characters in text")
    
    return found_characters
end

-- Extract text from a specific page range (start_page to end_page)
-- Returns up to max_len characters from the specified region
function ChapterAnalyzer:getTextFromPageRange(ui, start_page, end_page, max_len)
    if not ui or not ui.document then return nil end
    max_len = max_len or 15000
    
    local is_reflowable = ui.rolling ~= nil
    
    if is_reflowable then
        -- Save the reader's actual position so we can restore it
        local saved_xp = ui.document:getXPointer()
        
        local success, result = pcall(function()
            -- Get XPointer for the start of the range
            local start_xp = nil
            if ui.document.getPageXPointer then
                start_xp = ui.document:getPageXPointer(start_page)
            end
            if not start_xp then
                ui.document:gotoPage(start_page)
                start_xp = ui.document:getXPointer()
            end
            
            -- Get XPointer for the end of the range
            local end_xp = nil
            local page_count = ui.document.getPageCount and ui.document:getPageCount()
            if page_count and end_page > page_count and ui.document.getEndXPointer then
                -- Exclusive-end semantics put the last page's end one past the
                -- page count, where no page xpointer exists. Use the document's
                -- real end so the final page is included.
                end_xp = ui.document:getEndXPointer()
            end
            if not end_xp and ui.document.getPageXPointer then
                end_xp = ui.document:getPageXPointer(end_page)
            end
            if not end_xp then
                ui.document:gotoPage(end_page)
                end_xp = ui.document:getXPointer()
            end
            
            if not start_xp or not end_xp then return "" end
            
            -- Extract text between the two XPointers
            local text = ui.document:getTextFromXPointers(start_xp, end_xp) or ""
            
            -- Trim to max_len (take from the beginning since we want this specific range)
            if #text > max_len then
                text = text:sub(1, max_len)
            end
            return text
        end)
        
        -- Always restore the reader's position
        if saved_xp then
            pcall(function() ui.document:gotoXPointer(saved_xp) end)
        end
        
        if success and result and #result > 0 then
            return result
        end
        return nil
    else
        -- PDF: page-by-page extraction
        if not ui.document.getPageText then
            return nil
        end
        local text = ""
        for page = start_page, end_page do
            local page_text = ui.document:getPageText(page) or ""
            if type(page_text) == "table" then
                local texts = {}
                for _, block in ipairs(page_text) do
                    if type(block) == "table" then
                        for j = 1, #block do
                            local span = block[j]
                            if type(span) == "table" and span.word then
                                table.insert(texts, span.word)
                            end
                        end
                    end
                end
                page_text = table.concat(texts, " ")
            end
            text = text .. page_text .. "\n"
            if #text >= max_len then
                return utf8_sub(text, 1, max_len)
            end
        end
        return #text > 0 and text or nil
    end
end

-- Get text for analysis (up to max_len characters before current position)
function ChapterAnalyzer:getTextForAnalysis(ui, max_len, progress_callback, current_page, start_page, target_xp)
    if not ui or not ui.document then
        AIHelper:log("ChapterAnalyzer: getTextForAnalysis - no document")
        return nil
    end
    
    max_len = max_len or 100000 
    local book_text = ""
    AIHelper:log("ChapterAnalyzer: Extracting text for analysis (max " .. tostring(max_len) .. " chars)")
    
    -- Check if it's a reflowable document (EPUB, etc.)
    local is_reflowable = ui.rolling ~= nil
    
    if is_reflowable then
        local current_xp = nil
        
        -- Priority 1: Exact target XPointer (e.g., from a highlighted word)
        if target_xp then
            current_xp = target_xp
            AIHelper:log("ChapterAnalyzer: Using exact target_xp for context boundary")
        end
        
        if not current_xp then
            pcall(function()
                if not ui or not ui.document then return end
                -- Priority 2: Use getPageXPointer if provided and supported
                if current_page and ui.document.getPageXPointer then
                    local total_pages = ui.document:getPageCount() or current_page
                    local safe_pos = math.min(current_page, total_pages)
                    current_xp = ui.document:getPageXPointer(safe_pos)
                end
                -- Fallback to jumping if getPageXPointer is not available but we have a target pos
                if not current_xp and current_page then
                    local total_pages = ui.document:getPageCount() or current_page
                    local safe_pos = math.min(current_page, total_pages)
                    
                    -- Save current position to jump back
                    local current_real_xp = ui.document:getXPointer()
                    if current_real_xp then
                        ui.document:gotoPage(safe_pos)
                        current_xp = ui.document:getXPointer()
                        ui.document:gotoXPointer(current_real_xp)
                    end
                end
                
                -- Ultimate fallback to current screen top
                if not current_xp then 
                    current_xp = ui.document:getXPointer()
                end
            end)
        end
        
        if not current_xp then 
            AIHelper:log("ChapterAnalyzer: getTextForAnalysis - could not get XPointer")
            return nil 
        end
        
        -- Optimization: Try to get start XPointer without jumping to avoid "white flash"
        local success, result = pcall(function()
            if not ui or not ui.document then return "" end
            if progress_callback then progress_callback(0.1) end
            
            local start_xp = nil
            if start_page and start_page > 1 then
                AIHelper:log("ChapterAnalyzer: getTextForAnalysis - incremental mode from page " .. tostring(start_page))
                
                -- Cap the window: never look back more than 60 pages regardless of start_page.
                -- getTextFromXPointers is synchronous and blocking; a large span freezes the UI
                -- on long books (e.g. page 460 of a large EPUB).
                local current_p = current_page or 1
                local max_lookback = 60
                local capped_start = math.max(start_page, current_p - max_lookback)
                if capped_start > start_page then
                    AIHelper:log("ChapterAnalyzer: Capping incremental start_page from " .. tostring(start_page) .. " to " .. tostring(capped_start) .. " (60-page window)")
                    start_page = capped_start
                end

                -- Method 1: Use getPageXPointer (fast, no flash)
                if ui.document.getPageXPointer then
                    start_xp = ui.document:getPageXPointer(start_page)
                end
                
                -- Method 2: Fallback to jumping (causes flash, but only if Method 1 failed)
                if not start_xp then
                    AIHelper:log("ChapterAnalyzer: Fallback to gotoPage for start XPointer")
                    ui.document:gotoPage(start_page)
                    start_xp = ui.document:getXPointer()
                    ui.document:gotoXPointer(current_xp)
                end
            else
                -- Limit window: at most 60 pages back to avoid blocking extraction
                local current_p = current_page or (ui.getCurrentPage and ui:getCurrentPage()) or 1
                local window_start = math.max(1, current_p - 60)
                if ui.document.getPageXPointer then
                    start_xp = ui.document:getPageXPointer(window_start)
                elseif ui.document.gotoPos then
                    -- Legacy fallback: jump to a nearby page instead of position 0
                    local saved_xp = ui.document:getXPointer()
                    ui.document:gotoPage(window_start)
                    start_xp = ui.document:getXPointer()
                    if saved_xp then ui.document:gotoXPointer(saved_xp) end
                end
            end
            
            if not start_xp then return "" end
            
            if progress_callback then progress_callback(0.3) end
            
            -- Extract EVERYTHING from start to here
            local full_text = ui.document:getTextFromXPointers(start_xp, current_xp) or ""
            
            -- Trim to the last max_len characters
            if #full_text > max_len then
                return full_text:sub(-max_len)
            else
                return full_text
            end
        end)
        
        if success and result then
            book_text = result
        else
            AIHelper:log("ChapterAnalyzer: getTextForAnalysis - XPointer extraction failed: " .. tostring(result))
            book_text = ""
        end
    else
        -- For page-based documents (PDF), get text from a limited number of pages before current
        if not ui.document.getPageText then
            logger.warn("ChapterAnalyzer: getPageText not supported on ui.document")
            return ""
        end
        local current_pos = current_page or (ui.view and ui.view.state and ui.view.state.page) or 1
        local max_pages = 100 
        local calc_start_page = math.max(1, current_pos - max_pages)
        if start_page and start_page > 1 then
            calc_start_page = math.max(start_page, calc_start_page)
        end
        
        logger.info("ChapterAnalyzer: Extracting PDF pages", calc_start_page, "to", current_pos)
        AIHelper:log("ChapterAnalyzer: Extracting PDF pages " .. tostring(calc_start_page) .. " to " .. tostring(current_pos))
        
        for page = calc_start_page, current_pos do
            if not ui or not ui.document then break end
            if progress_callback and (page % 10 == 0) and current_pos > calc_start_page then
                progress_callback(0.1 + (0.8 * (page - calc_start_page) / (current_pos - calc_start_page)))
            end
            
            local ok_page, page_text = pcall(function() return ui.document:getPageText(page) end)
            if not ok_page then page_text = "" end
            page_text = page_text or ""
            if type(page_text) == "table" then
                local texts = {}
                for _, block in ipairs(page_text) do
                    if type(block) == "table" then
                        for i = 1, #block do
                            local span = block[i]
                            if type(span) == "table" and span.word then
                                table.insert(texts, span.word)
                            end
                        end
                    end
                end
                page_text = table.concat(texts, " ")
            end
            book_text = book_text .. page_text .. "\n"
        end
    end
    
    -- Limit text length (from the end)
    if #book_text > max_len then
        book_text = book_text:sub(-max_len)
    end
    
    if progress_callback then progress_callback(1.0) end
    logger.info("ChapterAnalyzer: Total characters extracted for analysis:", #book_text)
    AIHelper:log("ChapterAnalyzer: Total characters extracted for analysis: " .. tostring(#book_text))
    return book_text
end

-- Get highlights and notes for analysis
function ChapterAnalyzer:getAnnotationsForAnalysis(ui)
    local annotations_text = ""
    
    -- Try to get annotations from the document/UI
    -- In KOReader, annotations are typically in ui.annotation.annotations
    if ui.annotation and ui.annotation.annotations then
        for _, annot in ipairs(ui.annotation.annotations) do
            if annot.text and #annot.text > 0 then
                annotations_text = annotations_text .. "Highlight: " .. annot.text .. "\n"
            end
            if annot.note and #annot.note > 0 then
                annotations_text = annotations_text .. "Note: " .. annot.note .. "\n"
            end
        end
    end
    
    return #annotations_text > 0 and annotations_text or nil
end

-- Get detailed samples (Start/Mid/End) from each chapter
function ChapterAnalyzer:getDetailedChapterSamples(ui, max_chapters, total_limit, is_full_book, start_page, known_chapters, resolved_current_page)
    if not ui or not ui.document then return nil, nil end
    
    local raw_toc
    pcall(function()
        if ui.document and ui.document.getToc then
            raw_toc = ui.document:getToc()
        end
    end)
    local toc = flattenTOC(raw_toc)
    if not toc or #toc == 0 then 
        logger.info("ChapterAnalyzer: No TOC found for detailed sampling")
        return nil, nil 
    end
    
    local current_page = resolved_current_page
    if not is_full_book then
        if current_page then
            -- The fetch pipeline resolves the page once and passes it through.
            -- Do not mix that value with view/rolling state, which can use a
            -- different pagination coordinate system for reflowable books.
        elseif type(ui.getCurrentPage) == "function" then
            local ok, pg = pcall(function() return ui:getCurrentPage() end)
            if ok and pg then current_page = pg end
        elseif ui.view and ui.view.state and ui.view.state.page then
            current_page = ui.view.state.page
        elseif ui.rolling and ui.rolling.current_page then
            current_page = ui.rolling.current_page
        elseif ui.paging and type(ui.paging.getCurrentPage) == "function" then
            local ok, pg = pcall(function() return ui.paging:getCurrentPage() end)
            if ok and pg then current_page = pg end
        end
    end
    
    max_chapters = max_chapters or 200
    total_limit = total_limit or 150000
    
    -- Non-narrative TOC entries to exclude
    local non_narrative_patterns = {
        "^cover$", "^title", "^copyright", "^table of contents", "^contents$",
        "^dedication", "^acknowledgment", "^also by", "^about the author",
        "^epigraph$", "^foreword$", "^preface$",
        "^appendix", "^glossary", "^index$", "^notes$", "^bibliography",
        "^colophon", "^frontispiece",
    }
    local function isNonNarrative(title)
        if not title then return false end
        local lower = title:lower():gsub("^%s+", ""):gsub("%s+$", "")
        for _, pat in ipairs(non_narrative_patterns) do
            if lower:match(pat) then return true end
        end
        return false
    end

    -- Helper to normalize title for comparison (matching main.lua logic roughly)
    local function normalize(t)
        if not t then return "" end
        return t:lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^chapter%s*", ""):gsub("^ch%.?%s*", "")
    end

    -- Filter chapters
    local active_chapters = {}
    local chapter_titles = {}
    if toc and #toc > 0 then
        for i, chapter in ipairs(toc) do
            local ch_page = tonumber(chapter.page)
            if not is_full_book and current_page and ch_page and ch_page > current_page then
                -- Skip chapters past current_page without breaking (since TOC items may not be strictly page-ordered)
            else
                -- Skip non-narrative chapters
                if isNonNarrative(chapter.title) then
                    AIHelper:log("ChapterAnalyzer: Skipping non-narrative chapter: " .. (chapter.title or tostring(i)))
                else
                    local skip = false
                    if start_page and not is_full_book then
                        -- Scan forward for the next TOC entry with a valid page number
                        local next_chapter_page = math.huge
                        for j = i + 1, #toc do
                            local np = tonumber(toc[j].page)
                            if np then
                                next_chapter_page = np
                                break
                            end
                        end
                        if next_chapter_page <= start_page then
                            -- ONLY skip if it's already in our data
                            if known_chapters then
                                local norm_title = normalize(chapter.title)
                                if known_chapters[norm_title] then
                                    skip = true
                                end
                            else
                                -- Fallback to old behavior if no list provided
                                skip = true
                            end
                        end
                    end
                    
                    if not skip then
                        if #active_chapters >= max_chapters then break end
                        chapter.toc_index = i
                        table.insert(active_chapters, chapter)
                        table.insert(chapter_titles, chapter.title or tostring(i))
                    else
                        AIHelper:log("ChapterAnalyzer: Skipping already-fetched chapter: " .. (chapter.title or tostring(i)))
                    end
                end
            end
        end
    end
    
    -- If no chapters found in TOC, we don't exit; we'll fallback to even sampling later.
    -- However, we still need a count for budget calculations.
    local num_chapters = #active_chapters
    if num_chapters == 0 then
        num_chapters = 20 -- Default budget for even sampling
    end
    
    -- DYNAMIC BUDGET: Scale down for large books to leave room for AI output
    if #active_chapters > 60 then
        -- Very large omnibus: aggressive compression
        total_limit = math.min(total_limit, 60000)
        AIHelper:log("ChapterAnalyzer: Large book detected (" .. num_chapters .. " chapters). Compressed total_limit to " .. total_limit)
    elseif num_chapters > 30 then
        -- Large book: moderate compression
        total_limit = math.min(total_limit, 100000)
        AIHelper:log("ChapterAnalyzer: Medium-large book detected (" .. num_chapters .. " chapters). Compressed total_limit to " .. total_limit)
    end

    -- Calculate budget per chapter
    -- Reserve 20k for the main book_text (last 20k)
    local chapter_total_budget = total_limit - 20000
    local per_chapter_budget = math.floor(chapter_total_budget / num_chapters)
    
    -- Dynamic hard limit based on chapter count
    local max_per_chapter = num_chapters > 60 and 600 or (num_chapters > 30 and 2000 or 3600)
    if per_chapter_budget > max_per_chapter then per_chapter_budget = max_per_chapter end
    
    -- Minimum budget for it to be useful
    if per_chapter_budget < 300 then per_chapter_budget = 300 end
    
    local sample_len = math.floor(per_chapter_budget / 3)
    local samples = {}
    
    if #active_chapters > 0 then
        logger.info("ChapterAnalyzer: Detailed sampling for", #active_chapters, "chapters. Budget per chapter:", per_chapter_budget)
        AIHelper:log("ChapterAnalyzer: Sampling " .. #active_chapters .. " chapters with " .. per_chapter_budget .. " chars each.")
        
        for i, chapter in ipairs(active_chapters) do
            if not ui or not ui.document then break end
            local is_current_chapter = false
            if not is_full_book and current_page and chapter.page and chapter.page <= current_page then
                local next_chapter = toc[chapter.toc_index + 1]
                if not next_chapter or (next_chapter.page and next_chapter.page > current_page) then
                    is_current_chapter = true
                end
            end

            local success, chapter_text = pcall(function()
                if not ui or not ui.document then return "" end
                if is_current_chapter then
                    local end_page = self:getEndPageForCurrentPage(ui, current_page)
                    return self:getTextFromPageRange(ui, chapter.page, end_page, total_limit)
                elseif ui.document.getTextFromXPointer and chapter.xpointer then
                    -- EPUB: Usually returns the full text of the chapter file
                    return ui.document:getTextFromXPointer(chapter.xpointer)
                end
                return ""
            end)
            
            if success and chapter_text and #chapter_text > 100 then
                local start_txt = utf8_sub(chapter_text, 1, sample_len)
                local mid_start = math.max(1, math.floor(#chapter_text / 2) - math.floor(sample_len / 2))
                local mid_txt = utf8_sub(chapter_text, mid_start, mid_start + sample_len)
                local end_txt = utf8_sub(chapter_text, -sample_len, -1)
                
                table.insert(samples, string.format(
                    "CHAPTER [%s]:\n[START]: %s\n[MID]: %s\n[END]: %s",
                    chapter.title or tostring(i),
                    start_txt, mid_txt, end_txt
                ))
            end
        end
    else
        -- NO TOC FALLBACK: Even sampling across the book
        local max_range = 0
        pcall(function()
            if ui and ui.document then
                max_range = (is_full_book or not current_page) and ui.document:getPageCount() or current_page
            end
        end)
        if max_range and max_range > 0 then
            local num_sections = math.min(20, max_range)
            local step = math.floor(max_range / num_sections)
            local log_msg = (toc and #toc > 0)
                and ("ChapterAnalyzer: No un-fetched chapters found up to page " .. tostring(current_page) .. ". Using even sampling across " .. num_sections .. " sections.")
                or ("ChapterAnalyzer: No TOC found. Using even sampling across " .. num_sections .. " sections.")
            AIHelper:log(log_msg)
            
            for i = 1, num_sections do
                if not ui or not ui.document then break end
                local p = (i - 1) * step + 1
                local success, section_text = pcall(function()
                    if ui and ui.document and ui.document.getPageText then
                        return ui.document:getPageText(p)
                    end
                    return ""
                end)
                
                if success and section_text and #section_text > 100 then
                    table.insert(samples, string.format(
                        "SECTION [%d] (Near Page %d):\n%s",
                        i, p, utf8_sub(section_text, 1, per_chapter_budget)
                    ))
                    table.insert(chapter_titles, "Section " .. i)
                end
            end
        end
    end
    
    return (#samples > 0 and table.concat(samples, "\n\n---\n\n") or nil), chapter_titles
end

function ChapterAnalyzer:countMentions(text, name)
    local count = 0
    local pos = 1
    
    local pattern
    if #name < 4 then
        local safe_name = name:lower():gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
        pattern = "%f[%w]" .. safe_name .. "%f[%W]"
    end
    
    while true do
        local start_pos
        if pattern then
            start_pos = text:lower():find(pattern, pos)
        else
            start_pos = text:lower():find(name:lower(), pos, true)
        end
        if not start_pos then break end
        count = count + 1
        pos = start_pos + 1
    end
    
    return count
end

-- Extract a sentence-aware snippet around a match position in raw text.
-- Returns: ONLY the sentence containing the match,
-- capped at max_len characters.
local function extractSentenceSnippet(text, match_pos, max_len)
    max_len = max_len or 300
    if not text or not match_pos then return "" end

    -- Use pattern matching to find boundaries, which is much faster than byte loops in Lua
    local before = text:sub(1, match_pos - 1)
    local sent_start = 1
    -- Find the last sentence-ending character before the match
    local b_start, b_end = before:find("[.!?\n][^.!?\n]*$")
    if b_start then
        sent_start = b_start + 1
    end

    local after = text:sub(match_pos)
    local sent_end = #text
    -- Find the first sentence-ending character after the match
    local a_start, a_end = after:find("[.!?\n]")
    if a_start then
        sent_end = match_pos + a_start - 1
    end

    -- Trim to max_len if still too long
    if (sent_end - sent_start) > max_len then
        local half = math.floor(max_len / 2)
        sent_start = math.max(sent_start, match_pos - half)
        sent_end = math.min(sent_end, match_pos + half)
    end

    return text:sub(sent_start, sent_end):gsub("^%s+", ""):gsub("%s+$", "")
end


-- Scan a single TOC entry for occurrences of `name`.
-- Returns a list of { chapter, page, snippet } tables.
-- next_paged_entry: the first entry AFTER toc_entry that carries a page number
-- (may be next_toc_entry itself, or nil). The page-range fallback and the page
-- interpolation use it as the end bound when the immediate successor has none.
function ChapterAnalyzer:findMentionsInChapter(ui, entity, toc_entry, next_toc_entry, yield_fn, next_paged_entry)
    if not ui or not ui.document or not entity or not entity.name or not toc_entry then return {} end
    -- A page-based TOC entry (PDF, or an EPUB with a page-only TOC) has no
    -- xpointer. Do not reject it here, or the page fallbacks below never run.
    -- Reject only when there is no location marker of any kind.
    if not toc_entry.xpointer and not toc_entry.page then return {} end

    local name = entity.name
    local name_lower = name:lower()
    local chapter_mentions = {}

    -- Page bounds actually used to extract raw_text, when known. The recovery
    -- fallback below sets these to the real range it read. A malformed TOC entry
    -- often has no page marker, so the page estimate must interpolate over this
    -- known span instead of defaulting to the whole book.
    -- extracted_end_page is EXCLUSIVE (the first page after the text read), which
    -- is what the position-to-page interpolation below expects.
    local extracted_start_page, extracted_end_page

    -- Load chapter text first so we can use frequency analysis when building terms
    local ok, raw_text = pcall(function()
        if toc_entry.xpointer then
            if type(toc_entry.xpointer) == "string" and toc_entry.xpointer:sub(1, 5) == "page:" then
                local p = tonumber(toc_entry.xpointer:match("page:(%d+)"))
                if p and ui.document.getPageText then
                    -- next_p is where the NEXT section begins. The loop below reads
                    -- end_p inclusive, so stop one page earlier to avoid pulling the
                    -- next section's first page in (matches the page fallbacks below).
                    local next_p = next_toc_entry and next_toc_entry.xpointer and tonumber(next_toc_entry.xpointer:match("page:(%d+)"))
                    local end_p = (next_p and (next_p - 1)) or (ui.document.getTotalPages and ui.document:getTotalPages()) or p
                    if end_p < p then end_p = p end
                    local txt = ""
                    for curr_p = p, end_p do
                        local pt = ui.document:getPageText(curr_p)
                        if type(pt) == "table" then
                            local parts = {}
                            for _, block in ipairs(pt) do
                                if type(block) == "table" then
                                    for _, span in ipairs(block) do
                                        if type(span) == "table" and span.word then
                                            table.insert(parts, span.word)
                                        end
                                    end
                                end
                            end
                            pt = table.concat(parts, " ")
                        end
                        txt = txt .. (pt or "") .. "\n"
                    end
                    return txt
                end
            end
            if ui.document.getTextFromXPointers then
                local end_xp = next_toc_entry and next_toc_entry.xpointer
                if not end_xp and ui.document.getEndXPointer then
                    end_xp = ui.document:getEndXPointer()
                end
                if end_xp then
                    return ui.document:getTextFromXPointers(toc_entry.xpointer, end_xp) or ""
                end
            end
            if ui.document.getTextFromXPointer then
                return ui.document:getTextFromXPointer(toc_entry.xpointer) or ""
            end
        end
        
        -- Fallback for PDF/page-based documents
        if toc_entry.page and ui.document.getPageText then
            local start_pg = tonumber(toc_entry.page)
            -- next_toc_entry.page is where the NEXT chapter begins. The loop below
            -- reads end_pg inclusive, so stop one page earlier to avoid pulling the
            -- next chapter's first page into this chapter (matches the page-range
            -- fallback further down).
            local end_pg = (next_toc_entry and tonumber(next_toc_entry.page) and (tonumber(next_toc_entry.page) - 1))
                or (ui.document.getTotalPages and ui.document:getTotalPages()) or start_pg
            if start_pg then
                -- A very short chapter can share a page with the next one; read that page.
                if end_pg < start_pg then end_pg = start_pg end
                local txt = ""
                for p = start_pg, end_pg do
                    local pt = ui.document:getPageText(p)
                    if type(pt) == "table" then
                        local parts = {}
                        for _, block in ipairs(pt) do
                            if type(block) == "table" then
                                for _, span in ipairs(block) do
                                    if type(span) == "table" and span.word then
                                        table.insert(parts, span.word)
                                    end
                                end
                            end
                        end
                        pt = table.concat(parts, " ")
                    end
                    txt = txt .. (pt or "") .. "\n"
                end
                return txt
            end
        end
        return ""
    end)

    -- Fallback: the TOC is the default source, but some books have a missing or
    -- malformed table of contents (entries with no location marker, or listed out
    -- of document order). In those books the xpointer extraction above returns
    -- nothing. When that happens, extract the chapter by page range instead, the
    -- same robust method the X-Ray fetch uses. A short-but-real extraction (a
    -- part heading whose span is just its own title) is NOT a failure: the
    -- fallback would re-read pages owned by the next chapter and mis-attribute
    -- their mentions, so only an effectively empty extraction triggers it.
    if (not ok or not raw_text or not raw_text:find("%S")) and self.getTextFromPageRange then
        local start_pg = tonumber(toc_entry.page)
        -- A malformed entry can lack a page marker while its xpointer still
        -- resolves to a position (it only extracts no text). Resolve the page
        -- from the xpointer so such entries also recover.
        if not start_pg and type(toc_entry.xpointer) == "string" then
            start_pg = tonumber(toc_entry.xpointer:match("^page:(%d+)"))
            if not start_pg and ui.document.getPageFromXPointer then
                local okp, p = pcall(function() return ui.document:getPageFromXPointer(toc_entry.xpointer) end)
                if okp then start_pg = tonumber(p) end
            end
        end
        -- getTextFromPageRange has different end semantics per document type
        -- (see getEndPageForCurrentPage). Reflowable: the end page is EXCLUSIVE
        -- (it stops at the start xpointer of end_pg), so pass the next chapter's
        -- first page to read this chapter through its last page. Page-based:
        -- the end page is INCLUSIVE, so stop one page before the next chapter.
        local is_reflowable = ui.rolling ~= nil
        -- End bound: the next entry that carries a page number. The immediate
        -- successor can lack one; ending at the book's page count there would
        -- re-read the whole tail of the book for every such entry.
        local next_pg = (next_toc_entry and tonumber(next_toc_entry.page))
            or (next_paged_entry and tonumber(next_paged_entry.page))
        local end_pg = next_pg and (is_reflowable and next_pg or (next_pg - 1))
        -- Last chapter: no later paged entry. Use the document page count. Prefer
        -- getPageCount (the method the rest of the plugin relies on) and fall back
        -- to getTotalPages, so a reflowable book with a broken TOC still recovers.
        if not end_pg then
            local page_count
            if ui.document.getPageCount then
                page_count = ui.document:getPageCount()
            elseif ui.document.getTotalPages then
                page_count = ui.document:getTotalPages()
            end
            if page_count then
                -- Reflowable ends are exclusive: one past the count makes
                -- getTextFromPageRange read through the final page (it resolves
                -- an out-of-range end to the document's end xpointer).
                end_pg = is_reflowable and (page_count + 1) or page_count
            end
        end
        -- A very short chapter can share a page with the next one; read that page.
        -- On reflowable documents the exclusive end must be at least one page
        -- past the start, or the range is empty.
        if start_pg and end_pg then
            if is_reflowable then
                if end_pg <= start_pg then end_pg = start_pg + 1 end
            elseif end_pg < start_pg then
                end_pg = start_pg
            end
        end
        if start_pg and end_pg and end_pg >= start_pg then
            local ok2, txt = pcall(function()
                return self:getTextFromPageRange(ui, start_pg, end_pg, 5000000)
            end)
            if ok2 and txt and #txt >= 10 then
                raw_text = txt
                ok = true
                -- Remember the range this text really came from, so the page
                -- estimate below interpolates over it and does not fall back to
                -- the whole-book span when the TOC entry has no page marker.
                -- Normalize to an exclusive end for the interpolation.
                extracted_start_page = start_pg
                extracted_end_page = is_reflowable and math.max(end_pg, start_pg + 1) or (end_pg + 1)
            end
        end
    end

    if not ok or not raw_text or #raw_text < 10 then return {} end

    local text_lower = raw_text:lower()

    -- Count occurrences of a needle in text_lower (used for frequency check)
    local function countIn(needle)
        local escaped = needle:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
        local pattern = escaped
        if #needle < 4 then
            pattern = "%f[%w]" .. escaped .. "%f[%W]"
        end
        local _, n = text_lower:gsub(pattern, "")
        return n
    end

    -- Honorifics: fast-path blocklist for known titles.
    -- Short honorifics (< 3 chars) are already caught by the length check;
    -- 3-char ones (mr., mrs, sir, dr., etc.) need explicit listing since they
    -- can have plausible frequency ratios in heavily character-focused chapters.
    local honorifics = {
        ["mr"] = true, ["mr."] = true, ["mrs"] = true, ["mrs."] = true, ["ms"] = true, ["ms."] = true,
        ["dr"] = true, ["dr."] = true, ["sir"] = true, ["rev"] = true, ["rev."] = true, ["lt"] = true, ["lt."] = true,
        ["col"] = true, ["col."] = true, ["sgt"] = true, ["sgt."] = true, ["gen"] = true, ["gen."] = true,
        ["miss"] = true, ["lord"] = true, ["lady"] = true, ["dame"] = true, ["prof"] = true, ["prof."] = true,
        ["capt"] = true, ["capt."] = true, ["st"] = true, ["st."] = true, ["jr"] = true, ["jr."] = true,
        
        -- International
        ["m"] = true, ["m."] = true, ["mme"] = true, ["mme."] = true, ["mlle"] = true, ["mlle."] = true, ["mgr"] = true,
        ["herr"] = true, ["frau"] = true, ["hr"] = true, ["hr."] = true, ["fr"] = true, ["fr."] = true,
        ["sr"] = true, ["sr."] = true, ["sra"] = true, ["sra."] = true, ["don"] = true, ["dona"] = true, ["doña"] = true,
        ["bey"] = true, ["hanım"] = true,
        ["пан"] = true, ["пані"] = true, ["г-н"] = true, ["г-жа"] = true,
    }

    -- 2. Type-Aware Entity Classification
    -- Characters and Historical Figures have a 'role' but not a term 'definition'.
    local is_person = (entity.role ~= nil) and (entity.definition == nil)
    local is_term   = (entity.definition ~= nil)

    -- 1. Calculate the maximum frequency among the full name AND all AI-provided aliases.
    -- This provides a much more robust baseline for what constitutes "too generic".
    local max_base_freq = countIn(name_lower)
    if entity.aliases and type(entity.aliases) == "table" then
        for _, alias in ipairs(entity.aliases) do
            if type(alias) == "string" and #alias > 3 then
                max_base_freq = math.max(max_base_freq, countIn(alias:lower()))
            end
        end
    end
    local name_freq = math.max(1, max_base_freq)

    local function isTooGeneric(term)
        local term_l = term:lower()
        if #term < 2 or honorifics[term_l] then return true end
        -- Relax the multiplier for people and terms to prevent self-suppression in high-frequency fiction
        local limit
        if is_person then
            limit = math.max(10, name_freq * 5)
        elseif is_term then
            limit = math.max(50, name_freq * 10)
        else
            limit = 100
        end
        return countIn(term_l) > limit
    end

    -- Always start with the full name
    local terms = { { s = name_lower, l = #name_lower } }

    if is_person then
        -- Auto-generate first and last name components for people
        local first_name = name:match("^(%S+)")
        local last_name  = name:match("(%S+)$")
        if first_name and first_name ~= name then
            local fl = first_name:lower()
            if not honorifics[fl] and not isTooGeneric(fl) then
                table.insert(terms, { s = fl, l = #fl })
            end
        end
        if last_name and last_name ~= first_name and last_name ~= name then
            local ll = last_name:lower()
            if not honorifics[ll] and not isTooGeneric(ll) then
                table.insert(terms, { s = ll, l = #ll })
            end
        end
    else
        -- For non-people (Terms, Locations), handle articles and variations
        -- a. Strip leading articles (The, A, An, Der, Die, Das, Le, La, El, etc.)
        local stripped = name:match("^[Tt]he%s+(.+)") or 
                         name:match("^[Aa]n?%s+(.+)") or
                         name:match("^[Dd][ie][er]%s+(.+)") or
                         name:match("^[Dd]as%s+(.+)") or
                         name:match("^[Ll][ae]s?%s+(.+)") or
                         name:match("^[Ll]'%s*(.+)") or
                         name:match("^[Ee]l%s+(.+)") or
                         name:match("^[Uu]n[ae]?s?%s+(.+)")

        if stripped and stripped ~= name then
            local sl = stripped:lower()
            -- Bypassing isTooGeneric for direct article stripping; this is a high-value core variation.
            table.insert(terms, { s = sl, l = #sl })
        end
        
        if is_term then
            -- Never split multi-word terms into single-word aliases.
            -- Instead, apply plural/singular variations to the full term name.
            if name_lower:sub(-1) == "s" then
                local singular = name_lower:sub(1, -2)
                if #singular > 3 and not isTooGeneric(singular) then
                    table.insert(terms, { s = singular, l = #singular })
                end
            else
                local plural = name_lower .. "s"
                if not isTooGeneric(plural) then
                    table.insert(terms, { s = plural, l = #plural })
                end
            end
        else
            -- Locations: simple plural/singular variations (existing behavior)
            if name_lower:sub(-1) == "s" then
                local singular = name_lower:sub(1, -2)
                if #singular > 3 then
                    table.insert(terms, { s = singular, l = #singular })
                end
            else
                local plural = name_lower .. "s"
                table.insert(terms, { s = plural, l = #plural })
            end
        end
        
        -- Logging the terms we are about to search for debugging
        local log_terms = {}
        for _, t in ipairs(terms) do table.insert(log_terms, t.s) end
        logger.info("XRayPlugin: Searching for mentions of '" .. name .. "' using variants: " .. table.concat(log_terms, " | "))
    end

    -- 3. Add AI-provided aliases, filtered by the same rules
    if entity.aliases and type(entity.aliases) == "table" then
        for _, alias in ipairs(entity.aliases) do
            if type(alias) == "string" then
                local al = alias:lower()
                if not honorifics[al] and not isTooGeneric(al) then
                    local exists = false
                    for _, t in ipairs(terms) do
                        if t.s == al then exists = true; break end
                    end
                    if not exists then
                        table.insert(terms, { s = al, l = #al })
                    end
                end
            end
        end
    end

    local pos = 1

    -- Pre-calculate the first match position for each term.
    -- Enforce strict word boundaries for all single-word terms (no spaces or hyphens)
    -- to prevent substring matches (e.g. "flow" matching "airflow" or "flower").
    for _, t in ipairs(terms) do
        local is_single_word = not t.s:find("[%s%-]")
        if is_single_word then
            local safe_s = t.s:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
            t.pattern = "%f[%w]" .. safe_s .. "%f[%W]"
            t.next_p = text_lower:find(t.pattern, pos)
        else
            t.next_p = text_lower:find(t.s, pos, true)
        end
    end


    local last_yield = os.clock()
    
    while true do
        local min_p = math.huge
        local best_term = nil
        
        for _, t in ipairs(terms) do
            if t.next_p and t.next_p < min_p then
                min_p = t.next_p
                best_term = t
            end
        end
        
        if not best_term then
            break
        end
        
        local match_pos = min_p

        -- Prefer the real range the recovery fallback read. A malformed TOC entry
        -- has no page marker, so keying on toc_entry.page there would default the
        -- span to the whole book and scatter this chapter's mentions across it.
        local start_page = extracted_start_page or tonumber(toc_entry.page) or 1
        -- end_page is EXCLUSIVE: the page where the next chapter starts. The
        -- interpolation below maps fraction f (0 <= f < 1) of the text onto
        -- [start_page, end_page), so the chapter's last page is reachable and
        -- the first page of the next chapter is not. Prefer getPageCount (the
        -- method the rest of the plugin uses) and fall back to getTotalPages
        -- for the last chapter.
        local end_page = extracted_end_page
            or (next_toc_entry and tonumber(next_toc_entry.page))
            or (next_paged_entry and tonumber(next_paged_entry.page))
            or (ui.document.getPageCount and ui.document:getPageCount())
            or (ui.document.getTotalPages and ui.document:getTotalPages())
            or start_page
        if end_page < start_page then end_page = start_page end

        local est_page = start_page
        local total_chars = #raw_text
        if total_chars > 0 and end_page > start_page then
            local fraction = match_pos / total_chars
            est_page = math.floor(start_page + ((end_page - start_page) * fraction))
        end

        table.insert(chapter_mentions, {
            chapter = toc_entry.title or "???",
            page    = est_page,
            snippet = extractSentenceSnippet(raw_text, match_pos, 300),
        })
        
        pos = match_pos + best_term.l
        
        -- Update ONLY the term we just found. Others are still valid if their next_p >= pos.
        for _, t in ipairs(terms) do
            if not t.next_p or t.next_p < pos then
                if t.pattern then
                    t.next_p = text_lower:find(t.pattern, pos)
                else
                    t.next_p = text_lower:find(t.s, pos, true)
                end
            end
        end

        -- Yield every 100ms to keep UI alive
        if yield_fn and (os.clock() - last_yield > 0.1) then
            yield_fn()
            last_yield = os.clock()
        end
    end
    return chapter_mentions
end

function ChapterAnalyzer:scanMentionsAsync(ui, entity, toc, min_page, max_page, on_progress, on_complete)
    if not ui or not ui.document or not entity or not entity.name then 
        if on_complete then
            -- Schedule the callback so it executes asynchronously, preventing 
            -- a nil reference crash in the caller's assignment logic.
            local UIManager = require("ui/uimanager")
            UIManager:scheduleIn(0, function() on_complete({}) end)
        end
        return { cancel = function() end } 
    end

    local scan_toc = toc
    if not scan_toc or #scan_toc == 0 then
        local page_count = ui.document:getPageCount() and ui.document:getPageCount() or (ui.document.getTotalPages and ui.document:getTotalPages()) or 100
        local num_sections = math.min(20, page_count)
        local step = math.floor(page_count / num_sections)
        if step < 1 then step = 1 end
        scan_toc = {}
        for idx = 1, num_sections do
            local p = (idx - 1) * step + 1
            table.insert(scan_toc, {
                title = (ui.loc and ui.loc:t("this_page") or "Section") .. " " .. idx,
                page = p,
                xpointer = "page:" .. p
            })
        end
    end

    -- Scan in ascending page order. Some books list TOC entries out of document
    -- order. The boundary math below (next entry = this chapter's end) and the
    -- spoiler break both assume ascending pages, so an out-of-order TOC would
    -- give an end page before the start (chapter unread) or break the loop early
    -- and skip later chapters. Sort a copy so the caller's TOC is not mutated.
    --
    -- Two constraints keep the entry -> next entry chain intact (the next
    -- entry's xpointer is this chapter's end bound in findMentionsInChapter):
    --  * table.sort is not stable, so same-page entries (a parent heading and
    --    its first child) must tie-break on original TOC order. Otherwise the
    --    child can end up before its parent and read an inverted range.
    --  * Entries with no page marker anchor to the paged entry LISTED before
    --    them and move with it, so they keep their real neighbourhood when the
    --    paged entries re-sort. Keeping them at a fixed index instead would
    --    strand them between arbitrary strangers, inverting the chain; pushing
    --    them to the end would give them no next entry, so they would read
    --    from their xpointer to the end of the book.
    do
        local with_page, head = {}, {}
        for _, e in ipairs(scan_toc) do
            if tonumber(e.page) then
                with_page[#with_page + 1] = { entry = e, idx = #with_page + 1, children = {} }
            elseif #with_page > 0 then
                local host = with_page[#with_page].children
                host[#host + 1] = e
            else
                head[#head + 1] = e
            end
        end
        table.sort(with_page, function(a, b)
            local pa, pb = tonumber(a.entry.page), tonumber(b.entry.page)
            if pa ~= pb then return pa < pb end
            return a.idx < b.idx
        end)
        local sorted = {}
        for _, e in ipairs(head) do sorted[#sorted + 1] = e end
        for _, w in ipairs(with_page) do
            sorted[#sorted + 1] = w.entry
            for _, c in ipairs(w.children) do sorted[#sorted + 1] = c end
        end
        scan_toc = sorted
    end

    local UIManager = require("ui/uimanager")
    local cancel_handle = { _cancelled = false }
    function cancel_handle:cancel()
        self._cancelled = true
    end

    local mentions = {}
    -- A page-based TOC can list a parent heading and its first child on the
    -- same page. Both read that page, so the same passage is found twice under
    -- two chapter titles. Drop exact repeats (same page, same snippet).
    local seen_mentions = {}
    local total_chapters = #scan_toc

    -- Cooperative multitasking using Coroutines
    local scan_co = coroutine.create(function()
        for i = 1, total_chapters do
            if cancel_handle._cancelled then break end

            local entry = scan_toc[i]
            local next_entry = scan_toc[i + 1]
            -- First later entry with a page number: the end bound for the
            -- page-range paths when the immediate successor has none.
            local next_paged_entry = nil
            for j = i + 1, total_chapters do
                if tonumber(scan_toc[j].page) then
                    next_paged_entry = scan_toc[j]
                    break
                end
            end

            local start_p = tonumber(entry.page)
            local end_p = next_entry and tonumber(next_entry.page) or math.huge

            if start_p and max_page and start_p > max_page then
                -- Reached spoiler limit
                break
            end

            if not (min_page and end_p <= min_page) then
                -- We pass a yield function that will pause the coroutine
                local chapter_mentions = self:findMentionsInChapter(ui, entity, entry, next_entry, function()
                    coroutine.yield()
                end, next_paged_entry)
                
                -- Filter out mentions that pass max_page or are before min_page
                for _, m in ipairs(chapter_mentions) do
                    if not (max_page and m.page and m.page > (max_page + 5)) and not (min_page and m.page and m.page <= min_page) then
                        local key = tostring(m.page) .. "\0" .. tostring(m.snippet)
                        if not seen_mentions[key] then
                            seen_mentions[key] = true
                            table.insert(mentions, m)
                        end
                    end
                end

                if on_progress then
                    on_progress(mentions, i, total_chapters)
                end
            end

            -- Force GC every chapter to keep memory pressure low
            collectgarbage("collect")
            
            -- Yield after each chapter
            coroutine.yield()
        end
        
        if on_complete then on_complete(mentions) end
    end)

    local function resumeScan()
        if cancel_handle._cancelled or not ui or not ui.document then return end
        
        local ok, err = coroutine.resume(scan_co)
        if not ok then
            logger.error("XRayPlugin: Mentions scan error:", err)
            if on_complete then on_complete(mentions) end
            return
        end

        if coroutine.status(scan_co) ~= "dead" then
            -- Schedule next chunk
            local delay = 0.01
            UIManager:scheduleIn(delay, resumeScan)
        end
    end

    -- Start the scan
    UIManager:scheduleIn(0.2, resumeScan)
    
    return cancel_handle
end

return ChapterAnalyzer
