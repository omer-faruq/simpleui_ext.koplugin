local logger = require("logger")

local patch = {
    id = "module_copies",
    name = "Module Copies",
    description = "Adds 'Number of Copies' setting to all SimpleUI modules, allowing the same module to be placed on multiple pages.",
    default_enabled = false  -- Opt-in: patches default to disabled
}

function patch.apply()
    local _ = require("gettext")
    local ok_reg, Registry = pcall(require, "desktop_modules/moduleregistry")
    if not ok_reg or not Registry then
        logger.warn("simpleui_ext: patch_module_copies: moduleregistry not available")
        return
    end

    local ok_sui, SUISettings = pcall(require, "sui_store")
    if not ok_sui or not SUISettings then
        logger.warn("simpleui_ext: patch_module_copies: sui_store not available")
        return
    end

    logger.info("simpleui_ext: patch_module_copies: applying module copies patch")

    local original_get = Registry.get
    local wrapped_cache = {}

    Registry.get = function(id)
        if wrapped_cache[id] then
            return wrapped_cache[id]
        end

        local copy_index = id:match("#(%d+)$")
        if not copy_index then
            return original_get(id)
        end

        local base_id = id:match("^(.+)#%d+$")
        local mod = original_get(base_id)

        if mod then
            local wrapped_mod = {}
            for k, v in pairs(mod) do
                wrapped_mod[k] = v
            end
            -- Use the copy ID (e.g. "clock#2") so buildModulePicker's
            -- active_set lookup matches the raw ID stored in layout pages.
            wrapped_mod.id           = id
            wrapped_mod._original_id = mod.id
            wrapped_mod._original_name = mod.name
            wrapped_mod._copy_index  = copy_index
            wrapped_mod.name         = mod.name .. " (Copy " .. copy_index .. ")"

            -- LayoutService.save() iterates Registry.list() and calls
            -- setEnabled(pfx, false) for every module not in the layout.
            -- For copies, this would accidentally disable the base module's
            -- settings. Clear setEnabled and enabled_key so LayoutService
            -- skips the copy entirely. Preserve isEnabled so the copy still
            -- mirrors the base module's enabled state.
            if type(wrapped_mod.isEnabled) ~= "function" and wrapped_mod.enabled_key then
                local ek         = mod.enabled_key
                local default_on = mod.default_on
                wrapped_mod.isEnabled = function(pfx)
                    local v = SUISettings:readSetting(pfx .. ek)
                    if v == nil then return default_on ~= false end
                    return v == true
                end
            end
            wrapped_mod.setEnabled  = nil
            wrapped_mod.enabled_key = nil

            wrapped_cache[id]        = wrapped_mod
            return wrapped_mod
        end

        return mod
    end

    local UIManager = require("ui/uimanager")
    local SpinWidget = require("ui/widget/spinwidget")

    -- Returns true when order_id is a copy of base_id (e.g. "clock#2").
    -- Uses plain string comparison to avoid Lua pattern-character issues.
    local function _isCopyOf(order_id, base_id)
        local prefix = base_id .. "#"
        return #order_id > #prefix and order_id:sub(1, #prefix) == prefix
    end
    local function _copyNum(order_id, base_id)
        local prefix = base_id .. "#"
        return tonumber(order_id:sub(#prefix + 1))
    end

    local original_list = Registry.list
    Registry.list = function()
        local mods = original_list()

        local _ = require("gettext")

        for _mi, mod in ipairs(mods or {}) do
            if not mod._module_copies_enhanced then
                local original_getMenuItems = mod.getMenuItems

                local function enhanceModuleMenuItems(ctx_menu)
                    local original_items = original_getMenuItems and original_getMenuItems(ctx_menu) or {}

                    local enhanced_items = {}
                    for _, item in ipairs(original_items) do
                        enhanced_items[#enhanced_items + 1] = item
                    end

                    enhanced_items[#enhanced_items + 1] = {
                        text = _("Number of Copies"),
                        keep_menu_open = true,
                        callback = function()
                            local pfx = ctx_menu and ctx_menu.pfx or "simpleui_"
                            local current_copies = SUISettings:readSetting(pfx .. "module_" .. mod.id .. "_copies") or 1

                            UIManager:show(SpinWidget:new{
                                title_text   = _("Number of Copies"),
                                info_text    = _("Set how many copies of this module to show.\nEach copy can be placed on different pages."),
                                value        = current_copies,
                                value_min    = 1,
                                value_max    = 10,
                                value_step   = 1,
                                ok_text      = _("OK"),
                                cancel_text  = _("Cancel"),
                                default_value = 1,
                                callback = function(spin)
                                    local new_copies = spin.value
                                    SUISettings:saveSetting(pfx .. "module_" .. mod.id .. "_copies", new_copies)

                                    -- Build a "needed" set for copies 2..new_copies.
                                    local needed = {}
                                    for i = 2, new_copies do needed[i] = true end

                                    local layout = SUISettings:readSetting("simpleui_layout")
                                    if layout and type(layout.pages) == "table" then
                                        -- ── New simpleui_layout path ────────────────────────
                                        local new_pages    = {}
                                        local found_original = false

                                        for _, page in ipairs(layout.pages) do
                                            local new_modules = {}
                                            for _, order_id in ipairs(page.modules or {}) do
                                                if order_id == mod.id then
                                                    found_original = true
                                                    new_modules[#new_modules + 1] = order_id
                                                elseif _isCopyOf(order_id, mod.id) then
                                                    local cn = _copyNum(order_id, mod.id)
                                                    if cn and cn <= new_copies then
                                                        new_modules[#new_modules + 1] = order_id
                                                        needed[cn] = nil
                                                    end
                                                    -- else: remove — exceeds new_copies
                                                else
                                                    new_modules[#new_modules + 1] = order_id
                                                end
                                            end
                                            -- Shallow-copy the page table, replacing modules.
                                            local new_page = {}
                                            for k, v in pairs(page) do new_page[k] = v end
                                            new_page.modules = new_modules
                                            new_pages[#new_pages + 1] = new_page
                                        end

                                        -- Append any still-needed copies to the last page.
                                        if #new_pages > 0 then
                                            local lp = new_pages[#new_pages]
                                            for i = 2, new_copies do
                                                if needed[i] then
                                                    lp.modules[#lp.modules + 1] = mod.id .. "#" .. i
                                                end
                                            end
                                        end

                                        -- If the original module was absent, add it + copies.
                                        if not found_original and #new_pages > 0 then
                                            local lp = new_pages[#new_pages]
                                            lp.modules[#lp.modules + 1] = mod.id
                                            for i = 2, new_copies do
                                                lp.modules[#lp.modules + 1] = mod.id .. "#" .. i
                                            end
                                        end

                                        local new_layout = {}
                                        for k, v in pairs(layout) do new_layout[k] = v end
                                        new_layout.pages = new_pages
                                        SUISettings:saveSetting("simpleui_layout", new_layout)
                                    else
                                        -- ── Legacy module_order path ────────────────────────
                                        local PAGE_BREAK  = require("sui_homescreen").PAGE_BREAK_ID
                                        local saved_order = SUISettings:readSetting(pfx .. "module_order") or {}
                                        local new_order   = {}
                                        local found_original = false

                                        for _, order_id in ipairs(saved_order) do
                                            if order_id == PAGE_BREAK then
                                                new_order[#new_order + 1] = order_id
                                            elseif order_id == mod.id then
                                                found_original = true
                                                new_order[#new_order + 1] = order_id
                                            elseif _isCopyOf(order_id, mod.id) then
                                                local cn = _copyNum(order_id, mod.id)
                                                if cn and cn <= new_copies then
                                                    new_order[#new_order + 1] = order_id
                                                    needed[cn] = nil
                                                end
                                            else
                                                new_order[#new_order + 1] = order_id
                                            end
                                        end

                                        for i = 2, new_copies do
                                            if needed[i] then
                                                new_order[#new_order + 1] = mod.id .. "#" .. i
                                            end
                                        end

                                        if not found_original then
                                            new_order[#new_order + 1] = mod.id
                                            for i = 2, new_copies do
                                                new_order[#new_order + 1] = mod.id .. "#" .. i
                                            end
                                        end

                                        SUISettings:saveSetting(pfx .. "module_order", new_order)
                                    end

                                    -- Invalidate the copy wrapper cache for this module.
                                    local copy_prefix = mod.id .. "#"
                                    for k in pairs(wrapped_cache) do
                                        if k:sub(1, #copy_prefix) == copy_prefix then
                                            wrapped_cache[k] = nil
                                        end
                                    end

                                    local ok_hs, HS_module = pcall(require, "sui_homescreen")
                                    if ok_hs and HS_module and HS_module._instance then
                                        HS_module._instance._enabled_mods_cache = nil
                                    end

                                    if ctx_menu and ctx_menu.refresh then
                                        ctx_menu.refresh()
                                    end
                                end,
                            })
                        end,
                    }

                    return enhanced_items
                end

                mod.getMenuItems = enhanceModuleMenuItems

                -- Wrap the base module's setEnabled so that deactivating it
                -- when copies are still in the layout keeps settings enabled.
                -- Without this, LayoutService.save() calls setEnabled(pfx,false)
                -- for the base module when it is not on a page, which clears
                -- SETTING_ON and prevents any active copies from rendering.
                local _base_id = mod.id
                if type(mod.setEnabled) == "function" then
                    local _orig_se = mod.setEnabled
                    mod.setEnabled = function(pfx, on)
                        if not on then
                            local layout = SUISettings:readSetting("simpleui_layout")
                            if layout and type(layout.pages) == "table" then
                                for _, pg in ipairs(layout.pages) do
                                    for _, pid in ipairs(pg.modules or {}) do
                                        if _isCopyOf(pid, _base_id) then
                                            _orig_se(pfx, true)
                                            return
                                        end
                                    end
                                end
                            end
                        end
                        _orig_se(pfx, on)
                    end
                elseif mod.enabled_key then
                    local _ek = mod.enabled_key
                    mod.setEnabled = function(pfx, on)
                        if not on then
                            local layout = SUISettings:readSetting("simpleui_layout")
                            if layout and type(layout.pages) == "table" then
                                for _, pg in ipairs(layout.pages) do
                                    for _, pid in ipairs(pg.modules or {}) do
                                        if _isCopyOf(pid, _base_id) then
                                            SUISettings:saveSetting(pfx .. _ek, true)
                                            return
                                        end
                                    end
                                end
                            end
                        end
                        SUISettings:saveSetting(pfx .. _ek, on)
                    end
                end

                mod._module_copies_enhanced = true
            end
        end

        -- Append copy modules so buildModulePicker can offer them.
        -- For each base module that has N copies configured, add entries for
        -- copies 2..N.  The picker's active_set is keyed on raw layout IDs
        -- (e.g. "clock#2"), so giving copies their own id lets the filter work.
        local result = {}
        for _, m in ipairs(mods or {}) do
            result[#result + 1] = m
        end
        local hs_pfx = "simpleui_hs_"
        for _, m in ipairs(mods or {}) do
            if not m.id:find("#", 1, true) then
                local copies = SUISettings:readSetting(
                    hs_pfx .. "module_" .. m.id .. "_copies") or 1
                for ci = 2, copies do
                    local copy_mod = Registry.get(m.id .. "#" .. ci)
                    if copy_mod then
                        result[#result + 1] = copy_mod
                    end
                end
            end
        end
        return result
    end

    logger.info("simpleui_ext: patch_module_copies: patch applied successfully")
end

return patch
