-- spec/xray_imagemanager_spec.lua
require("spec.spec_helper")
local ImageManager = require("xray_imagemanager")
local SeriesManager = require("xray_seriesmanager")

describe("xray_imagemanager", function()
    local img_mgr
    local series_mgr

    before_each(function()
        img_mgr = ImageManager:new()
        series_mgr = SeriesManager:new()
        os.execute("mkdir -p /tmp/koreader/settings/xray/series")
    end)

    after_each(function()
        os.execute("rm -rf /tmp/koreader")
    end)

    describe("generateImageId", function()
        it("creates consistent safe id from href", function()
            local id = img_mgr:generateImageId("images/map_westlands.png", 1)
            assert.are.equal("images_map_westlands.png_1", id)

            local id2 = img_mgr:generateImageId("OEBPS/Images/Diagram#1.jpg", 14)
            assert.are.equal("OEBPS_Images_Diagram_1.jpg_14", id2)
        end)
    end)

    describe("classifyImage", function()
        it("detects maps correctly", function()
            assert.are.equal("map", img_mgr:classifyImage("Map of the Westlands", "img01.jpg"))
            assert.are.equal("map", img_mgr:classifyImage("World Overview", "images/karte_welt.png"))
            assert.are.equal("map", img_mgr:classifyImage("Plano de la Ciudad", "plano.jpg"))
        end)

        it("detects diagrams and trees correctly", function()
            assert.are.equal("diagram", img_mgr:classifyImage("House Lineage", "tree.png"))
            assert.are.equal("diagram", img_mgr:classifyImage("Ship Layout Diagram", "ship_floorplan.jpg"))
            assert.are.equal("diagram", img_mgr:classifyImage("Battle Chart", "chart.svg"))
        end)

        it("detects general illustrations", function()
            assert.are.equal("illustration", img_mgr:classifyImage("Figure 1", "fig1.jpg"))
            assert.are.equal("illustration", img_mgr:classifyImage("Plate IV", "plate4.jpg"))
        end)
    end)

    describe("isOrnamental and filterImages", function()
        it("filters out decorative ornaments and tiny icons in standard mode", function()
            local ornamental = { title = "Divider Ornament", href = "images/fleuron_sep.png", width = 30, height = 30 }
            assert.is_true(img_mgr:isOrnamental(ornamental, "standard"))

            local map = { title = "Map of Randland", href = "images/map.jpg", width = 1600, height = 1200 }
            assert.is_false(img_mgr:isOrnamental(map, "standard"))
        end)

        it("includes all images when filter_mode is 'all'", function()
            local ornamental = { title = "Divider Ornament", href = "images/fleuron_sep.png", width = 30, height = 30 }
            assert.is_false(img_mgr:isOrnamental(ornamental, "all"))
        end)

        it("filters non-large images when filter_mode is 'large_only'", function()
            local med_img = { title = "Small icon", href = "img.png", width = 200, height = 200 }
            assert.is_true(img_mgr:isOrnamental(med_img, "large_only"))

            local large_map = { title = "Large Map", href = "big_map.png", width = 1200, height = 900 }
            assert.is_false(img_mgr:isOrnamental(large_map, "large_only"))
        end)
    end)

    describe("getFilteredImages and Spoilers", function()
        local test_images

        before_each(function()
            test_images = {
                { id = "img1", title = "Map of Caemlyn", page = 10, is_favorite = false },
                { id = "img2", title = "Battle of Dumai's Wells", page = 500, is_favorite = false },
                { id = "img3", title = "World Map", page = 5, is_favorite = true },
                { id = "img4", title = "Hidden Sketch", page = 20, is_hidden = true },
            }
        end)

        it("orders favorites first, then by page order", function()
            local res = img_mgr:getFilteredImages(test_images, "all", 200, "standard")
            assert.are.equal(3, #res)
            assert.are.equal("img3", res[1].id) -- Favorite first
            assert.are.equal("img1", res[2].id) -- Page 10
            assert.are.equal("img2", res[3].id) -- Page 500
        end)

        it("flags spoilers accurately based on current reading page", function()
            local res = img_mgr:getFilteredImages(test_images, "all", 200, "standard")
            -- img1 (page 10) <= current_page (200) -> not spoiler
            assert.is_false(res[2].is_spoiler)
            -- img2 (page 500) > current_page (200) -> spoiler
            assert.is_true(res[3].is_spoiler)
        end)

        it("filters only favorites in favorites tab", function()
            local res = img_mgr:getFilteredImages(test_images, "favorites", 200, "standard")
            assert.are.equal(1, #res)
            assert.are.equal("img3", res[1].id)
        end)

        it("filters hidden items in hidden tab", function()
            local res = img_mgr:getFilteredImages(test_images, "hidden", 200, "standard")
            assert.are.equal(1, #res)
            assert.are.equal("img4", res[1].id)
        end)
    end)

    describe("toggleFavorite, rename, hide", function()
        local book_data

        before_each(function()
            book_data = {
                images = {
                    { id = "img1", title = "Original Map", page = 15, is_favorite = false, is_hidden = false }
                }
            }
        end)

        it("toggles favorite state", function()
            local fav = img_mgr:toggleFavorite(book_data, "img1")
            assert.is_true(fav)
            assert.is_true(book_data.images[1].is_favorite)

            local unfav = img_mgr:toggleFavorite(book_data, "img1")
            assert.is_false(unfav)
            assert.is_false(book_data.images[1].is_favorite)
        end)

        it("renames image title", function()
            local ok = img_mgr:renameImage(book_data, "img1", "Updated Realm Map")
            assert.is_true(ok)
            assert.are.equal("Updated Realm Map", book_data.images[1].title)
            assert.is_true(book_data.images[1].custom_title)
        end)

        it("sets image rotation", function()
            local ok = img_mgr:setImageRotation(book_data, "img1", 90)
            assert.is_true(ok)
            assert.are.equal(90, book_data.images[1].rotation)
        end)

        it("sets image zoom and pan", function()
            local ok = img_mgr:setImageZoom(book_data, "img1", 2.5, -40, 60)
            assert.is_true(ok)
            assert.are.equal(2.5, book_data.images[1].zoom_level)
            assert.are.equal(-40, book_data.images[1].pan_x)
            assert.are.equal(60, book_data.images[1].pan_y)
        end)

        it("toggles hidden state", function()
            local hidden = img_mgr:toggleHideImage(book_data, "img1")
            assert.is_true(hidden)
            assert.is_true(book_data.images[1].is_hidden)
        end)
    end)

    describe("series images integration", function()
        it("saves and retrieves series images up to current book index", function()
            local slug = "stormlight_test"
            local book1_map = { id = "s_img1", title = "Roshar Map", source_book_index = 1, source_book_title = "Way of Kings" }
            local book3_map = { id = "s_img2", title = "Urithiru Map", source_book_index = 3, source_book_title = "Oathbringer" }

            series_mgr:saveSeriesImage(slug, book1_map)
            series_mgr:saveSeriesImage(slug, book3_map)

            -- When reading Book 2, reader should only see Book 1 maps
            local for_book2 = series_mgr:getSeriesImages(slug, 2)
            assert.are.equal(1, #for_book2)
            assert.are.equal("Roshar Map", for_book2[1].title)

            -- When reading Book 3, reader sees both
            local for_book3 = series_mgr:getSeriesImages(slug, 3)
            assert.are.equal(2, #for_book3)
        end)
    end)
end)
