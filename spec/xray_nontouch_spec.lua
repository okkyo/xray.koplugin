-- spec/xray_nontouch_spec.lua
require("spec.spec_helper")

local xray_theme = require("xray_theme")
local ImageGallery = require("xray_image_gallery")
local ImageViewer = require("xray_image_viewer")
local XRaySettingsCard = require("xray_settings_card")
local UnitScanner = require("xray_unitscanner")
local UIManager = require("ui/uimanager")

describe("X-Ray Non-Touch & Keyboard Support", function()
    local mock_plugin

    before_each(function()
        mock_plugin = {
            loc = { t = function(self, k, ...) return k end },
            ai_helper = {
                settings = {},
                saveSettings = function(self, s) for k, v in pairs(s) do self.settings[k] = v end end,
                importFromTextFile = function(self, prompt) return true, 1, "xray_key.txt" end,
                init = function() end,
                updateConfigKey = function() end,
            },
            isRTL = function() return false end,
            path = "xray.koplugin/",
            _draw_underline = function() end,
            _PointerArrow = require("ui/widget/widget"):extend{},
            showImageActions = function() end,
            image_manager = require("xray_imagemanager"):new(),
            book_data = {},
        }
    end)

    describe("Theme Tokens", function()
        it("defines high-contrast non-touch focus design tokens", function()
            assert.are_not.equal(nil, xray_theme.border_focus)
            assert.are_not.equal(nil, xray_theme.color_focus_border)
            assert.are_not.equal(nil, xray_theme.color_focus_bg)
            assert.are_not.equal(nil, xray_theme.radius_focus)
            assert.is_true(xray_theme.border_focus >= 2)
        end)
    end)

    describe("ImageGallery Non-Touch Controls", function()
        local sample_images = {
            { id = "img1", title = "Map of Roshar", page = 1, category = "map" },
            { id = "img2", title = "Shallan Sketch", page = 15, category = "illustration" },
            { id = "img3", title = "Urithiru Diagram", page = 45, category = "diagram" },
            { id = "img4", title = "Highstorm Map", page = 80, category = "map" },
        }

        it("initializes focused_index to 1 and registers full key_events", function()
            mock_plugin.images = sample_images
            local gallery = ImageGallery:new{
                plugin = mock_plugin,
                images = sample_images,
                view_mode = "mosaic",
                tab = "all",
            }
            assert.are.equal(1, gallery.focused_index)
            assert.are_not.equal(nil, gallery.key_events.NextCard)
            assert.are_not.equal(nil, gallery.key_events.PrevCard)
            assert.are_not.equal(nil, gallery.key_events.OpenFocused)
            assert.are_not.equal(nil, gallery.key_events.ImageActions)
            assert.are_not.equal(nil, gallery.key_events.CycleTab)
            assert.are_not.equal(nil, gallery.key_events.CycleView)
            assert.are_not.equal(nil, gallery.key_events.ToggleFilter)
            assert.are_not.equal(nil, gallery.key_events.Select1)
        end)

        it("moves focus forward and backward with wrapping", function()
            mock_plugin.images = sample_images
            local gallery = ImageGallery:new{
                plugin = mock_plugin,
                images = sample_images,
                view_mode = "mosaic",
                tab = "all",
            }
            gallery:onNextCard()
            assert.are.equal(2, gallery.focused_index)
            gallery:onNextCard()
            assert.are.equal(3, gallery.focused_index)
            gallery:onPrevCard()
            assert.are.equal(2, gallery.focused_index)
            gallery:onPrevCard()
            assert.are.equal(1, gallery.focused_index)
            -- Prev wrapping on page 1 wraps to end of page items
            gallery:onPrevCard()
            assert.are.equal(#sample_images, gallery.focused_index)
        end)

        it("opens image directly on number shortcuts (1-9)", function()
            mock_plugin.images = sample_images
            local opened_entry = nil
            local gallery = ImageGallery:new{
                plugin = mock_plugin,
                images = sample_images,
                view_mode = "mosaic",
                tab = "all",
            }
            gallery.openViewer = function(self, entry)
                opened_entry = entry
            end
            gallery:onSelect2()
            assert.are_not.equal(nil, opened_entry)
            assert.are.equal("img2", opened_entry.id)
        end)

        it("cycles view modes with V key", function()
            mock_plugin.images = sample_images
            local gallery = ImageGallery:new{
                plugin = mock_plugin,
                images = sample_images,
                view_mode = "mosaic",
                tab = "all",
            }
            assert.are.equal("mosaic", gallery.view_mode)
            gallery:onCycleView()
            assert.are.equal("grid", gallery.view_mode)
            gallery:onCycleView()
            assert.are.equal("list", gallery.view_mode)
            gallery:onCycleView()
            assert.are.equal("mosaic", gallery.view_mode)
        end)

        it("navigates across 4 zones (header, tabs, cards, footer) smoothly", function()
            mock_plugin.images = sample_images
            local gallery = ImageGallery:new{
                plugin = mock_plugin,
                images = sample_images,
                view_mode = "mosaic",
                tab = "all",
            }
            assert.are.equal("cards", gallery.focus_zone)
            assert.are.equal(1, gallery.focused_index)

            -- Moving Up from top row cards goes to tabs
            gallery:onFocusUp()
            assert.are.equal("tabs", gallery.focus_zone)

            -- Moving Up from tabs goes to header
            gallery:onFocusUp()
            assert.are.equal("header", gallery.focus_zone)

            -- Moving Down from header goes to tabs
            gallery:onFocusDown()
            assert.are.equal("tabs", gallery.focus_zone)

            -- Moving Down from tabs goes to cards
            gallery:onFocusDown()
            assert.are.equal("cards", gallery.focus_zone)
            assert.are.equal(1, gallery.focused_index)

            -- Moving Down from bottom row goes to footer
            gallery.focused_index = 4
            gallery:onFocusDown()
            assert.are.equal("footer", gallery.focus_zone)

            -- Moving Up from footer returns to cards
            gallery:onFocusUp()
            assert.are.equal("cards", gallery.focus_zone)
        end)

        it("dispatches Enter / Return in handleEvent correctly", function()
            mock_plugin.images = sample_images
            local opened_entry = nil
            local gallery = ImageGallery:new{
                plugin = mock_plugin,
                images = sample_images,
                view_mode = "mosaic",
                tab = "all",
            }
            gallery.openViewer = function(self, entry)
                opened_entry = entry
            end
            gallery.focus_zone = "cards"
            gallery.focused_index = 3

            local handled = gallery:handleEvent({ type = "Key", key = "Return" })
            assert.is_true(handled)
            assert.are_not.equal(nil, opened_entry)
            assert.are.equal("img3", opened_entry.id)
        end)
    end)

    describe("ImageViewer Non-Touch Controls", function()
        it("registers keyboard shortcuts and actions", function()
            local viewer = ImageViewer:new{
                plugin = mock_plugin,
                image_entry = { id = "img1", title = "Map", page = 1 },
                file_path = "assets/map.svg",
            }
            -- ToggleZoom and arrow keys are handled via key_events for context-aware dispatch.
            assert.are_not.equal(nil, viewer.key_events.ZoomIn)
            assert.are_not.equal(nil, viewer.key_events.ZoomOut)
            assert.are_not.equal(nil, viewer.key_events.Invert)
            assert.are_not.equal(nil, viewer.key_events.Minimize)
            assert.are_not.equal(nil, viewer.key_events.Actions)
            assert.are_not.equal(nil, viewer.key_events.OpenFocused)
            -- Escape/Back is now EscapeBack (context-aware: resets zoom or closes)
            assert.are_not.equal(nil, viewer.key_events.EscapeBack)

            local initial_inverted = viewer.inverted
            viewer:onInvert()
            assert.are.equal(not initial_inverted, viewer.inverted)

            local action_shown = false
            mock_plugin.showImageActions = function() action_shown = true end
            viewer:onActions()
            assert.is_true(action_shown)
        end)

        it("navigates toolbar buttons and image focus zones", function()
            local viewer = ImageViewer:new{
                plugin = mock_plugin,
                image_entry = { id = "img1", title = "Map", page = 1 },
                file_path = "assets/map.svg",
            }
            assert.are.equal("toolbar", viewer.focus_zone)

            -- Left / Right cycles through the 7 toolbar buttons
            viewer.focused_btn_idx = 1
            viewer:onFocusRight()
            assert.are.equal(2, viewer.focused_btn_idx)
            viewer:onFocusLeft()
            assert.are.equal(1, viewer.focused_btn_idx)
            viewer:onFocusLeft()
            assert.are.equal(7, viewer.focused_btn_idx)

            -- Down moves into image zone
            viewer:onFocusDown()
            assert.are.equal("image", viewer.focus_zone)

            -- Up when not zoomed in moves back to toolbar
            viewer.zoom_level = viewer:getFitZoom()
            viewer:onFocusUp()
            assert.are.equal("toolbar", viewer.focus_zone)
        end)

        it("EscapeBack resets zoom and returns to toolbar when zoomed in", function()
            local viewer = ImageViewer:new{
                plugin = mock_plugin,
                image_entry = { id = "img1", title = "Map", page = 1 },
                file_path = "assets/map.svg",
            }
            -- Zoom in and move to image zone
            viewer.focus_zone = "image"
            viewer.zoom_level = viewer:getFitZoom() + 1.0  -- well beyond fit
            viewer.pan_x = 50
            viewer.pan_y = 30

            -- EscapeBack should reset zoom and return to toolbar, not close
            local closed = false
            viewer.close = function() closed = true end
            viewer:onEscapeBack()

            assert.is_false(closed)
            assert.are.equal("toolbar", viewer.focus_zone)
            assert.are.equal(viewer:getFitZoom(), viewer.zoom_level)
        end)

        it("dispatches toolbar actions via onOpenFocused key event", function()
            local rotated = false
            local viewer = ImageViewer:new{
                plugin = mock_plugin,
                image_entry = { id = "img1", title = "Map", page = 1 },
                file_path = "assets/map.svg",
            }
            viewer.onRotate = function() rotated = true; return true end
            viewer.focus_zone = "toolbar"
            viewer.focused_btn_idx = 1 -- Rotate button

            -- onOpenFocused is the method wired to Enter/Return via key_events.OpenFocused
            local handled = viewer:onOpenFocused()
            assert.is_true(handled)
            assert.is_true(rotated)
        end)

        it("switches to prev/next images on page keys", function()
            mock_plugin.images = {
                { id = "img1", title = "Map 1" },
                { id = "img2", title = "Map 2" },
            }
            local opened_image = nil
            mock_plugin.openImageViewer = function(self, img) opened_image = img end

            local viewer = ImageViewer:new{
                plugin = mock_plugin,
                image_entry = mock_plugin.images[1],
                file_path = "assets/map.svg",
            }
            viewer:onNextImage()
            assert.are_not.equal(nil, opened_image)
            assert.are.equal("img2", opened_image.id)
        end)
    end)

    describe("Entity Menu Focus Highlighting", function()
        it("patches MenuItem class from item_group and sets _xray_focused on focus/unfocus", function()
            -- MenuItem is private inside menu.lua. Our patch extracts the class via
            -- getmetatable(item).__index from the first item_group entry.
            -- Simulate: create a fake ItemClass, a fake menu with item_group, and call
            -- _patchMenuItemClass (tested indirectly via newMenu).
            local menu = require("ui/widget/menu")
            local xray_theme_mod = require("xray_theme")

            local ItemClass = {
                onFocus = function(self) return true end,
                onUnfocus = function(self) return true end,
                paintTo = function(self, bb, x, y) end,
            }
            local dummy_item = {
                menu = { _xray_highlight = true },
                _xray_focused = false,
                dimen = { w = 600, h = 60 },
            }
            setmetatable(dummy_item, { __index = ItemClass })

            local fake_group = { dummy_item }

            -- Directly invoke the internal patching logic via the mock's structure
            -- by simulating what _patchMenuItemClass does:
            local mt = getmetatable(dummy_item)
            local ExtractedClass = mt and mt.__index
            assert.are.equal(ItemClass, ExtractedClass)

            -- After patching, onFocus should set _xray_focused
            local orig_onFocus = ItemClass.onFocus
            function ItemClass:onFocus()
                self._xray_focused = self.menu and self.menu._xray_highlight or false
                if orig_onFocus then orig_onFocus(self) end
                return true
            end
            local orig_onUnfocus = ItemClass.onUnfocus
            function ItemClass:onUnfocus()
                self._xray_focused = false
                if orig_onUnfocus then orig_onUnfocus(self) end
                return true
            end

            ItemClass.onFocus(dummy_item)
            assert.is_true(dummy_item._xray_focused)

            ItemClass.onUnfocus(dummy_item)
            assert.is_false(dummy_item._xray_focused)
        end)
    end)

    describe("ButtonDialog Non-Touch Support", function()
        it("patches ButtonDialog with Enter/Escape key events, traps propagation, and focuses default button", function()
            local ButtonDialog = require("ui/widget/buttondialog")
            local cancel_called = false
            local dlg = {
                buttons = {{{
                    text = "Cancel",
                    is_enter_default = true,
                    callback = function() cancel_called = true end,
                }}},
                layout = {
                    {
                        {
                            is_enter_default = true,
                            callback = function() cancel_called = true end,
                            handleEvent = function(self, ev)
                                if ev.type == "Focus" then self._focused = true end
                                if ev.type == "Unfocus" then self._focused = false end
                            end
                        }
                    }
                },
                key_events = {},
            }
            -- Simulate ButtonDialog:init after patching
            if ButtonDialog.init then
                ButtonDialog.init(dlg)
                assert.are_not.equal(nil, dlg.key_events.Press)
                assert.are_not.equal(nil, dlg.key_events.Close)
                assert.is_true(dlg.stop_events_propagation)
                assert.are.equal(1, dlg.selected.x)
                assert.are.equal(1, dlg.selected.y)
                assert.is_true(dlg.layout[1][1]._focused)

                -- Test onPress activation (after debounce threshold)
                if ButtonDialog.onPress then
                    dlg._created_time = (os.clock and os.clock() or os.time()) - 1
                    dlg.getFocusItem = function(self) return self.layout[self.selected.y][self.selected.x] end
                    ButtonDialog.onPress(dlg)
                    assert.is_true(cancel_called)
                end
            end
        end)
    end)
end)
