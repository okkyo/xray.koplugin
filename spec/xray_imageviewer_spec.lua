-- spec/xray_imageviewer_spec.lua
require("spec.spec_helper")
local ImageViewer = require("xray_image_viewer")

describe("xray_imageviewer", function()
    local mock_plugin

    before_each(function()
        mock_plugin = {
            loc = { t = function(self, k) return k end },
            showImageActions = function() end,
        }
    end)

    it("initializes and builds UI without crashing", function()
        local viewer = ImageViewer:new{
            plugin = mock_plugin,
            image_entry = { id = "img1", title = "The Hobbit Map", page = 12 },
            file_path = "assets/map.svg",
        }
        assert.are_not.equal(nil, viewer)
        assert.are_not.equal(nil, viewer[1])
        -- zoom_level is set by getFitZoom() on init; for unreadable assets it returns 1.0
        assert.are.equal(1.0, viewer.zoom_level)
        assert.are.equal(0, viewer.rotation_angle)
    end)

    it("supports paintTo without nil arithmetic crashes", function()
        local viewer = ImageViewer:new{
            plugin = mock_plugin,
            image_entry = { id = "img1", title = "The Hobbit Map", page = 12 },
            file_path = "assets/map.svg",
        }
        local mock_bb = {}
        local ok, err = pcall(function()
            viewer:paintTo(mock_bb, 0, 0)
        end)
        if not ok then print("paintTo err: " .. tostring(err)) end
        assert.is_true(ok)
    end)

    it("clamps pan correctly within image bounds", function()
        local viewer = ImageViewer:new{
            plugin = mock_plugin,
            image_entry = { id = "img1", title = "Map", page = 1 },
            file_path = "assets/map.svg",
        }
        -- Excessive pan is clamped
        viewer.pan_x = 99999
        viewer.pan_y = 99999
        viewer:clampPan()
        assert.is_true(viewer.pan_x < 99999)
        assert.is_true(viewer.pan_y < 99999)
    end)

    it("handles zoom and rotation interactions", function()
        local viewer = ImageViewer:new{
            plugin = mock_plugin,
            image_entry = { id = "img1", title = "Map", page = 1 },
            file_path = "assets/map.svg",
        }
        local fit_zoom = viewer:getFitZoom()
        viewer:onZoomIn()
        assert.is_true(viewer.zoom_level > fit_zoom)
        viewer:onZoomOut()
        -- Should return to fit_zoom (1.0 for unreadable asset files)
        assert.are.equal(fit_zoom, viewer.zoom_level)

        viewer:onRotate()
        assert.are.equal(270, viewer.rotation_angle) -- 270 in KOReader equals 90° Clockwise
        viewer:onRotate()
        assert.are.equal(180, viewer.rotation_angle)
    end)
end)
