-- utils/sui_ext_text.lua — per-element Font / Style / Size through SimpleUI's
-- own text styles (Config.getTextStyle, Config.makeTextSection, SimpleUI 3.0+).
--
-- The user's choice is stored under SimpleUI's keys and edited with SimpleUI's
-- menu, so the ext modules behave like the native ones. On older SimpleUI the
-- API is missing: styles() returns nil, menu() returns nil, and every face
-- falls back to the module's built-in one.
--
-- An element the user has not touched keeps its built-in face exactly; a
-- Size-only change keeps that face at the scaled size. Only a picked font or
-- style switches to SUIStyle.getTextFace.

local M = {}

local _variants = {}   -- mod_id → { elem → default variant }
local _declared = {}   -- mod_id → true once SimpleUI knows its defaults

local function config()
    local ok, C = pcall(require, "sui_config")
    if ok and type(C) == "table" and C.getTextStyle and C.makeTextSection then return C end
    return nil
end

-- Hands the defaults to SimpleUI as soon as it is loaded.
local function ensureDeclared(C, mod_id)
    if _declared[mod_id] or not _variants[mod_id] then return end
    if C.declareTextVariants then C.declareTextVariants(mod_id, _variants[mod_id]) end
    _declared[mod_id] = true
end

-- Declares the elements of `mod_id` that are not regular by default, e.g.
-- { title = "bold" }. Call at module load.
function M.declare(mod_id, variants)
    _variants[mod_id], _declared[mod_id] = variants, nil
    local C = config()
    if C then ensureDeclared(C, mod_id) end
end

-- Styles of `elems` for this render, keyed by element, or nil when unsupported.
-- Read fresh rather than from the engine's ctx.cfg bundle: that bundle may
-- predate our declare() (SimpleUI loaded after us) and carry wrong defaults.
function M.styles(ctx, mod_id, elems)
    local C = config()
    if not C then return nil end
    ensureDeclared(C, mod_id)
    local ok, styles = pcall(C.readTextStyles, mod_id, elems, ctx and ctx.pfx)
    return ok and styles or nil
end

-- Size multiplier of an element (1 when unsupported or untouched).
function M.scale(styles, elem)
    local st = styles and styles[elem]
    return st and st.scale or 1
end

-- Face and embolden flag of `elem` at `size` (already fully scaled).
-- legacy(size) → the module's own face; legacy_bold is its own bold flag.
function M.face(styles, mod_id, elem, size, legacy, legacy_bold)
    local st = styles and styles[elem]
    local default = _variants[mod_id] and _variants[mod_id][elem] or "regular"
    if not st or (not st.family and st.variant == default) then
        return legacy(size), legacy_bold
    end
    local ok, SUIStyle = pcall(require, "features/sui_style")
    if not ok or not SUIStyle or not SUIStyle.getTextFace then
        return legacy(size), legacy_bold
    end
    local ok2, face, bold = pcall(SUIStyle.getTextFace, st, size)
    if not ok2 or not face then return legacy(size), legacy_bold end
    return face, bold or false
end

-- "Text" menu entry (one sub-entry per element), or nil when unsupported.
-- labels: elem → translated title. SimpleUI translates its own rows.
function M.menu(mod_id, elems, labels, pfx, refresh)
    local C = config()
    if not C then return nil end
    ensureDeclared(C, mod_id)
    local ok, item = pcall(C.makeTextSection, {
        mod_id  = mod_id,
        elems   = elems,
        labels  = labels,
        pfx     = pfx,
        refresh = refresh,
    })
    return ok and item or nil
end

return M
