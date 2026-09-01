# UI Style Guide & Non-Touch Device Standards

This document defines the user interface design system, theme tokens, and non-touch interaction contracts for the KOReader X-Ray plugin.

---

## 1. Design System & Theme Tokens

All UI components must reference the centralized theme tokens defined in `xray_theme.lua`:

- **`border_focus`**: `math.max(2, sc(3))` (Bold 3px thickness for unmistakable visibility on LCD and e-ink displays)
- **`color_focus_border`**: `Blitbuffer.COLOR_BLACK` (Solid black for high visual contrast)
- **`color_focus_bg`**: `Blitbuffer.Color8(215)` (Prominent light grey fill for focused rows/cards/buttons)
- **`color_focus_indicator`**: `Blitbuffer.COLOR_BLACK`
- **`radius_focus`**: `sc(4)`
- **`border_btn`**: `sc(1)`
- **`border_window`**: `sc(1)`
- **`radius_window`**: `0` (or `sc(4)` for cards)
- **`radius_btn`**: `sc(4)`

### E-Ink Visual Contrast Guidelines
- All interactive focus indicators must have high visual contrast against light backgrounds (minimum 3px solid border `color_focus_border` and `color_focus_bg` tint).
- Card thumbnails must display a high-contrast top-left focus badge (e.g. `[ ↵ OPEN ]` with white text on black background).
- Avoid subtle gray shades (< 15% difference) for active states as they do not render reliably on 16-level grayscale e-ink screens.

---

## 2. Non-Touch Interaction Contract

Non-touch devices (e.g. Kindle 4 Non-Touch, Kindle Keyboard, Sony PRS, button-driven e-readers, and PC desktop KOReader instances) interact solely via hardware keys. Every dialog, card, overlay, and custom widget MUST implement the following contracts:

### 4-Zone Image Gallery Navigation (`xray_image_gallery.lua`)
The gallery features 4 dedicated focus zones connected smoothly via D-pad navigation:
1. **Header Zone**: View Mode Button (`1`), Filter Button (`2`), Close Button (`3`).
2. **Tabs Zone**: `All` (`1`), `Favorites` (`2`), `Series` (`3`), `Hidden` (`4`).
3. **Cards Zone**: 1-to-N page items with double-frame focus border + `[ ↵ OPEN ]` badge.
4. **Footer Zone**: `‹ Prev` (`1`) and `Next ›` (`2`) pagination buttons.

- **Transitions**:
  - `Up` from top row cards → `Tabs Zone` → `Header Zone` → `Footer Zone`.
  - `Down` from `Header Zone` → `Tabs Zone` → `Cards Zone` → `Footer Zone`.
  - `Left` / `Right` navigates items within current zone with wrap-around.
  - `Return` / `KP_Enter` / `Enter` / `Select` / `Space` triggers the focused item action immediately (opens image, switches tab, toggles filter, cycles view mode, or pages).
  - Explicit `ImageGallery:handleEvent(ev)` ensures immediate key capture on desktop and embedded devices.

### 2-Zone Image Viewer Navigation (`xray_image_viewer.lua`)
1. **Toolbar Zone**: 7 focusable buttons (Rotate, Zoom In, Zoom Out, Invert, Actions, Minimize, Close).
2. **Image Zone**:
   - When zoomed in (> fit zoom): `Left` / `Right` / `Up` / `Down` smoothly pans the viewport.
   - When at fit zoom: `Left` / `Right` navigates to previous/next image across the book/gallery.
   - `Return` / `Enter` / `Select` / `Space` toggles zoom levels.
   - Direct shortcuts: `+`/`-` zoom, `r` rotate, `i` invert, `a` actions, `PageUp`/`PageDown` next/prev image, `Escape`/`q` close.
   - Explicit `ImageViewer:handleEvent(ev)` ensures immediate key capture on desktop and embedded devices.

### 2D Multi-Row Option Cards (e.g. Unit Style Preview / `showUnitStyleCard`)
- `Up` / `Down` moves between setting categories/rows.
- `Left` / `Right` moves between values/pills in the active category with 3px focus frames and `color_focus_bg` tint.
- `Return` / `KP_Enter` / `Enter` / `Select` / `Space` immediately commits the setting and updates the live preview.
- `Device.input.group.Enter`, `Device.input.group.Select`, `Device.input.group.Back` are fully mapped.

---

## 3. Keyboard & Mnemonic Shortcuts Standard

Standard keyboard shortcuts across major features:

### Image Gallery (`xray_image_gallery.lua`)
- `1`–`9`: Direct number selection to immediately open image #1–9 on current page.
- `t` / `Tab`: Cycle through tabs (`All` → `Favorites` → `Series References` → `Hidden`).
- `v`: Cycle through view modes (`Mosaic` → `Grid` → `List`).
- `f`: Toggle filter mode (`Maps & Diagrams Only` ↔ `All Images`).
- `a` / `A` / `Menu` / `.`: Open Image Actions menu for the currently focused image.
- `PageDown` / `NextPage` / `n` / `]`: Go to next gallery page.
- `PageUp` / `PrevPage` / `p` / `[`: Go to previous gallery page.
- `Select` / `Return` / `Enter` / `Space`: Open focused image in Fullscreen Viewer.
- `Back` / `Escape` / `q`: Close gallery.

### Image Viewer (`xray_image_viewer.lua`)
- `+` / `=` / `KP_Add` / `k`: Zoom In.
- `-` / `_` / `KP_Subtract` / `j`: Zoom Out.
- `Left` / `Right` / `Up` / `Down`: Pan viewport (when zoomed in) or navigate images (when fit to screen).
- `r` / `R`: Rotate 90° clockwise.
- `i` / `I` / `n` / `N`: Toggle Invert / Night Mode.
- `m` / `M`: Minimize viewer to book.
- `a` / `A` / `Menu` / `.`: Open Image Actions menu.
- `PageUp` / `PrevPage` / `p` / `[`: Previous image.
- `PageDown` / `NextPage` / `]`: Next image.
- `Return` / `KP_Enter` / `Enter` / `Select` / `Space`: Toggle zoom.
- `Back` / `Escape` / `q`: Close viewer.

### Log Viewer (`XRayLogViewer`)
- `Left` / `Up` / `PageUp` / `PrevPage` / `p`: Previous page.
- `Right` / `Down` / `PageDown` / `NextPage` / `Space` / `n`: Next page.
- `r` / `R` / `F5`: Reload logs from disk.
- `Back` / `Escape` / `q`: Close log viewer.

### Tooltips & Footnotes
- Floating tooltips (`UnitTooltip`) must register instant dismissal on `Back`, `Escape`, or `Select` in addition to auto-dismiss timers.

