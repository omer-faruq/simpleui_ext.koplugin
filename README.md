# SimpleUI Extra Modules

Extra homescreen modules for SimpleUI on KOReader.

Currently includes one module: **Hero Currently Reading** — a large, bookshelf-style hero card that displays your currently-reading book with cover art, title, author, description blurb, and a progress bar with estimated time remaining.

---

## Modules

### Hero Currently Reading

Displays the most recently opened book as a full-width hero card, mirroring the layout used by the Bookshelf plugin:

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
- Cover image (30% of card width, 3:2 aspect ratio — bookshelf proportions)
- Title (bold, up to 2 lines) and author
- Description blurb pulled from BookInfoManager / DocSettings / custom metadata
- Progress bar with page count and estimated time remaining (sourced from the Statistics plugin database)
- Tap to open the book
- Supports SimpleUI's module scaling, theme colours, and frame/background options

---

## Requirements

| Dependency | Notes |
|---|---|
| **KOReader** | Any recent build |
| **SimpleUI plugin** | Required — this plugin extends SimpleUI's homescreen |
| **Statistics plugin** | Optional — enables the time-remaining estimate |
| **CoverBrowser / Bookshelf** | Optional — richer book descriptions |

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
       └── modules/
           └── module_hero_currently.lua
   ```

3. **Restart KOReader** (or use *Top Menu → Settings → Start fresh*).

4. SimpleUI will automatically detect and register the new modules on startup.

---

## Usage

### Enabling the module

1. Open KOReader and go to the **SimpleUI homescreen**.
2. Tap the top bar to open the SimpleUI menu.
3. Go to **Arrange Modules** (or the homescreen layout editor).
4. Find **"Hero Currently Reading"** in the list and enable it.
5. Drag it to the desired position on the homescreen.
6. Tap **Save** and return to the homescreen.

### What is shown

- The **most recently opened book** is displayed. If SimpleUI's built-in *Currently Reading* module is also active, both will share the same book.
- The **progress bar** shows current page / total pages on the left, and estimated time remaining on the right. Time remaining is calculated from the Statistics plugin's per-page reading history (capped at 3 minutes/page to avoid outliers).
- If no reading time data is available yet, only the page count is shown.

### Scaling

The module respects SimpleUI's per-module scale factor. Adjust it in the module settings to make the card larger or smaller. The cover size always stays at 30% of the card width regardless of scale; font sizes scale proportionally.

---

## Adding more modules

The plugin is designed to be extended. To add a new SimpleUI-compatible module:

1. Drop `module_yourname.lua` into `simpleui_ext.koplugin/modules/`.
2. Add `"modules/module_yourname"` to the `MODULES` table in `main.lua`.
3. Restart KOReader.

The module must follow [SimpleUI's module contract](https://github.com/jospalau/simpleui) (`id`, `name`, `label`, `enabled_key`, `build(w, ctx)`, `getHeight(ctx)`, …).

---

## Credits

- **[Bookshelf plugin](https://github.com/jospalau/bookshelf.koplugin)** — The hero card layout, cover proportions, progress bar style, and time-remaining calculation are all modelled after Bookshelf's hero card implementation. Bookshelf is the original source of this visual design.
- **[SimpleUI plugin](https://github.com/jospalau/simpleui)** — This plugin is an extension of SimpleUI and relies entirely on its homescreen module system, shared book-data helpers, and registry API.
- **GitHub Copilot (Claude Sonnet)** — This plugin was created with the assistance of AI. 

