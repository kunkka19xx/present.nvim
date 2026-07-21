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
---@field notes string?             Prefix for speaker-note lines ("Notes:")
---@field reveal_on_heading boolean Treat plain markdown headings as in-slide reveals

---@class present.Options
---@field syntax present.Syntax
---@field center_vertical boolean   Center body vertically (else flow from top)
---@field top_padding integer       Blank lines above the body when not centering
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
    notes = "Notes:", -- prefix: speaker note (shown with `s`)
    reveal_on_heading = true, -- also treat plain markdown headings as reveals
  },
  center_vertical = false, -- false: flow from top; true: center in the card
  top_padding = 1, -- blank lines above the body when not centering
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
