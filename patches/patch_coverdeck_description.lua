-- patches/patch_coverdeck_description.lua — SimpleUI Extra Modules
-- Adds a "Description" strip to SimpleUI's built-in CoverDeck module.
--
-- When enabled, a brief excerpt of the active (centre) book's description is
-- rendered above or below the cover carousel.  Tapping it opens the full text
-- in a scrollable viewer, mirroring the behaviour of module_hero_currently.
--
-- CONTRACT (required by main.lua's patch discovery):
--   P.id              string  — unique identifier used in log messages
--   P.apply           func()  — called once after SimpleUI has initialised; idempotent
--   P.name            string  — display name for menu
--   P.description     string  — help text for menu
--   P.default_enabled bool    — first-run default (false = opt-in for patches)
--
-- HOW IT WORKS
--   module_coverdeck's build() returns a carousel widget.  This patch wraps
--   the three public functions accessible via the module table:
--
--     M.getHeight(ctx)     — adds the estimated strip height (STRIP_LINES
--                            text lines + PAD2 gap) when the feature is
--                            enabled, so the homescreen reserves the right
--                            amount of vertical space before the first build.
--
--     M.build(w, ctx)      — calls orig_build() to get the carousel, then
--                            reads the description of ctx.fps[coverdeck_cur_idx]
--                            (the centre book).  If a description exists it
--                            builds a tappable text strip and assembles a
--                            VerticalGroup with [carousel, gap, strip] or
--                            [strip, gap, carousel] depending on position.
--                            _cover_slots is forwarded so updateCovers() keeps
--                            working after the widget is wrapped.
--
--     M.getMenuItems(ctx)  — appends a "Description" sub-menu with Enable,
--                            Position, Text Alignment, and Max Length items.
--
-- COMPOSITION WITH patch_coverdeck_exclude
--   Both patches wrap M.build().  Alphabetical load order means this patch
--   wraps first ("d" < "e"), then patch_coverdeck_exclude wraps the
--   description-wrapped version.  At runtime the call chain is:
--
--     exclude-wrapper → description-wrapper → original M.build
--
--   The exclude wrapper filters ctx.recent_fps before calling inward and
--   restores them afterwards.  Our wrapper therefore sees the already-filtered
--   fps list, which is correct (description always reflects the visible deck).
--   No merging of the two patches is required.
--
-- SETTING KEYS  (all prefixed with ctx.pfx at runtime)
--   coverdeck_desc_enabled    bool    — master toggle (default off)
--   coverdeck_desc_position   string  — "above" | "below" (default "below")
--   coverdeck_desc_align      string  — "left"|"center"|"right"|"justify" (default "center")
--   coverdeck_desc_limit_mode string  — "max_length" | "fixed_lines" (default "max_length")
--   coverdeck_desc_max_len    number  — max characters in strip (default 500, only used when limit_mode = "max_length")
--   coverdeck_desc_line_count number  — fixed line count (1-5, default 3, only used when limit_mode = "fixed_lines")
--   coverdeck_desc_font_size  number  — base font size in pt (default 8; multiplied by module scale)

local logger = require("logger")

-- ---------------------------------------------------------------------------
-- PATCH_ID must match the filename: patch_<PATCH_ID>.lua
-- This ID is used for:
--   1. P.id (patch identifier for simpleui_ext toggle system)
--   2. Settings key in SimpleUI's sui_settings.lua
local PATCH_ID = "coverdeck_description"

local P = {}
P.id              = PATCH_ID
P.name            = "Cover Deck Description"
P.description     = "Show the active book's description below (or above) the Cover Deck carousel"
P.default_enabled = false  -- Opt-in: patches default to disabled

local SK_ENABLED    = "coverdeck_desc_enabled"
local SK_POSITION   = "coverdeck_desc_position"
local SK_ALIGN      = "coverdeck_desc_align"
local SK_LIMIT_MODE = "coverdeck_desc_limit_mode"
local SK_MAX_LEN    = "coverdeck_desc_max_len"
local SK_LINE_COUNT = "coverdeck_desc_line_count"
local SK_FONT_SIZE  = "coverdeck_desc_font_size"

local MAX_RECENT_FPS = 10   -- must match module_coverdeck's constant
local STRIP_LINES    = 3    -- default visual line cap for the description strip (when limit_mode = "max_length")

local _applied = false

-- Cache for truncated descriptions to avoid expensive re-calculation
-- Key: filepath .. "|" .. width .. "|" .. font_size .. "|" .. max_lines
-- Value: truncated text
-- Max 20 entries to prevent memory bloat
local _truncate_cache = {}
local _cache_count = 0
local _cache_max_size = 20

-- Cache invalidation: clear when settings change
local function _clearCache()
    _truncate_cache = {}
    _cache_count = 0
end

-- ---------------------------------------------------------------------------
-- Settings helpers
-- ---------------------------------------------------------------------------

local function _getS()
    local ok, S = pcall(require, "sui_store")
    return ok and S
end

local function _isEnabled(pfx, S)
    return S ~= nil and S:isTrue(pfx .. SK_ENABLED)
end

local function _getPosition(pfx, S)
    return (S and S:readSetting(pfx .. SK_POSITION)) or "below"
end

local function _getAlign(pfx, S)
    return (S and S:readSetting(pfx .. SK_ALIGN)) or "center"
end

local function _getLimitMode(pfx, S)
    return (S and S:readSetting(pfx .. SK_LIMIT_MODE)) or "max_length"
end

local function _getMaxLen(pfx, S)
    local v = S and tonumber(S:readSetting(pfx .. SK_MAX_LEN))
    return (v and v > 0) and v or 500
end

local function _getLineCount(pfx, S)
    local v = S and tonumber(S:readSetting(pfx .. SK_LINE_COUNT))
    return (v and v >= 1 and v <= 5) and v or 3
end

local function _getFontSize(pfx, S)
    local v = S and tonumber(S:readSetting(pfx .. SK_FONT_SIZE))
    return (v and v >= 6 and v <= 20) and v or 8
end

-- ---------------------------------------------------------------------------
-- HTML stripping (same logic as module_hero_currently)
-- ---------------------------------------------------------------------------

local function _stripHTML(s)
    if not s or s == "" then return nil end
    s = s:gsub("<br%s*/?>",  " ")
    s = s:gsub("<p[^>]*>",   " "); s = s:gsub("</p>",   " ")
    s = s:gsub("<div[^>]*>", " "); s = s:gsub("</div>", " ")
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("&amp;",  "&"); s = s:gsub("&lt;",   "<")
    s = s:gsub("&gt;",   ">"); s = s:gsub("&quot;", '"')
    s = s:gsub("&apos;", "'"); s = s:gsub("&nbsp;", " ")
    s = s:gsub("&#(%d+);", function(n)
        local cp = tonumber(n)
        return (cp and cp >= 32 and cp < 128) and string.char(cp) or " "
    end)
    s = s:gsub("%s+", " "):match("^%s*(.-)%s*$")
    return (s and s ~= "") and s or nil
end

-- ---------------------------------------------------------------------------
-- Unicode-safe character truncation
-- ---------------------------------------------------------------------------

local function _truncate(s, max_chars)
    if not s or #s == 0 then return s end
    local count = 0
    local i = 1
    local last_safe = 0
    while i <= #s do
        local byte = s:byte(i)
        local char_len
        if     byte >= 240 then char_len = 4
        elseif byte >= 224 then char_len = 3
        elseif byte >= 192 then char_len = 2
        else                    char_len = 1
        end
        count = count + 1
        if count == max_chars then
            last_safe = i + char_len - 1
        end
        if count > max_chars then
            return s:sub(1, last_safe) .. "\xE2\x80\xA6"  -- "…"
        end
        i = i + char_len
    end
    return s
end

-- ---------------------------------------------------------------------------
-- Truncate text to fit within a specific number of rendered lines
-- Uses cache to avoid expensive re-calculation
-- ---------------------------------------------------------------------------

local function _truncateToLines(text, width, face, max_lines, cache_key)
    if not text or text == "" or max_lines <= 0 then return "" end
    
    -- Check cache first (huge performance win for repeated calls)
    if cache_key and _truncate_cache[cache_key] then
        return _truncate_cache[cache_key]
    end
    
    local RenderText = require("ui/rendertext")
    local words = {}
    for word in text:gmatch("%S+") do
        words[#words + 1] = word
    end
    
    -- Apply safety margin to prevent overflow on different devices (Android vs Kobo)
    -- Font rendering can vary slightly, so we use 95% of available width
    local safe_width = math.floor(width * 0.95)
    
    local lines = {}
    local current_line = ""
    local word_idx = 1
    
    while word_idx <= #words do
        -- Stop immediately if we already have max_lines
        if #lines >= max_lines then
            return table.concat(lines, " ") .. "\xE2\x80\xA6"
        end
        
        local word = words[word_idx]
        local test_line = current_line == "" and word or (current_line .. " " .. word)
        local w = RenderText:sizeUtf8Text(0, safe_width, face, test_line, true).x
        
        if w <= safe_width then
            -- Word fits, add to current line
            current_line = test_line
            word_idx = word_idx + 1
        else
            -- Word doesn't fit, save current line and start new one
            if current_line ~= "" then
                -- Save the full line
                lines[#lines + 1] = current_line
                current_line = ""
                -- Don't increment word_idx - retry this word on next line
            else
                -- Single word too long for line, add it anyway
                lines[#lines + 1] = word
                word_idx = word_idx + 1
                current_line = ""
            end
        end
    end
    
    -- Add remaining text if we haven't reached max_lines
    if current_line ~= "" and #lines < max_lines then
        lines[#lines + 1] = current_line
    end
    
    local result = table.concat(lines, " ")
    
    -- Store in cache (with simple LRU: clear all if max size exceeded)
    if cache_key then
        if not _truncate_cache[cache_key] then
            if _cache_count >= _cache_max_size then
                _truncate_cache = {}  -- Simple eviction: clear all
                _cache_count = 0
            end
            _cache_count = _cache_count + 1
        end
        _truncate_cache[cache_key] = result
    end
    
    return result
end

-- ---------------------------------------------------------------------------
-- Book description reader — tries custom_metadata → BookInfoManager → sidecar
-- Returns plain text (HTML stripped) or nil.
-- ---------------------------------------------------------------------------

local function _getDescription(fp)
    if not fp then return nil end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or lfs.attributes(fp, "mode") ~= "file" then return nil end

    local raw

    -- 1) DocSettings custom_metadata.lua — highest priority (user overrides)
    local ok_ds, DS = pcall(require, "docsettings")
    if ok_ds and DS then
        local ok3, custom_file = pcall(DS.findCustomMetadataFile, DS, fp)
        if ok3 and custom_file then
            local ok4, cs = pcall(DS.openSettingsFile, custom_file)
            if ok4 and cs then
                local cp = cs:readSetting("custom_props") or {}
                raw = cp.description or cp.comments
            end
        end
    end

    -- 2) BookInfoManager (CoverBrowser scanner — richest source for EPUB)
    if not raw then
        local ok_cfg, Config = pcall(require, "sui_config")
        local BIM = ok_cfg and Config and Config.getBookInfoManager()
        if BIM then
            local ok_i, info = pcall(BIM.getBookInfo, BIM, fp, false)
            if ok_i and info then
                raw = (type(info.description) == "string" and info.description ~= "" and info.description)
                   or (type(info.comments)    == "string" and info.comments    ~= "" and info.comments)
            end
        end
    end

    -- 3) DocSettings sidecar doc_props — fallback
    if not raw and ok_ds and DS then
        local ok2, ds = pcall(DS.open, DS, fp)
        if ok2 and ds then
            local rp = ds:readSetting("doc_props") or {}
            raw = rp.description or rp.comments
            pcall(function() ds:close() end)
        end
    end

    return raw and _stripHTML(raw)
end

-- ---------------------------------------------------------------------------
-- Reconstruct the fps list the same way module_coverdeck does.
-- Called AFTER orig_build() so ctx.coverdeck_cur_idx is already normalised.
-- When patch_coverdeck_exclude is also active it will have pre-filtered
-- ctx.recent_fps (we are inside its wrapper), so the book we pick is always
-- the one actually visible at the centre of the carousel.
-- ---------------------------------------------------------------------------

local function _buildFps(ctx)
    local ok_s, S = pcall(require, "sui_store")
    local pfx    = ctx.pfx or ""
    local source

    -- Read source the same way module_coverdeck does
    local c = ctx.cfg and ctx.cfg.coverdeck
    source = c and c.source
    if not source then
        source = (ok_s and S and S:readSetting(pfx .. "flow_recent_source")) or "recent"
    end

    -- TBR source
    if source == "tbr" then
        local ok_tbr, tbr = pcall(require, "desktop_modules/module_tbr")
        if ok_tbr and tbr then
            local tbr_fps = tbr.getTBRList()
            if tbr_fps and #tbr_fps > 0 then return tbr_fps end
        end
        -- TBR empty → fall through to recent
    end

    -- Recent source (mirrors buildRecentFps in module_coverdeck)
    local fps  = {}
    if ctx.current_fp then
        fps[1] = ctx.current_fp
    end
    if ctx.recent_fps then
        local seen = {}
        if ctx.current_fp then seen[ctx.current_fp] = true end
        for _, fp in ipairs(ctx.recent_fps) do
            if not seen[fp] then
                fps[#fps + 1] = fp
                seen[fp] = true
                if #fps >= MAX_RECENT_FPS then break end
            end
        end
    end
    return fps
end

-- ---------------------------------------------------------------------------
-- _buildDescStrip(w, pfx, full_desc, bd_title, bd_author, S, scale, lbl_scale, fp)
--
-- Builds the tappable description widget.  Returns:
--   dtap         InputContainer  — the tappable strip
--   strip_h      number          — the actual rendered height (pixels)
-- ---------------------------------------------------------------------------

local function _buildDescStrip(w, pfx, full_desc, bd_title, bd_author, S, scale, lbl_scale, fp)
    scale     = scale     or 1.0
    lbl_scale = lbl_scale or 1.0

    local Device         = require("device")
    local Screen         = Device.screen
    local Font           = require("ui/font")
    local Geom           = require("ui/geometry")
    local GestureRange   = require("ui/gesturerange")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local Blitbuffer     = require("ffi/blitbuffer")

    local ok_ui, UI = pcall(require, "sui_core")
    local PAD = ok_ui and UI and UI.PAD or Screen:scaleBySize(8)

    local ok_ss, SUIStyle = pcall(require, "sui_style")
    -- Same fg color as the coverdeck title (CLR_TEXT_EFF in module_coverdeck)
    local CLR_TEXT = (ok_ss and SUIStyle and SUIStyle.getThemeColor("fg"))
                  or Blitbuffer.COLOR_BLACK

    -- Font size: user base (pt) scaled by the same module + label scale that
    -- module_coverdeck applies to its own title / stats text.
    local base_fs = _getFontSize(pfx, S)
    local desc_fs = math.max(7, math.floor(Screen:scaleBySize(base_fs) * scale * lbl_scale))
    local face    = Font:getFace("smallinfofont", desc_fs)

    local align       = _getAlign(pfx, S)
    local limit_mode  = _getLimitMode(pfx, S)
    local desc_w      = w - PAD * 2   -- same horizontal inset as the carousel's inner content

    -- Determine max_lines and strip_text based on limit mode
    local max_lines, strip_text
    if limit_mode == "fixed_lines" then
        max_lines  = _getLineCount(pfx, S)
        -- Pre-truncate text to exact line count to prevent overflow
        -- Use cache key: filepath|width|fontsize|maxlines for performance
        local cache_key = fp and (fp .. "|" .. desc_w .. "|" .. desc_fs .. "|" .. max_lines)
        strip_text = _truncateToLines(full_desc, desc_w, face, max_lines, cache_key)
    else  -- "max_length" (default)
        max_lines  = STRIP_LINES
        local max_len = _getMaxLen(pfx, S)
        strip_text = _truncate(full_desc, max_len)
    end

    -- Use makeAlphaTextBox so the text composites over whatever is already on
    -- the framebuffer — identical to the technique used by module_hero_currently.
    -- TextBoxWidget:new fills its own internal blitbuffer with white before
    -- drawing text; makeAlphaTextBox bypasses that fill entirely.
    local desc_opts = {
        text        = strip_text,
        face        = face,
        width       = desc_w,
        alignment   = align,
        fgcolor     = CLR_TEXT,
        max_lines   = max_lines,
        line_height = 0.3,
    }
    local desc_widget
    if ok_ui and UI and UI.makeAlphaTextBox then
        desc_widget = UI.makeAlphaTextBox(desc_opts)
    else
        -- Fallback: regular TextBoxWidget (opaque white bg, acceptable when
        -- the homescreen background is also white)
        local TextBoxWidget = require("ui/widget/textboxwidget")
        desc_widget = TextBoxWidget:new(desc_opts)
    end

    -- Calculate height: fixed for fixed_lines mode, actual for max_length mode
    local actual_h
    if limit_mode == "fixed_lines" then
        -- Use fixed height based on line count to keep layout stable
        -- Text is already pre-truncated by _truncateToLines
        local line_h = math.ceil((face.size or desc_fs) * 1.4)
        actual_h = line_h * max_lines
    else
        -- Use actual rendered height for max_length mode
        actual_h = desc_widget:getSize().h
    end

    -- Tappable wrapper: opens full description in a scrollable viewer
    local DescTap = InputContainer:extend{}
    local _full   = full_desc
    local _title  = bd_title or ""
    local _author = bd_author

    function DescTap:onTap()
        local TextViewer = require("ui/widget/textviewer")
        local UIManager  = require("ui/uimanager")
        local viewer_title = _title
        if _author and _author ~= "" then
            viewer_title = viewer_title .. " \xE2\x80\x94 " .. _author
        end
        UIManager:show(TextViewer:new{
            title = viewer_title,
            text  = _full,
        })
        return true
    end

    local dtap = DescTap:new{
        dimen = Geom:new{ w = desc_w, h = actual_h },
        desc_widget,
    }
    dtap.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = dtap.dimen } },
    }

    return dtap, actual_h
