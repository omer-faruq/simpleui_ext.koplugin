-- patches/patch_coverdeck_exclude.lua — SimpleUI Extra Modules
-- Adds "Exclude Paths from Recent" filtering to SimpleUI's built-in CoverDeck
-- module (module_coverdeck), identical to the filter already present on
-- Hero Currently Reading and Recent Book Stats.
--
-- CONTRACT (required by main.lua's patch discovery):
--   P.id     string  — unique identifier used in log messages
--   P.apply  func()  — called once after SimpleUI has initialised; idempotent
--
-- HOW IT WORKS
--   module_coverdeck's buildRecentFps() is a local function and cannot be
--   replaced directly.  Instead we monkey-patch the two public functions that
--   are accessible via the module table returned by require():
--
--     M.build()        — saves ctx.current_fp / ctx.recent_fps, filters them
--                        in-place, calls the original, then restores them so
--                        the homescreen's shared ctx (which holds the mutable
--                        carousel index and other state) is never permanently
--                        modified.  The filter is a no-op when source ~= "recent"
--                        or when no exclude fragments have been configured.
--
--     M.getMenuItems() — appends an "Exclude Paths from Recent" item that opens
--                        an InputDialog, mirroring the UI on the other modules.
--
-- SETTING KEY
--   pfx .. "coverdeck_exclude_paths"   (comma/newline-separated path fragments)

local logger = require("logger")

-- ---------------------------------------------------------------------------
local P = {}
P.id = "coverdeck_exclude_paths"

local SK_EXCLUDE = "coverdeck_exclude_paths"
local _applied   = false

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function _getExcludePaths(pfx)
    local ok, SUISettings = pcall(require, "sui_store")
    if not ok or not SUISettings then return {} end
    local raw = SUISettings:readSetting((pfx or "") .. SK_EXCLUDE)
    if not raw or raw == "" then return {} end
    local result = {}
    for token in raw:gmatch("[^,\n]+") do
        local t = token:match("^%s*(.-)%s*$")
        if t ~= "" then result[#result + 1] = t end
    end
    return result
end

local function _isExcluded(fp, excludes)
    if not fp or #excludes == 0 then return false end
    for _, frag in ipairs(excludes) do
        if fp:find(frag, 1, true) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- apply()
-- ---------------------------------------------------------------------------
function P.apply()
    if _applied then return end

    local ok, M = pcall(require, "desktop_modules/module_coverdeck")
    if not ok or not M then
        logger.warn("coverdeck_exclude patch: cannot load module_coverdeck — skipped")
        return
    end
    _applied = true

    -- ── wrap build() ──────────────────────────────────────────────────────
    -- MAX_DECK matches module_coverdeck's MAX_RECENT_FPS constant (10).
    -- buildRecentFps() fills the carousel from ctx.current_fp (slot 0) and
    -- ctx.recent_fps (slots 1..MAX_DECK), stopping at MAX_DECK total.
    -- Simply filtering ctx.recent_fps would shrink the deck; instead we re-fill
    -- it by walking ReadHistory until we have MAX_DECK non-excluded entries.
    local MAX_DECK   = 10
    local orig_build = M.build
    M.build = function(w, ctx)
        local pfx = ctx.pfx or ""

        -- Resolve source the same way module_coverdeck does:
        -- ctx.cfg bundle (pre-read by _buildCtx) takes priority.
        local c      = ctx.cfg and ctx.cfg.coverdeck
        local source = c and c.source
        if not source then
            local ok2, S = pcall(require, "sui_store")
            source = (ok2 and S and S:readSetting(pfx .. "flow_recent_source")) or "recent"
        end

        if source == "recent" then
            local excludes = _getExcludePaths(pfx)
            if #excludes > 0 then
                -- Save originals — orig_build() writes coverdeck_cur_idx back
                -- into ctx, so we must not replace ctx with a copy.
                local orig_current_fp = ctx.current_fp
                local orig_recent_fps = ctx.recent_fps

                -- Null out current_fp when excluded.
                if orig_current_fp and _isExcluded(orig_current_fp, excludes) then
                    ctx.current_fp = nil
                end

                -- Re-build recent_fps from ReadHistory so excluded slots are
                -- filled with the next non-excluded books — deck count stays at
                -- MAX_DECK instead of shrinking by the number of excluded entries.
                local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
                local ok_rh,  RH  = pcall(require, "readhistory")
                if ok_rh and RH then
                    if not (RH.hist and #RH.hist > 0) then
                        pcall(function() RH:reload() end)
                    end
                    if RH.hist then
                        local filled = {}
                        for _, e in ipairs(RH.hist) do
                            if e and e.file
                                and (not ok_lfs or lfs.attributes(e.file, "mode") == "file")
                                and not _isExcluded(e.file, excludes)
                            then
                                filled[#filled + 1] = e.file
                                if #filled >= MAX_DECK then break end
                            end
                        end
                        ctx.recent_fps = filled
                    end
                else
                    -- ReadHistory unavailable — fall back to simple filter.
                    local filtered = {}
                    for _, fp in ipairs(orig_recent_fps or {}) do
                        if (not ok_lfs or lfs.attributes(fp, "mode") == "file")
                            and not _isExcluded(fp, excludes)
                        then
                            filtered[#filtered + 1] = fp
                        end
                    end
                    ctx.recent_fps = filtered
                end

                local result = orig_build(w, ctx)

                -- Restore so subsequent refreshes see the full unfiltered lists.
                ctx.current_fp = orig_current_fp
                ctx.recent_fps = orig_recent_fps
                return result
            end
        end

        return orig_build(w, ctx)
    end

    -- ── wrap getMenuItems() ───────────────────────────────────────────────
    local orig_getMenuItems = M.getMenuItems
    M.getMenuItems = function(ctx_menu)
        local items   = orig_getMenuItems(ctx_menu) or {}
        local pfx     = ctx_menu.pfx or ""
        local refresh = ctx_menu.refresh
        local _lc     = ctx_menu._ or function(x) return x end
        local ok2, SUISettings = pcall(require, "sui_store")

        items[#items + 1] = {
            text_func = function()
                local raw = ok2 and SUISettings
                            and SUISettings:readSetting(pfx .. SK_EXCLUDE)
                if not raw or raw == "" then
                    return _lc("Exclude Paths from Recent")
                end
                local n = 0
                for _ in raw:gmatch("[^,\n]+") do n = n + 1 end
                return string.format("%s (%d)", _lc("Exclude Paths from Recent"), n)
            end,
            callback = function()
                local InputDialog = require("ui/widget/inputdialog")
                local UIManager   = require("ui/uimanager")
                local raw = (ok2 and SUISettings
                             and SUISettings:readSetting(pfx .. SK_EXCLUDE)) or ""
                local dlg
                dlg = InputDialog:new{
                    title       = _lc("Exclude Paths from Recent"),
                    input       = raw,
                    input_hint  = "/mnt/onboard/rss, instapaper",
                    description = _lc("Comma-separated path fragments.\nBooks whose path contains any fragment will be skipped."),
                    allow_newline    = false,
                    buttons = {{
                        {
                            text     = _lc("Cancel"),
                            callback = function() UIManager:close(dlg) end,
                        },
                        {
                            text             = _lc("Save"),
                            is_enter_default = true,
                            callback = function()
                                local val = dlg:getInputText()
                                if ok2 and SUISettings then
                                    SUISettings:saveSetting(pfx .. SK_EXCLUDE, val)
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
        }

        return items
    end
end

return P
