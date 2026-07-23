--- Configuration: defaults, the live `options` table, and `setup()`.
local executors = require("present.executors")

-- WARNING when customising markers: they are matched LITERALLY at the start of a
-- line, so pick tokens that cannot collide with content you actually write or
-- with markdown you render. Avoid bare markdown/vim syntax such as `#` (heading),
-- `>` alone (blockquote), `-`/`*` (list/rule), `` ` `` (code). The defaults use a
-- `>`+non-space prefix precisely because that is not something you'd normally
-- type as prose or valid markdown. `slide_break`/`reveal` must be their own whole
-- line; `slide`/`header`/`footer`/`comment`/`notes` are line prefixes.
---@class present.Syntax
---@field slide string?             Prefix marking a titled slide (default ">#")
---@field slide_break string?       Whole-line marker for a new untitled slide (">---")
---@field reveal string?            Whole-line marker for an in-slide reveal ("---")
---@field header string?            Prefix for header text (">hd")
---@field footer string?            Prefix for footer text (">ft")
---@field comment string?           Prefix for dropped comment lines (">//")
---@field callout string?           Prefix opening a callout box (">!", e.g. ">!note")
---@field qr string?                Prefix rendering the rest of the line as a QR code (">qr")
---@field image string?             Prefix rendering an image file on the slide (">img")
---@field toc string?               Whole line listing the deck's sections (">toc")
---@field notes string?             Prefix for speaker-note lines ("Notes:")
---@field reveal_on_heading boolean Treat plain markdown headings as in-slide reveals

---@class present.Image
---@field backend string       "auto" | "kitty" | "chafa" | "off"
---@field width integer        Default image width in terminal cells
---@field max_height integer   Cap on image height in cells (0 = uncapped)
---@field cell_aspect number   Cell height / width; raise if images look squashed

---@class present.Toc
---@field auto boolean          Insert a contents slide automatically
---@field title string          Title for the auto-inserted slide
---@field after integer         Insert it after this slide (rounded up to a section boundary)
---@field min_sections integer  Skip the auto slide unless the deck has this many sections
---@field max_columns integer   Widen a long list into up to this many columns (1 = never)

---@class present.Options
---@field syntax present.Syntax
---@field toc present.Toc           Automatic table of contents
---@field center_vertical boolean   Center body vertically (else flow from top)
---@field top_padding integer       Blank lines above the body when not centering
---@field spotlight boolean         Dim already-revealed chunks so the newest stands out
---@field image present.Image       `>img` rendering
---@field executors table<string, fun(block: present.Block): string[]>

local M = {}

M.defaults = {
  -- All markers are LITERAL tokens. See the warning above present.Syntax.
  syntax = {
    slide = ">#", -- prefix: new slide, text after = title (also >##, >###)
    slide_break = ">---", -- whole line: new slide, no title
    reveal = "---", -- whole line: in-slide reveal step
    header = ">hd", -- prefix: header text (dim, above the title)
    footer = ">ft", -- prefix: footer text (dim, along the bottom)
    comment = ">//", -- prefix: line dropped, never shown
    callout = ">!", -- prefix: callout box, e.g. `>!note text` (note/tip/warning/...)
    qr = ">qr", -- prefix: render the rest of the line as a QR code (needs qrencode)
    image = ">img", -- prefix: render an image file, `>img <path> [width]`
    toc = ">toc", -- line: expands to a bullet list of the deck's section titles
    notes = "Notes:", -- prefix: speaker note (shown with `s`)
    reveal_on_heading = true, -- also treat plain markdown headings as reveals
  },
  -- A contents slide the deck gets for free. Writing `>toc` yourself turns this
  -- off for that deck - your placement wins.
  toc = {
    auto = true, -- false: only ever show a contents slide where `>toc` says
    title = "Contents", -- title of the auto-inserted slide
    after = 1, -- insert after slide 1 (the title slide); 0 = before everything
    min_sections = 3, -- don't bother for decks with fewer sections than this
    max_columns = 3, -- a long list widens into columns before it spills onto a
    -- second contents slide; 1 keeps it a plain single column
  },
  center_vertical = false, -- false: flow from top; true: center in the card
  top_padding = 1, -- blank lines above the body when not centering
  spotlight = false, -- true: dim already-revealed chunks so the newest stands out
  image = {
    -- "auto" probes the terminal: real graphics where they work, `chafa` cell
    -- art otherwise. Force one with "kitty"/"chafa", or "off" for a plain
    -- stand-in line.
    backend = "auto",
    width = 40, -- default width in cells; `>img pic.png 60` overrides per image
    max_height = 0, -- cap the height in cells, shrinking width to match (0 = uncapped)
    cell_aspect = 2.0, -- cell height / width; raise if images come out squashed
  },
  executors = {
    lua = executors.lua,
    javascript = executors.create_system_executor("node"),
    typescript = executors.create_system_executor("npx", ".ts"),
    python = executors.create_system_executor("python3"),
    bash = executors.create_system_executor("bash"),
    sh = executors.create_system_executor("sh"),
    go = executors.go,
    rust = executors.rust,
  },
}

--- The live options table. Read `require("present.config").options.X` at call
--- time (do not cache it - `setup` replaces the table).
---@type present.Options
M.options = vim.deepcopy(M.defaults)

--- Configure the plugin (optional - sensible defaults otherwise).
---@param opts present.Options?
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
