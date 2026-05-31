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
    local original_defaultOrder = Registry.defaultOrder
    
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
            wrapped_mod._original_name = mod.name
            wrapped_mod._copy_index = copy_index
            wrapped_mod.name = mod.name .. " (Copy " .. copy_index .. ")"
            wrapped_cache[id] = wrapped_mod
            return wrapped_mod
        end
        
        return mod
    end

    local UIManager = require("ui/uimanager")
    local SpinWidget = require("ui/widget/spinwidget")
    local Blitbuffer = require("ffi/blitbuffer")

    local modules_wrapped = false

    local original_list = Registry.list
    Registry.list = function()
        local mods = original_list()
        
        if not modules_wrapped then
            local _ = require("gettext")
            
            for i, mod in ipairs(mods) do
                local original_getMenuItems = mod.getMenuItems
                
                local function enhanceModuleMenuItems(ctx_menu)
                    local original_items = original_getMenuItems and original_getMenuItems(ctx_menu) or {}
                    
                    local enhanced_items = {}
                    for idx, item in ipairs(original_items) do
                        enhanced_items[#enhanced_items + 1] = item
                    end

                    enhanced_items[#enhanced_items + 1] = {
                        text = _("Number of Copies"),
                        keep_menu_open = true,
                        callback = function()
                            local pfx = ctx_menu and ctx_menu.pfx or "simpleui_"
                            local current_copies = SUISettings:readSetting(pfx .. "module_" .. mod.id .. "_copies") or 1
                            
                            UIManager:show(SpinWidget:new{
                                title_text = _("Number of Copies"),
                                info_text = _("Set how many copies of this module to show.\nEach copy can be placed on different pages."),
                                value = current_copies,
                                value_min = 1,
                                value_max = 10,
                                value_step = 1,
                                ok_text = _("OK"),
                                cancel_text = _("Cancel"),
                                default_value = 1,
                                callback = function(spin)
                                    local new_copies = spin.value
                                    SUISettings:saveSetting(pfx .. "module_" .. mod.id .. "_copies", new_copies)
                                    
                                    local saved_order = SUISettings:readSetting(pfx .. "module_order") or {}
                                    local new_order = {}
                                    local PAGE_BREAK = require("sui_homescreen").PAGE_BREAK_ID
                                    
                                    local existing_copies = {}
                                    local found_original = false
                                    local original_position = nil
                                    
                                    for order_idx, order_id in ipairs(saved_order) do
                                        local base_id = order_id:match("^(.+)#%d+$") or order_id
                                        if base_id == mod.id then
                                            if order_id == mod.id then
                                                found_original = true
                                                original_position = order_idx
                                            else
                                                local copy_num = tonumber(order_id:match("#(%d+)$"))
                                                if copy_num then
                                                    existing_copies[copy_num] = order_idx
                                                end
                                            end
                                        end
                                    end
                                    
                                    local needed_copies = {}
                                    for i = 2, new_copies do
                                        needed_copies[i] = true
                                    end
                                    
                                    for order_idx, order_id in ipairs(saved_order) do
                                        if order_id == PAGE_BREAK then
                                            new_order[#new_order + 1] = order_id
                                        else
                                            local base_id = order_id:match("^(.+)#%d+$") or order_id
                                            
                                            if base_id == mod.id then
                                                if order_id == mod.id then
                                                    new_order[#new_order + 1] = mod.id
                                                else
                                                    local copy_num = tonumber(order_id:match("#(%d+)$"))
                                                    if copy_num and copy_num <= new_copies then
                                                        new_order[#new_order + 1] = order_id
                                                        needed_copies[copy_num] = nil
                                                    end
                                                end
                                            else
                                                new_order[#new_order + 1] = order_id
                                            end
                                        end
                                    end
                                    
                                    for i = 2, new_copies do
                                        if needed_copies[i] then
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
                                    
                                    for k in pairs(wrapped_cache) do
                                        if k:match("^" .. mod.id .. "#") then
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
            end
            
            modules_wrapped = true
        end
        
        return mods
    end

    logger.info("simpleui_ext: patch_module_copies: patch applied successfully")
end

return patch