end

-- ---------------------------------------------------------------------------
-- apply()
-- ---------------------------------------------------------------------------

function P.apply()
    if _applied then return end

    local ok, M = pcall(require, "desktop_modules/module_coverdeck")
    if not ok or not M then
        logger.warn("coverdeck_description patch: cannot load module_coverdeck — skipped")
        return
    end
    _applied = true

    -- ── wrap getHeight() ──────────────────────────────────────────────────
    -- Must be wrapped before build() so the homescreen reserves the correct
    -- total height.  Uses a fixed estimate based on limit mode settings.

    local orig_getHeight = M.getHeight
    M.getHeight = function(ctx)
        local h   = orig_getHeight(ctx)
        local pfx = ctx and ctx.pfx or ""
        local S   = _getS()
        if not _isEnabled(pfx, S) then return h end

        local Device = require("device")
        local Screen = Device.screen
        local Font   = require("ui/font")
        local ok_ui, UI = pcall(require, "sui_core")
        local PAD2 = ok_ui and UI and UI.PAD2 or Screen:scaleBySize(4)

        local ok_cfg2, Config2 = pcall(require, "sui_config")
        local scale2     = (ok_cfg2 and Config2 and Config2.getModuleScale("coverdeck",     pfx)) or 1.0
        local lbl_scale2 = (ok_cfg2 and Config2 and Config2.getItemLabelScale("coverdeck", pfx)) or 1.0
        local base_fs2   = _getFontSize(pfx, S)
        local face   = Font:getFace("smallinfofont", math.max(7, math.floor(Screen:scaleBySize(base_fs2) * scale2 * lbl_scale2)))
        local line_h = math.ceil(face.size * 1.4)

        -- Determine line count based on limit mode
        local limit_mode = _getLimitMode(pfx, S)
        local line_count
        if limit_mode == "fixed_lines" then
            line_count = _getLineCount(pfx, S)
        else  -- "max_length"
            line_count = STRIP_LINES
        end

        return h + PAD2 + line_h * line_count
    end

    -- ── wrap build() ──────────────────────────────────────────────────────

    local orig_build = M.build
    M.build = function(w, ctx)
        local S   = _getS()
        local pfx = ctx.pfx or ""

        -- Pass-through when feature is disabled
        if not _isEnabled(pfx, S) then
            return orig_build(w, ctx)
        end

        -- Run the original (or exclude-patched) carousel build.
        -- This sets ctx.coverdeck_cur_idx to the current centre index.
        local carousel = orig_build(w, ctx)
        if not carousel then return nil end

        -- Determine which file is at the centre of the just-built carousel.
        local fps    = _buildFps(ctx)
        local curIdx = ctx.coverdeck_cur_idx or 1
        if curIdx > #fps then curIdx = 1 end
        local fp     = fps[curIdx]

        local full_desc = fp and _getDescription(fp)
        local limit_mode = _getLimitMode(pfx, S)
        
        -- In fixed_lines mode, always add placeholder even without description to keep layout stable
        -- In max_length mode, skip if no description (old behavior)
        if not full_desc and limit_mode ~= "fixed_lines" then
            return carousel
        end

        -- Fetch book title/author for the fullscreen viewer header
        local bd_title, bd_author
        local ok_sh, SH = pcall(require, "desktop_modules/module_books_shared")
        if ok_sh and SH then
            local pre = ctx.prefetched and ctx.prefetched[fp]
            local bd  = SH.getBookData(fp, pre)
            bd_title  = bd and bd.title
            bd_author = bd and bd.authors
        end

        -- Read the same scale values module_coverdeck uses for its own text.
        -- ctx.cfg.coverdeck is the pre-read settings bundle (fast path on HS);
        -- fall back to direct Config reads when the bundle is absent.
        local ok_cfg, Config = pcall(require, "sui_config")
        local c_bundle  = ctx.cfg and ctx.cfg.coverdeck
        local scale     = (ok_cfg and Config and ((c_bundle and c_bundle.scale)     or Config.getModuleScale("coverdeck",     pfx))) or 1.0
        local lbl_scale = (ok_cfg and Config and ((c_bundle and c_bundle.lbl_scale) or Config.getItemLabelScale("coverdeck", pfx))) or 1.0

        -- Build the description strip (or empty placeholder in fixed_lines mode)
        local dtap, _strip_h
        if full_desc then
            dtap, _strip_h = _buildDescStrip(w, pfx, full_desc, bd_title, bd_author, S, scale, lbl_scale, fp)
        else
            -- Create empty placeholder with fixed height in fixed_lines mode
            local Device = require("device")
            local Screen = Device.screen
            local Font   = require("ui/font")
            local Geom   = require("ui/geometry")
            local VerticalSpan = require("ui/widget/verticalspan")
            
            local base_fs = _getFontSize(pfx, S)
            local desc_fs = math.max(7, math.floor(Screen:scaleBySize(base_fs) * scale * lbl_scale))
            local face    = Font:getFace("smallinfofont", desc_fs)
            local line_h  = math.ceil((face.size or desc_fs) * 1.4)
            local line_count = _getLineCount(pfx, S)
            _strip_h = line_h * line_count
            
            dtap = VerticalSpan:new{ width = _strip_h }
        end

        -- Inject description into carousel's internal structure.
        -- Carousel is a FrameContainer containing a VerticalGroup.
        -- We need to add description to that VerticalGroup.
        local Device  = require("device")
        local Screen  = Device.screen
        local ok_ui2, UI2 = pcall(require, "sui_core")
        local PAD2 = ok_ui2 and UI2 and UI2.PAD2 or Screen:scaleBySize(4)
        local VerticalSpan = require("ui/widget/verticalspan")

        -- carousel is a FrameContainer, carousel[1] is the VerticalGroup
        local vg = carousel[1]
        if vg then
            local position = _getPosition(pfx, S)
            if position == "above" then
                -- Insert at the beginning
                table.insert(vg, 1, dtap)
                table.insert(vg, 2, VerticalSpan:new{ width = PAD2 })
            else  -- "below" (default)
                -- Append at the end
                vg[#vg + 1] = VerticalSpan:new{ width = PAD2 }
                vg[#vg + 1] = dtap
            end
        end

        return carousel
    end

    -- ── wrap getMenuItems() ───────────────────────────────────────────────
    -- Appends a "Description" sub-menu to the existing CoverDeck settings.

    local orig_getMenuItems = M.getMenuItems
    M.getMenuItems = function(ctx_menu)
        local items   = orig_getMenuItems(ctx_menu) or {}
        local pfx     = ctx_menu.pfx or ""
        local refresh = ctx_menu.refresh
        local _lc     = ctx_menu._ or function(x) return x end
        local S       = _getS()

        local desc_menu = {
            text = _lc("Description"),
            sub_item_table = {
                -- Enable / Disable
                {
                    text           = _lc("Enable Description"),
                    checked_func   = function() return _isEnabled(pfx, S) end,
                    keep_menu_open = true,
                    callback       = function()
                        if S then
                            S:saveSetting(pfx .. SK_ENABLED, not _isEnabled(pfx, S))
                        end
                        refresh()
                    end,
                },

                -- Position (default: "below")
                {
                    text = _lc("Position"),
                    sub_item_table = {
                        {
                            text         = _lc("Below"),
                            radio        = true,
                            checked_func = function() return _getPosition(pfx, S) == "below" end,
                            callback     = function()
                                if S then S:saveSetting(pfx .. SK_POSITION, "below") end
                                refresh()
                            end,
                        },
                        {
                            text         = _lc("Above"),
                            radio        = true,
                            checked_func = function() return _getPosition(pfx, S) == "above" end,
                            callback     = function()
                                if S then S:saveSetting(pfx .. SK_POSITION, "above") end
                                refresh()
                            end,
                        },
                    },
                },

                -- Text Alignment (default: "center")
                {
                    text = _lc("Text Alignment"),
                    sub_item_table = {
                        {
                            text         = _lc("Left"),
                            radio        = true,
                            checked_func = function() return _getAlign(pfx, S) == "left" end,
                            callback     = function()
                                if S then S:saveSetting(pfx .. SK_ALIGN, "left") end
                                refresh()
                            end,
                        },
                        {
                            text         = _lc("Center"),
                            radio        = true,
                            checked_func = function() return _getAlign(pfx, S) == "center" end,
                            callback     = function()
                                if S then S:saveSetting(pfx .. SK_ALIGN, "center") end
                                refresh()
                            end,
                        },
                        {
                            text         = _lc("Right"),
                            radio        = true,
                            checked_func = function() return _getAlign(pfx, S) == "right" end,
                            callback     = function()
                                if S then S:saveSetting(pfx .. SK_ALIGN, "right") end
                                refresh()
                            end,
                        },
                        {
                            text         = _lc("Justify"),
                            radio        = true,
                            checked_func = function() return _getAlign(pfx, S) == "justify" end,
                            callback     = function()
                                if S then S:saveSetting(pfx .. SK_ALIGN, "justify") end
                                refresh()
                            end,
                        },
                    },
                },

                -- Text Size (base pt, multiplied by module scale at render time)
                {
                    text = _lc("Text Size"),
                    sub_item_table = (function()
                        local sizes = { 7, 8, 9, 10, 11, 12 }
                        local t = {}
                        for _, sz in ipairs(sizes) do
                            t[#t + 1] = {
                                text         = string.format("%d pt", sz),
                                radio        = true,
                                checked_func = function() return _getFontSize(pfx, S) == sz end,
                                callback     = function()
                                    if S then S:saveSetting(pfx .. SK_FONT_SIZE, sz) end
                                    _clearCache()  -- Font size affects rendering
                                    refresh()
                                end,
                            }
                        end
                        return t
                    end)(),
                },

                -- Limit Mode (max_length or fixed_lines)
                {
                    text = _lc("Limit Mode"),
                    sub_item_table = {
                        {
                            text         = _lc("Max Length"),
                            radio        = true,
                            checked_func = function() return _getLimitMode(pfx, S) == "max_length" end,
                            callback     = function()
                                if S then S:saveSetting(pfx .. SK_LIMIT_MODE, "max_length") end
                                _clearCache()  -- Mode change invalidates cache
                                refresh()
                            end,
                        },
                        {
                            text         = _lc("Fixed Line Count"),
                            radio        = true,
                            checked_func = function() return _getLimitMode(pfx, S) == "fixed_lines" end,
                            callback     = function()
                                if S then S:saveSetting(pfx .. SK_LIMIT_MODE, "fixed_lines") end
                                _clearCache()  -- Mode change invalidates cache
                                refresh()
                            end,
                        },
                    },
                },

                -- Max Length (number input, only shown when limit_mode = "max_length")
                {
                    text_func = function()
                        local v = S and tonumber(S:readSetting(pfx .. SK_MAX_LEN)) or 500
                        return string.format("%s: %d", _lc("Max Length"), v)
                    end,
                    enabled_func = function() return _getLimitMode(pfx, S) == "max_length" end,
                    keep_menu_open = true,
                    callback = function()
                        local InputDialog = require("ui/widget/inputdialog")
                        local UIManager   = require("ui/uimanager")
                        local current = tostring(
                            S and tonumber(S:readSetting(pfx .. SK_MAX_LEN)) or 500)
                        local dlg
                        dlg = InputDialog:new{
                            title       = _lc("Max Description Length"),
                            input       = current,
                            input_type  = "number",
                            description = _lc("Maximum number of characters shown in the strip.\nDefault: 500"),
                            buttons = {{
                                {
                                    text     = _lc("Cancel"),
                                    callback = function() UIManager:close(dlg) end,
                                },
                                {
                                    text             = _lc("Save"),
                                    is_enter_default = true,
                                    callback = function()
                                        local val = tonumber(dlg:getInputText())
                                        if val and val > 0 then
                                            if S then
                                                S:saveSetting(pfx .. SK_MAX_LEN, val)
                                            end
                                            _clearCache()  -- Max length affects truncation
                                        end
                                        UIManager:close(dlg)
                                        refresh()
                                    end,
                                },
                            }},
                        }
                        UIManager:show(dlg)
                        dlg:onShowKeyboard()
                    end,
                },

                -- Line Count (radio buttons 1-5, only shown when limit_mode = "fixed_lines")
                {
                    text = _lc("Line Count"),
                    enabled_func = function() return _getLimitMode(pfx, S) == "fixed_lines" end,
                    sub_item_table = (function()
                        local counts = { 1, 2, 3, 4, 5 }
                        local t = {}
                        for _, cnt in ipairs(counts) do
                            t[#t + 1] = {
                                text         = tostring(cnt),
                                radio        = true,
                                checked_func = function() return _getLineCount(pfx, S) == cnt end,
                                callback     = function()
                                    if S then S:saveSetting(pfx .. SK_LINE_COUNT, cnt) end
                                    _clearCache()  -- Line count affects rendering
                                    refresh()
                                end,
                            }
                        end
                        return t
                    end)(),
                },
            },
        }

        items[#items + 1] = desc_menu
        return items
    end
end

return P
