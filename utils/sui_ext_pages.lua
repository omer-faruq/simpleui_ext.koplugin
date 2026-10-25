-- utils/sui_ext_pages.lua — KOReader "stable page numbers" (pagemap) support.
--
-- With "Use stable page numbers" on for a book, ReaderPageMap keeps these in
-- the book's sidecar:
--   pagemap_use_page_labels     true
--   pagemap_doc_pages           number of stable pages
--   pagemap_current_page_label  label of the current page (saved on close)
--   pagemap_last_page_label     label of the last page (saved on close)
--
-- Every reader here returns nil for a book without that flag, so callers keep
-- their screen-page path — and output — unchanged for everyone else.

local lfs = require("libs/libkoreader-lfs")

local M = {}

local _cache = {}   -- fp → { mtime, info }  (info == false: no stable pages)

-- Stable page info from an open DocSettings, or nil.
function M.fromDocSettings(ds)
    if not (ds and ds.isTrue and ds:isTrue("pagemap_use_page_labels")) then return nil end
    local total = tonumber(ds:readSetting("pagemap_doc_pages"))
    if not total or total <= 0 then return nil end
    return {
        total        = total,
        cur_label    = ds:readSetting("pagemap_current_page_label"),
        last_label   = ds:readSetting("pagemap_last_page_label"),
        screen_pages = tonumber(ds:readSetting("doc_pages")),
    }
end

-- Stable page info for a book path, or nil. Cached by sidecar mtime: one stat
-- per call, the sidecar is parsed again only after it changed.
function M.read(fp)
    if not fp then return nil end
    local ok, DS = pcall(require, "docsettings")
    if not ok or not DS then return nil end
    local ok_f, sidecar = pcall(DS.findSidecarFile, DS, fp)
    if not ok_f or not sidecar then return nil end
    local mtime = lfs.attributes(sidecar, "modification")
    local hit = _cache[fp]
    if hit and hit.mtime == mtime then return hit.info or nil end
    local info
    local ok2, ds = pcall(DS.open, DS, fp)
    if ok2 and ds then
        info = M.fromDocSettings(ds)
        pcall(function() ds:close() end)
    end
    _cache[fp] = { mtime = mtime, info = info or false }
    return info
end

-- Current page as the reader shows it.
-- Returns cur_n, total_n, plus cur_label, last_label when the reader saved
-- them (they can be non-numeric, e.g. "xii": display only, never arithmetic).
function M.position(info, pct)
    local total = info.total
    local cur   = math.max(1, math.min(total, math.floor((pct or 0) * total)))
    local cl, ll = info.cur_label, info.last_label
    if cl ~= nil and ll ~= nil then
        return cur, total, tostring(cl), tostring(ll)
    end
    return cur, total
end

-- Factor turning screen-page counts (stats DB) into stable pages.
function M.ratio(info, screen_pages)
    local sp = tonumber(screen_pages) or info.screen_pages
    if not sp or sp <= 0 then return 1 end
    return info.total / sp
end

return M
