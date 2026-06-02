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

<details>
<summary><b>Hero Currently Reading</b> — Full-width hero card showing your current book with cover, progress, and time remaining</summary>

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

</details>

<details>
<summary><b>Recent Book Stats</b> — Compact two-panel card with book progress and reading pace statistics</summary>

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

</details>

<details>
<summary><b>Reading Streaks</b> — Current and best reading streaks (daily and weekly)</summary>

### Reading Streaks

Displays current and best reading streaks (daily and weekly) in a compact four-column card:

```
┌──────────┬──────────┬──────────┬──────────┐
│ CURR WKS │ CURR DYS │ BEST WKS │ BEST DYS │
│    3     │    21    │    12    │    45    │
└──────────┴──────────┴──────────┴──────────┘
```

**Features:**
- Four streak metrics in a single row: current weeks, current days, best weeks, best days
- Data sourced from Statistics plugin database with intelligent caching
- Wallpaper-aware: transparent background with border when wallpaper is active, bold fonts for better readability
- Automatic cache invalidation when statistics database is updated
- SimpleUI-style section headers with separators

**Settings (via Arrange Modules):**

| Setting | Description |
|---|---|
| Show section label | Toggle "Reading Streaks" header visibility |
| Scale | Resize the card proportionally |

</details>

<details>
<summary><b>Reading Insights</b> — Yearly statistics and monthly reading activity chart</summary>

### Reading Insights

Displays yearly reading statistics and monthly reading activity chart:

```
◀ 2025                         2026
90 days read          1,407 pages read
┌─────┬─────┬─────┬─────┬─────┬─────┐
│ Jan │ Feb │ Mar │ Apr │ May │ Jun │
│ ▓▓▓ │ ▓▓▓ │ ▓▓▓ │ ▓▓▓ │ ▓▓▓ │ ▓▓▓ │
└─────┴─────┴─────┴─────┴─────┴─────┘
```

**Features:**
- Yearly statistics: days read and pages read (or hours read)
- Monthly activity chart showing reading days or hours per month
- Tap "◀ 2025" to open full Reading Insights popup (requires `2-reading-insights-popup.lua` patch)
- Display mode toggle: days vs. hours
- Wallpaper-aware: transparent background with border, bold fonts for readability
- Intelligent caching with automatic invalidation
- Chart bars are tappable to view books read in that month (when patch is installed)

**Settings (via Arrange Modules):**

| Setting | Description |
|---|---|
| Show section label | Toggle "Reading Insights" header visibility |
| Scale | Resize the card proportionally |
| Display Mode | Choose between "Days read per month" or "Hours read per month" |

**Note:** The full Reading Insights popup (opened by tapping the year) requires the `2-reading-insights-popup.lua` patch to be installed in KOReader's `patches/` folder (not in this plugin's patches folder).

</details>

<details>
<summary><b>Currently Reading (with Pace)</b> — Enhanced Currently Reading with avg time/day, pages/min, and %/day stats</summary>

### Currently Reading (with Pace)

Enhanced version of SimpleUI's built-in Currently Reading module with additional pace statistics:

```
┌─────────────────────────────────────────────┐
│ The Name of the Wind                        │
│ Patrick Rothfuss                            │
│ 73% • 199 pages • 2h 15m                    │
│ ████████████░░░░░                           │
│ 5h 30m to go                                │
│ 45m/day • 0.8 pg/min • 5.2%/day            │
└─────────────────────────────────────────────┘
```

**Features:**
- All standard Currently Reading features (title, author, progress, time remaining)
- **Three additional pace metrics:**
  - **avg_time_per_day** — Average reading time per day (e.g. "42m/day")
  - **pages_per_minute** — Reading speed in pages per minute (e.g. "0.8 pg/min")
  - **percent_per_day** — Average progress per day (e.g. "4.3%/day")
- Both default (line-per-stat) and compact (single row with ·) layouts
- Integrated into Arrange Items menu for custom ordering
- Individual visibility toggles for each pace stat
- Placeholder text when data not available
- Respects SimpleUI theme colors and scaling

**Settings (via Arrange Modules):**

| Setting | Description |
|---|---|
| Scale | Resize the card proportionally |
| Show avg_time_per_day | Toggle average time per day visibility |
| Show pages_per_minute | Toggle reading speed visibility |
| Show percent_per_day | Toggle progress per day visibility |
| Compact Layout | Display all stats in a single row with · separators |

