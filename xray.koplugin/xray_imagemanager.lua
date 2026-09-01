-- xray_imagemanager.lua - Document Image and Map Extraction & Tracking for KOReader X-Ray
local logger = require("logger")
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or type(lfs) ~= "table" then
    ok_lfs, lfs = pcall(require, "lfs")
end
if not ok_lfs or type(lfs) ~= "table" then lfs = nil end

local plugin_path = ((...) or ""):match("(.-)[^%.]+$") or ""
local utils = require(plugin_path .. "xray_utils")

local ImageManager = {}

function ImageManager:new(plugin)
    local o = {
        plugin = plugin,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Generate a safe unique ID for an image entry
function ImageManager:generateImageId(href, index)
    if not href or href == "" then
        return "img_" .. tostring(index or os.time())
    end
    local clean = href:gsub("[^%w%._%-]", "_")
    return clean .. "_" .. tostring(index or 1)
end

-- Ensure sidecar image directory exists
function ImageManager:getImageDir(book_path)
    if not book_path then return nil end
    local sidecar_dir = DocSettings:getSidecarDir(book_path)
    local image_dir = sidecar_dir .. "/xray/images"
    if lfs then
        pcall(function()
            lfs.mkdir(sidecar_dir)
            lfs.mkdir(sidecar_dir .. "/xray")
            lfs.mkdir(image_dir)
        end)
    end
    return image_dir
end

-- Check if an image title or filename suggests it is a map or diagram
function ImageManager:classifyImage(title, href)
    local text = (tostring(title or "") .. " " .. tostring(href or "")):lower()
    if text:find("map") or text:find("karte") or text:find("carte") or text:find("mapa") or text:find("plano") then
        return "map"
    elseif text:find("diagram") or text:find("chart") or text:find("tree") or text:find("genealog") or text:find("lineage") or text:find("schema") then
        return "diagram"
    elseif text:find("plan") or text:find("layout") or text:find("floor") then
        return "diagram"
    elseif text:find("illus") or text:find("plate") or text:find("figure") or text:find("fig") then
        return "illustration"
    end
    return "general"
end

-- Check if an image is purely ornamental / decorative noise
function ImageManager:isOrnamental(image, filter_mode)
    if filter_mode == "all" then
        return false
    end
    
    local text = (tostring(image.title or "") .. " " .. tostring(image.href or "") .. " " .. tostring(image.id or "")):lower()
    
    -- Blacklisted decorative filenames and IDs
    local ornamental_patterns = {
        "ornament", "divider", "decoration", "bullet", "flourish",
        "vignette", "border", "dropcap", "drop_cap", "line_break",
        "colophon", "publisher_logo", "logo_small", "sep_line",
        "header_icon", "footer_icon", "star_sep", "fleuron", "orn_",
        "separator", "dingbat", "spacer", "tailpiece", "headpiece"
    }
    for _, pat in ipairs(ornamental_patterns) do
        if text:find(pat) then
            return true
        end
    end
    
    if not image then return true end
    
    if filter_mode == "maps_only" or filter_mode == "large_only" then
        local cat = (image.category or "image"):lower()
        if cat == "map" or cat == "diagram" then
            return false
        end
        local w = tonumber(image.width) or 0
        local h = tonumber(image.height) or 0
        if w >= 500 or h >= 500 then
            return false
        end
        return true
    end
    
    -- "all" mode includes all illustrations and maps
    return false
end

-- Extract image file from an EPUB / archive to the sidecar images directory
function ImageManager:extractImageToFile(book_path, image)
    if not image then return nil end
    if image.cached_file then
        local f = io.open(image.cached_file, "rb")
        if f then
            f:close()
            return image.cached_file
        end
    end
    if not book_path or not image.href then return nil end
    local image_dir = self:getImageDir(book_path)
    if not image_dir then return nil end
    
    -- Target extracted file path
    local ext = image.href:match("%.([%w]+)$") or "jpg"
    local safe_id = image.id or self:generateImageId(image.href, image.page)
    local target_path = image_dir .. "/" .. safe_id .. "." .. ext
    
    -- Check if already extracted
    if lfs then
        local attr = lfs.attributes(target_path)
        if attr and attr.size and attr.size > 0 then
            image.cached_file = target_path
            return target_path
        end
    else
        local f = io.open(target_path, "rb")
        if f then
            f:close()
            image.cached_file = target_path
            return target_path
        end
    end
    
    -- Extract using unzip if available on device
    local escaped_book = book_path:gsub("'", "'\\''")
    local escaped_href = image.href:gsub("'", "'\\''")
    local escaped_target = target_path:gsub("'", "'\\''")
    
    -- Direct extraction command
    local cmd = string.format("unzip -p '%s' '%s' > '%s'", escaped_book, escaped_href, escaped_target)
    local rc = os.execute(cmd)
    
    if rc == 0 or rc == true then
        local attr = lfs and lfs.attributes(target_path)
        if attr and attr.size and attr.size > 0 then
            image.cached_file = target_path
            return target_path
        end
    end
    
    -- Fallback: try case-insensitive or base filename match in archive
    local base_name = image.href:match("([^/]+)$") or image.href
    local fallback_cmd = string.format("unzip -p '%s' '*%s' > '%s'", escaped_book, base_name:gsub("'", "'\\''"), escaped_target)
    local rc2 = os.execute(fallback_cmd)
    if rc2 == 0 or rc2 == true then
        local attr = lfs and lfs.attributes(target_path)
        if attr and attr.size and attr.size > 0 then
            image.cached_file = target_path
            return target_path
        end
    end
    
    return nil
end

-- Filter images based on selected tab and reading progress
function ImageManager:getFilteredImages(images, tab, current_page, filter_mode, series_images)
    images = images or {}
    series_images = series_images or {}
    filter_mode = filter_mode or "standard"
    
    local results = {}
    
    -- 1. Handle Series Tab specifically
    if tab == "series" then
        for _, img in ipairs(series_images) do
            local item = {}
            for k, v in pairs(img) do item[k] = v end
            item.is_series = true
            table.insert(results, item)
        end
        return results
    end
    
    -- 2. Process current book images
    for _, img in ipairs(images) do
        local is_hidden = (img.is_hidden == true)
        local is_fav = (img.is_favorite == true)
        
        local include = false
        if tab == "hidden" then
            include = is_hidden
        elseif tab == "favorites" then
            -- Favorites are explicitly curated: ALWAYS show all favorites
            include = is_fav and not is_hidden
        else -- "all" tab: filter according to active filter_mode
            local is_ornamental = self:isOrnamental(img, filter_mode)
            include = not is_hidden and not is_ornamental
        end
        
        if include then
            local item = {}
            for k, v in pairs(img) do item[k] = v end
            
            -- Spoiler calculation: if image appears after current_page
            if current_page and item.page and tonumber(item.page) then
                item.is_spoiler = tonumber(item.page) > tonumber(current_page)
            else
                item.is_spoiler = false
            end
            
            table.insert(results, item)
        end
    end
    
    -- Sort: Favorites first, then strictly by book page order
    table.sort(results, function(a, b)
        if (a.is_favorite and true or false) ~= (b.is_favorite and true or false) then
            return a.is_favorite == true
        end
        local pA = tonumber(a.page) or 0
        local pB = tonumber(b.page) or 0
        if pA ~= pB then
            return pA < pB
        end
        return (a.title or "") < (b.title or "")
    end)
    
    return results
end

local function matchesImageKey(img, key)
    if not img or not key then return false end
    return (img.id and img.id == key)
        or (img.href and img.href == key)
        or (img.src and img.src == key)
        or (img.title and img.title == key)
        or (img.cached_file and img.cached_file == key)
        or (img.local_file and img.local_file == key)
end

-- Toggle favorite status for an image
function ImageManager:toggleFavorite(book_data, image_id)
    if not book_data or not book_data.images or not image_id then return false end
    for _, img in ipairs(book_data.images) do
        if matchesImageKey(img, image_id) then
            img.is_favorite = not (img.is_favorite == true)
            return img.is_favorite
        end
    end
    return false
end

-- Rename image title
function ImageManager:renameImage(book_data, image_id, new_title)
    if not book_data or not book_data.images or not image_id or not new_title then return false end
    for _, img in ipairs(book_data.images) do
        if matchesImageKey(img, image_id) then
            img.title = new_title
            img.custom_title = true
            return true
        end
    end
    return false
end

-- Set rotation angle for an image
function ImageManager:setImageRotation(book_data, image_id, rotation)
    if not book_data or not book_data.images or not image_id then return false end
    for _, img in ipairs(book_data.images) do
        if matchesImageKey(img, image_id) then
            img.rotation = rotation
            return true
        end
    end
    return false
end

-- Set zoom level and pan position for an image
function ImageManager:setImageZoom(book_data, image_id, zoom_level, pan_x, pan_y)
    if not book_data or not book_data.images or not image_id then return false end
    for _, img in ipairs(book_data.images) do
        if matchesImageKey(img, image_id) then
            img.zoom_level = zoom_level
            img.pan_x = pan_x
            img.pan_y = pan_y
            return true
        end
    end
    return false
end

-- Toggle hidden status for an image
function ImageManager:toggleHideImage(book_data, image_id)
    if not book_data or not book_data.images or not image_id then return false end
    for _, img in ipairs(book_data.images) do
        if matchesImageKey(img, image_id) then
            img.is_hidden = not (img.is_hidden == true)
            return img.is_hidden
        end
    end
    return false
end

-- Scan document images from EPUB OPF / spine
function ImageManager:scanDocumentImages(ui, on_progress_cb)
    if not ui or not ui.document then return {} end
    local book_path = ui.document.file
    if not book_path then return {} end
    
    logger.info("ImageManager: Starting image scan for: " .. tostring(book_path))
    local images = {}
    local total_pages = ui.document:getPageCount() or 1
    
    -- Format check
    local is_epub = book_path:lower():match("%.epub$") ~= nil
    local is_cbz = book_path:lower():match("%.cbz$") ~= nil
    
    if is_epub then
        images = self:scanEpubImages(book_path, total_pages)
    elseif is_cbz then
        images = self:scanCbzImages(book_path, total_pages)
    else
        -- Fallback: Check document cover and pages
        local cover = {
            id = "img_cover",
            title = "Cover Image",
            page = 1,
            category = "illustration",
            href = "cover.jpg"
        }
        table.insert(images, cover)
    end
    
    logger.info(string.format("ImageManager: Scan complete, found %d images", #images))
    return images
end

-- Scan images in an EPUB file by reading OPF manifest and spine
function ImageManager:scanEpubImages(book_path, total_pages)
    local images = {}
    local escaped_book = book_path:gsub("'", "'\\''")
    
    -- 1. List files inside EPUB using unzip -l
    local list_cmd = string.format("unzip -l '%s'", escaped_book)
    local p = io.popen(list_cmd)
    if not p then return images end
    
    local manifest_images = {}
    local image_idx = 1
    
    for line in p:lines() do
        -- Line format in unzip -l: Length Date Time Name
        local size_str, fname = line:match("^%s*(%d+)%s+[%d%-%s:]+%s+(.+)%s*$")
        if size_str and fname then
            local lower_f = fname:lower()
            if lower_f:match("%.jpe?g$") or lower_f:match("%.png$") or lower_f:match("%.webp$") or lower_f:match("%.svg$") then
                local size = tonumber(size_str) or 0
                local title = self:generateTitleFromFilename(fname)
                local cat = self:classifyImage(title, fname)
                
                table.insert(manifest_images, {
                    id = self:generateImageId(fname, image_idx),
                    href = fname,
                    file_size = size,
                    title = title,
                    category = cat,
                    page = math.max(1, math.min(total_pages, math.floor(image_idx * (total_pages / 20)))),
                })
                image_idx = image_idx + 1
            end
        end
    end
    p:close()
    
    -- 2. Refine page estimates from list
    if #manifest_images > 0 then
        for i, img in ipairs(manifest_images) do
            img.page = math.max(1, math.min(total_pages, math.floor((i / #manifest_images) * total_pages)))
            table.insert(images, img)
        end
    end
    
    return images
end

-- Scan comic CBZ archive images
function ImageManager:scanCbzImages(book_path, total_pages)
    local images = {}
    local escaped_book = book_path:gsub("'", "'\\''")
    local list_cmd = string.format("unzip -l '%s'", escaped_book)
    local p = io.popen(list_cmd)
    if not p then return images end
    
    local page_idx = 1
    for line in p:lines() do
        local size_str, fname = line:match("^%s*(%d+)%s+[%d%-%s:]+%s+(.+)%s*$")
        if size_str and fname then
            local lower_f = fname:lower()
            if lower_f:match("%.jpe?g$") or lower_f:match("%.png$") or lower_f:match("%.webp$") then
                local title = string.format("Page %d", page_idx)
                table.insert(images, {
                    id = "cbz_" .. tostring(page_idx),
                    href = fname,
                    file_size = tonumber(size_str) or 0,
                    title = title,
                    category = (page_idx == 1 and "illustration" or "general"),
                    page = page_idx,
                })
                page_idx = page_idx + 1
            end
        end
    end
    p:close()
    return images
end

-- Convert raw filename into clean human-readable title
function ImageManager:generateTitleFromFilename(fname)
    if not fname then return "Image" end
    local base = fname:match("([^/]+)%.[%w]+$") or fname
    -- Replace underscores and hyphens with spaces
    local clean = base:gsub("[_%-]+", " ")
    -- Capitalize words
    clean = clean:gsub("(%a)([%w_']*)", function(first, rest)
        return first:upper() .. rest:lower()
    end)
    return clean
end

return ImageManager
