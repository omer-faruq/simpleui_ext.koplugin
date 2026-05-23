# SimpleUI Extra Modules

Extra homescreen modules and patches for SimpleUI on KOReader.

**Modules** are **auto-discovered**: drop any `module_*.lua` file into the `modules/` folder and it will be picked up automatically on the next KOReader start — no changes to `main.lua` needed.

**Patches** are also **auto-discovered**: drop any `patch_*.lua` file into the `patches/` folder. Each patch file must return a table with two fields:

```lua
return {
    id    = "my_patch_id",       -- string, used in log messages
    apply = function() ... end,  -- called once after all plugins have initialised
}
```

A patch can monkey-patch any public function on any `require()`-able module — not just SimpleUI modules. If a patch fails (e.g. after a SimpleUI update), it is silently skipped and all other modules and patches continue to work normally.

---

## Modules

### Hero Currently Reading

Displays the most recently opened book as a full-width hero card, mirroring the layout used by the  Bookshelf plugin:

```
┌───────────────────────────────────────────────────────┐
│  ┌──────────┐  The Name of the Wind                   │
│  │          │  Patrick Rothfuss                       │
│  │  Cover   │                                         │
│  │  Art     │  A young man grows up hearing legends   │
│  │          │  about himself…                         │
│  │          │                                         │
│  └──────────┘  73 / 272  [████████░░░]  4h 12m left  │
└───────────────────────────────────────────────────────┘
```

**Features:**
- Cover image (30 % of card width, 3:2 aspect ratio — bookshelf proportions)
- Title (bold, up to 2 lines) and author
- Description blurb pulled from BookInfoManager / DocSettings / custom metadata
- Progress bar with page count and estimated time remaining (sourced from the Statistics plugin database)
- Tap to open the book
- Supports SimpleUI's module scaling, theme colours, and frame/background options

**Settings (via Arrange Modules):**

| Setting | Description |
|---|---|
| Scale | Resize the card proportionally |
| Show Frame | Draw a thin border around the card |
| Solid Background | Fill the card background with the theme background colour |
| Exclude Paths from Recent | Comma-separated path fragments; books whose path contains any fragment are skipped (e.g. `/mnt/onboard/rss,instapaper,cache`) |

---

### Recent Book Stats

Displays reading statistics for the most recently opened book in a compact two-panel card, mirroring the layout of the built-in *Reading Stats Popup*:

```
┌─────────────────────┬──────────────────────┐
│ BOOK: The Name of…  │ PACE                 │
│  73%   │  199 pg    │  14d   │   6d        │
│  2h    │  5h to go  │  45m   │  0.8 pg/min │
└─────────────────────┴──────────────────────┘
```

**Features:**
- **BOOK panel** — progress %, pages read, time spent, estimated time remaining
- **PACE panel** — days reading, estimated days to finish, avg time per day, pages per minute
- Book title embedded in the BOOK header (pixel-accurate truncation with ellipsis)
- Tap to open the book
- Wallpaper-aware: all text areas transparent, headers show a solid underline instead of a filled background
- 5-minute cache per book; automatically invalidated when the book is closed so stats are always fresh on return
- Uses the shared Statistics plugin DB connection when available (`M.needs = { db = true }`)

**Settings (via Arrange Modules):**

| Setting | Description |
|---|---|
| Scale | Resize the card proportionally |
| Time Format | Human-readable (e.g. 3.5 hours) or compact XhYm (e.g. 3h30m) |
| Tap to Open Book | Tapping the card opens the most recently read book |
| Exclude Paths from Recent | Comma-separated path fragments; books whose path contains any fragment are skipped |

---

## Built-in Module Patches

In addition to new modules, this plugin applies transparent patches to SimpleUI's built-in modules to add missing functionality.

### Cover Deck — Exclude Paths from Recent

When the Cover Deck source is set to **Recent Books**, this patch adds an **Exclude Paths from Recent** filter (identical to the one on Hero Currently Reading and Recent Book Stats).

**Setting (via Arrange Modules → Cover Deck):**

| Setting | Description |
|---|---|
| Exclude Paths from Recent | Comma-separated path fragments; books whose path contains any fragment are excluded from the Recent Books source (e.g. `/mnt/onboard/rss, instapaper, cache`) |

The filter has no effect when the source is set to **To Be Read**.

---

## Requirements

| Dependency | Notes |
|---|---|
| **KOReader** | Any recent build |
| **SimpleUI plugin** | Required — this plugin extends SimpleUI's homescreen |
| **Statistics plugin** | Optional — enables the time-remaining estimate in Hero Currently Reading |
| **CoverBrowser / Bookshelf** | Optional — richer book descriptions in Hero Currently Reading |

---

## Installation

1. **Download or clone** this repository so you have the `simpleui_ext.koplugin` folder.

2. **Copy the folder** to your KOReader plugins directory:

   | Device | Path |
   |---|---|
   | Kobo | `/.adds/koreader/plugins/` |
   | Kindle | `/extensions/koreader/plugins/` |
   | PocketBook | `/app/plugins/` |
   | Android | `/sdcard/koreader/plugins/` |

   The result should look like:
   ```
   plugins/
   └── simpleui_ext.koplugin/
       ├── _meta.lua
       ├── main.lua
       ├── modules/
       │   ├── module_hero_currently.lua
       │   └── module_recent_book_stats.lua
       └── patches/
           └── patch_coverdeck_exclude.lua
   ```

3. **Restart KOReader** (or use *Top Menu → Settings → Start fresh*).

4. SimpleUI will automatically detect and register all modules on startup.

---

## Usage

### Enabling a module

1. Open KOReader and go to the **SimpleUI homescreen**.
2. Tap the top bar to open the SimpleUI menu.
3. Go to **Arrange Modules** (or the homescreen layout editor).
4. Find the module by name, enable it, and drag it to the desired position.
5. Tap **Save** and return to the homescreen.

---

## Adding more modules

The plugin auto-discovers every file matching `module_*.lua` inside the `modules/` folder. To add a new SimpleUI-compatible module:

1. Drop `module_yourname.lua` into `simpleui_ext.koplugin/modules/`.
2. Restart KOReader — no other changes needed.

The module must follow [SimpleUI's module contract](https://github.com/doctorhetfield-cmd/simpleui.koplugin) (`id`, `name`, `label`, `enabled_key`, `build(w, ctx)`, `getHeight(ctx)`, …).

---

## Adding more patches

The plugin auto-discovers every file matching `patch_*.lua` inside the `patches/` folder. To add a new patch:

1. Drop `patch_yourname.lua` into `simpleui_ext.koplugin/patches/`.
2. Restart KOReader — no other changes needed.

The file must return a table with `id` (string) and `apply` (function). `apply()` is called once after all plugins have initialised, so any `require()`-able module is available. If `apply()` raises an error it is caught and logged; no other module or patch is affected.

---

## Credits

- **[Bookshelf plugin](https://github.com/AndyHazz/bookshelf.koplugin)** — The hero card layout, cover proportions, progress bar style, and time-remaining calculation are all modelled after Bookshelf's hero card implementation.
- **[SimpleUI plugin](https://github.com/doctorhetfield-cmd/simpleui.koplugin)** — This plugin is an extension of SimpleUI and relies entirely on its homescreen module system, shared book-data helpers, and registry API.
- **[quanganhdo/koreader-user-patches](https://github.com/quanganhdo/koreader-user-patches)** — `module_recent_book_stats.lua` is a modified version of `2-reading-stats-popup.lua` from this repository, adapted as a SimpleUI homescreen module.
- **GitHub Copilot (Claude Sonnet)** — This plugin was created with the assistance of AI.