**Note:** This is a standalone module (full copy of SimpleUI's module_currently.lua with pace additions) rather than a patch, ensuring stability independent of SimpleUI updates.

</details>

<details>
<summary><b>Currently Reading (Yanllsama)</b> — Enhanced reading dashboard with dynamic grid, customizable headers, and rich statistics</summary>

### Currently Reading (Yanllsama)

A completely redesigned, highly detailed, and fully dynamic reading statistics dashboard module with enriched data, brand new progress bar designs, dynamic grid management, and flexible interface options.

```
┌─────────────────────────────────────────────┐
│ ┌──────┐  The Name of the Wind              │
│ │      │  Patrick Rothfuss                  │
│ │Cover │                                     │
│ │      │  ┌─────────┬─────────┬─────────┐   │
│ └──────┘  │THIS BOOK│  SPEED  │ EXTRA 1 │   │
│           │ 2h left │ 0.8pg/m │ 21 days │   │
│           │ 199 pg  │ 45m/day │ 6d left │   │
│           └─────────┴─────────┴─────────┘   │
│           ████████████░░░░░ 73%             │
└─────────────────────────────────────────────┘
```

**Features:**
- **Fully Dynamic Grid System:** Freely determine layout with 1-4 columns and 1-6 rows
- **4 Customizable Category Headers:** Change header text (e.g., "THIS BOOK", "SPEED", "EXTRA 1"), adjust thickness, or hide completely
- **Rich Statistics (10 metrics):**
  - Time Left & Time Spent
  - Pages Read & Pages Left
  - Days Reading & Days to Go
  - Daily Average & Pages/Minute Speed
  - Mins/Session & Last Session Pages
- **Advanced Progress Bars (6 styles):** Simple, With percentage, Bold, Minimal, Outline, Segmented
- **Full Control (Edit Items):** Show/hide any statistic, rearrange display order with drag-and-drop
- **Smart Info Screen:** Tap book/author name to view full book description
- **Flexible Font & Size Controls:** Customize fonts and sizes for title, author, values, and labels
- **Time Format Options:** Readable (e.g., 3.5 hours) or XhYm (e.g., 3h 30 min)

**Settings (via Arrange Modules):**

| Setting | Description |
|---|---|
| Scale | Resize the card proportionally |
| Cover size | Scale for the cover thumbnail only |
| Cover Spacing | Horizontal space between cover and text (0-300%) |
| Grid Dimensions | Set columns (1-4) and rows (1-6) for statistics layout |
| Category Headers | Customize header text for each column, adjust thickness (thin/medium/bold), or hide |
| Edit Items | Toggle visibility of individual statistics and sort their display order |
| Progress bar style | Choose from 6 different bar designs |
| Time Format | Readable or XhYm format |
| Font Settings | Customize fonts and sizes for title, author, values, and labels |
| Exclude Paths from Recent | Comma-separated path fragments to skip certain books |

**Note:** This is an opt-in module (disabled by default). Enable it via **Tools → SimpleUI Extra → Modules**. Based on [yanllsama/koreader-enhanced-currently-reading](https://github.com/yanllsama/koreader-enhanced-currently-reading).

</details>

---

## Built-in Patches

In addition to new modules, this plugin applies transparent patches to SimpleUI's built-in modules to add missing functionality.

<details>
<summary><b>Cover Deck — Exclude Paths from Recent</b> — Filter books from Cover Deck's Recent Books source</summary>

### Cover Deck — Exclude Paths from Recent

When the Cover Deck source is set to **Recent Books**, this patch adds an **Exclude Paths from Recent** filter (identical to the one on Hero Currently Reading and Recent Book Stats).

**Setting (via Arrange Modules → Cover Deck):**

| Setting | Description |
|---|---|
| Exclude Paths from Recent | Comma-separated path fragments; books whose path contains any fragment are excluded from the Recent Books source (e.g. `/mnt/onboard/rss, instapaper, cache`) |

The filter has no effect when the source is set to **To Be Read**.

</details>

<details>
<summary><b>Cover Deck — Description Strip</b> — Show book descriptions below/above the carousel</summary>

### Cover Deck — Description Strip

Adds a brief description excerpt above or below the Cover Deck carousel, showing the active (center) book's description.

**Features:**
- Displays book description from BookInfoManager / DocSettings / custom metadata
- Tappable strip opens full description in a scrollable viewer
- Configurable position (above or below carousel)
- Adjustable text alignment and maximum length
- Automatically updates when carousel changes
- Integrates seamlessly with Cover Deck's existing layout

**Settings (via Arrange Modules → Cover Deck → Description):**

| Setting | Description |
|---|---|
| Enable Description | Toggle the description strip on/off (default: off) |
| Position | Display above or below the carousel (default: below) |
| Text Alignment | Left, center, or right alignment |
| Max Length | Maximum characters to display (default: 200) |

**Note:** This patch works alongside the Exclude Paths patch. Both can be enabled simultaneously without conflicts.

</details>

<details>
<summary><b>Module Copies</b> — Place the same module on multiple homescreen pages</summary>

### Module Copies

Adds a "Number of Copies" setting to all SimpleUI modules, allowing you to place the same module on multiple homescreen pages.

**Features:**
- Create 1-10 copies of any module (original + up to 9 extra copies)
- Each copy can be independently positioned on different pages
- Extra copies labeled as "Module Name (Copy 2)", "Copy 3", etc.
- Existing copy positions preserved when changing copy count
- New copies automatically added to the end of module order
- Performance optimized with module wrapping cache

**Settings (via Settings → Modules → Module Settings → [Any Module]):**

| Setting | Description |
|---|---|
| Number of Copies | Set how many copies of this module to show (1-10, default: 1) |

**Usage:**
1. Go to **Settings → Modules → Module Settings**
2. Select any module (e.g., "Clock", "Currently Reading")
3. Tap **"Number of Copies"**
4. Set the desired number (e.g., 3 for original + 2 extra copies)
5. Go to **Arrange Modules** to position each copy on different pages

**Example:**
- Set "Clock" to 3 copies
- Result: "Clock" (original), "Clock (Copy 2)", "Clock (Copy 3)"
- Place original on page 1, Copy 2 on page 2, Copy 3 on page 3

**Note:** This patch is disabled by default (opt-in). Enable it via **Tools → SimpleUI Extra → Patches**.

</details>

<details>
<summary><b>SimpleUI Home Screen on Sleep Screen</b> — Display your homescreen as the screensaver</summary>

### SimpleUI Home Screen on Sleep Screen

Displays your SimpleUI home screen as the sleep screen (screensaver), replacing the default wallpaper or cover image.

**Features:**
- Renders the full SimpleUI home screen (all modules) on the sleep screen
- No status bar or navigation bar — clean module-only view
- Multi-page support: choose which home screen page to display
- Portrait orientation enforced (matching cover/image modes)
- E-ink flash to clear ghosting before display
- Fallback to white screen if rendering fails

**Settings (via Settings → Wallpaper → Sleep screen):**

| Setting | Description |
|---|---|
| Show SimpleUI home screen on sleep screen | Radio option in the sleep screen type selector |
| Home screen page | Choose which page to display (1, 2, 3...) — only active when the option above is selected |

**Usage:**
1. Go to **Settings → Screen → Sleep screen → Wallpaper**
2. Select **"Show SimpleUI home screen on sleep screen"**
3. If you have multiple pages, tap **"Home screen page"** to choose which one
4. Put your device to sleep — your SimpleUI home screen will appear

**Note:** This patch is disabled by default (opt-in). Enable it via **Tools → SimpleUI Extra → Patches**.

</details>

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
       │   ├── module_recent_book_stats.lua
       │   ├── module_reading_streaks.lua
       │   ├── module_reading_insights.lua
       │   ├── module_currently_with_pace.lua
       │   └── module_currently_yanllsama.lua
       └── patches/
           ├── patch_coverdeck_exclude.lua
           ├── patch_coverdeck_description.lua
           ├── patch_module_copies.lua
           └── patch_screensaver_homescreen.lua
   ```

3. **Restart KOReader** (or use *Top Menu → Settings → Start fresh*).

4. SimpleUI will automatically detect and register all modules on startup.

---

## Usage

### How to Use This Plugin

After installation, SimpleUI Extra provides two types of enhancements:

1. **Modules** — New homescreen cards that you can add to your SimpleUI layout
2. **Patches** — Modifications to existing SimpleUI modules and KOReader features

---

### Managing Modules

**Enabling a module:**

1. Open KOReader and go to the **SimpleUI homescreen**
2. Tap the **top bar** to open the SimpleUI menu
3. Select **Arrange Modules** (or the homescreen layout editor)
4. Find the module by name (e.g. "Hero Currently Reading", "Reading Streaks")
5. **Enable** the module using the toggle
6. **Drag** it to your desired position in the layout
7. Tap **Save** and return to the homescreen

**Configuring module settings:**

1. In **Arrange Modules**, tap the module name
2. Adjust settings like:
   - **Scale** — Resize the card
   - **Show Frame** — Add borders
   - **Solid Background** — Fill background color
   - Module-specific options (varies by module)
3. Changes apply immediately after saving

**Disabling a module (performance):**

If you want to completely disable a module from loading (not just hide it from the layout):

1. Go to **Tools → SimpleUI Extra**
2. Find the module under **Modules**
3. Toggle it **off**
4. **Restart KOReader** for changes to take effect

This improves startup performance by preventing the module from loading at all.

---

### Managing Patches

**Patches are disabled by default** and must be explicitly enabled.

**Enabling a patch:**

1. Go to **Tools → SimpleUI Extra**
2. Find the patch under **Patches** section
3. Toggle it **on**
4. **Restart KOReader** for the patch to apply

**Available patches:**

- **Cover Deck — Exclude Paths from Recent** — Filter books from Cover Deck's Recent Books source
- **Cover Deck — Description Strip** — Show book descriptions below/above the carousel
- **Module Copies** — Place the same module on multiple homescreen pages
- **SimpleUI Home Screen on Sleep Screen** — Display your homescreen as the screensaver

**Disabling a patch:**

1. Go to **Tools → SimpleUI Extra**
2. Toggle the patch **off**
3. **Restart KOReader**

---

### Quick Start Example

**Goal:** Add a hero card showing your current book with a reading streak counter.

1. **Install** the plugin (see Installation section)
2. **Restart** KOReader
3. Open **SimpleUI homescreen** → tap top bar → **Arrange Modules**
4. **Enable** "Hero Currently Reading" and drag it to the top
5. **Enable** "Reading Streaks" and drag it below the hero card
6. Tap **Save**
7. Your homescreen now shows both modules!

**Optional:** Enable the "Cover Deck — Description Strip" patch:
1. Go to **Tools → SimpleUI Extra → Patches**
2. Enable **"Cover Deck — Description Strip"**
3. **Restart** KOReader
4. Go to **Arrange Modules → Cover Deck → Description**
5. Enable the description strip and configure position/alignment

---

## Toggle System

**Enable/disable modules and patches** via **Tools → SimpleUI Extra**:
- **Modules**: Enabled by default, can be disabled to improve startup performance
- **Patches**: Disabled by default (opt-in), enable only what you need
- **Restart required** after toggling

Settings stored in `settings/simpleui_ext.lua`.

---

## Adding Modules

**Auto-discovery**: Drop `module_yourname.lua` into `modules/` folder.

**Required fields**:
```lua
local M = {}
M.id = "yourname"  -- Must match filename: module_yourname.lua
M.name = "Your Module Name"
M.description = "Short description for toggle menu"
M.default_enabled = true  -- Loaded by default (optional, defaults to true)
-- ... rest of SimpleUI module contract
return M
```

**Rule**: `M.id` must match filename (`module_<id>.lua`)

---

## Adding Patches

**Auto-discovery**: Drop `patch_yourname.lua` into `patches/` folder.

**Required fields**:
```lua
local PATCH_ID = "yourname"  -- Must match filename: patch_yourname.lua

local P = {}
P.id = PATCH_ID
P.name = "Your Patch Name"
P.description = "Short description for toggle menu"
P.default_enabled = false  -- Patches default to disabled (opt-in)
P.apply = function()
    -- Monkey-patch code here
end
return P
```

**Rules**:
- `P.id` must match filename (`patch_<id>.lua`)
- Use `PATCH_ID` constant for consistency
- `apply()` called once after all plugins initialize

---

## Credits

- **[Bookshelf plugin](https://github.com/AndyHazz/bookshelf.koplugin)** — The hero card layout, cover proportions, progress bar style, and time-remaining calculation are all modelled after Bookshelf's hero card implementation.
- **[SimpleUI plugin](https://github.com/doctorhetfield-cmd/simpleui.koplugin)** — This plugin is an extension of SimpleUI and relies entirely on its homescreen module system, shared book-data helpers, and registry API.
- **[quanganhdo/koreader-user-patches](https://github.com/quanganhdo/koreader-user-patches)** — `module_recent_book_stats.lua` is a modified version of `2-reading-stats-popup.lua` from this repository, adapted as a SimpleUI homescreen module.
- **[zenixlabs/koreader-frankenpatches-public](https://github.com/zenixlabs/koreader-frankenpatches-public)** — `module_reading_streaks.lua` and `module_reading_insights.lua` are derived from `2-reading-insights-popup.lua` from this repository, adapted as SimpleUI homescreen modules.
- **[yanllsama/koreader-enhanced-currently-reading](https://github.com/yanllsama/koreader-enhanced-currently-reading)** — `module_currently_yanllsama.lua` is based on Yanllsama's enhanced Currently Reading module with dynamic grid system, customizable headers, and rich statistics.
- **GitHub Copilot (Claude Sonnet)** — This plugin was created with the assistance of AI.

