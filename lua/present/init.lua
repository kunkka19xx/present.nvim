--- present.nvim - a minimal, hackable markdown slideshow for Neovim.
---
--- Separator design ("`>` prefix = slide-level, no prefix = in-slide"):
---   ># Title      new slide, with a title (>#, >##, ... any level)
---   >---          new slide, no title
---   ---           in-slide reveal: the next chunk appears on keypress
---   # / ## / ...   a plain markdown heading is also an in-slide reveal
---   >hd / >ft ...  header / footer text (dim), global or per-slide
---   >// ...        comment line, dropped from the slide (never shown)
---   >!note ...     callout box (note/tip/warning/...); more lines until a blank
---   Notes: ...     speaker note, shown with `s`, never on the slide
---
--- Keys during a presentation:
---   n / <Space> / <Right>   next    p / b / <Left>   previous
---   gg first   G last   {count}G goto   o overview   / search
---   X run first block   A run all blocks   s notes   r reload   ? help   q quit
---
--- Code is split across:
---   config     defaults + setup      parser    markdown -> slides
---   executors  code runners          state     shared runtime state
---   ui         windows + rendering   overlays  popups (picker/search/notes/run)
---   init       (this file)           public API + keymaps + lifecycle

local config = require("present.config")
local parser = require("present.parser")
local state = require("present.state")
local ui = require("present.ui")
local overlays = require("present.overlays")
local executors = require("present.executors")

local M = {}

--- Configure the plugin (optional - sensible defaults otherwise).
M.setup = config.setup

--- Build an executor that runs a program on the block's temp file. Exposed so
--- users can register extra languages in `setup { executors = { ... } }`.
M.create_system_executor = executors.create_system_executor

local function present_keymap(mode, key, callback)
  vim.keymap.set(mode, key, callback, { buffer = state.floats.body.buf })
end

--- Re-parse the source buffer and re-render the current slide in place. Used by
--- hot reload (the `r` key and `:w` on the source). Keeps the current position
--- (clamped) so edits show up without leaving the presentation. A brand-new
--- banner (header added/removed after start) is not re-laid-out - restart for that.
local function reload()
  if not state.active or not vim.api.nvim_buf_is_valid(state.source_buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(state.source_buf, 0, -1, false)
  local parsed = parser.parse(lines, config.options.syntax)
  if #parsed.slides == 0 then
    return
  end
  state.parsed = parsed
  ui.set_slide_content(state.current_slide) -- clamps to the new slide count
end

M.start_presentation = function(opts)
  opts = opts or {}
  opts.bufnr = opts.bufnr or 0
  -- Resolve 0 -> the real buffer so hot reload has a stable handle later.
  local source_buf = opts.bufnr == 0 and vim.api.nvim_get_current_buf() or opts.bufnr
  state.source_buf = source_buf

  local lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  state.parsed = parser.parse(lines, config.options.syntax)
  if #state.parsed.slides == 0 then
    vim.notify("present: no slides found (use `># Title` or `>---`)", vim.log.levels.WARN)
    return
  end
  state.current_slide = 1
  state.title = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(source_buf), ":t")
  state.active = true

  -- Reserve the top banner line if any header text is configured. Fixed for the
  -- whole deck so the body never shifts between slides.
  state.banner = state.parsed.global.header ~= nil
  for _, s in ipairs(state.parsed.slides) do
    state.banner = state.banner or s.header ~= nil
  end

  -- Mini gray highlight for the configured header/footer text.
  vim.api.nvim_set_hl(0, "PresentDim", { link = "Comment", default = true })

  local windows = ui.window_configurations(state.banner)
  state.floats.background = ui.create_floating_window(windows.background)
  state.floats.header = ui.create_floating_window(windows.header)
  state.floats.footer = ui.create_floating_window(windows.footer)
  state.floats.body = ui.create_floating_window(windows.body, true)
  if state.banner then
    state.floats.banner = ui.create_floating_window(windows.banner)
  end

  ui.foreach_float(function(_, float)
    vim.bo[float.buf].filetype = "markdown"
  end)
  vim.wo[state.floats.body.win].conceallevel = 2
  vim.wo[state.floats.body.win].concealcursor = "nc"

  -- Navigation ------------------------------------------------------
  local next = function()
    ui.set_slide_content(state.current_slide + 1)
  end
  local prev = function()
    ui.set_slide_content(state.current_slide - 1)
  end
  present_keymap("n", "n", next)
  present_keymap("n", "<Right>", next)
  present_keymap("n", "<Space>", next)
  present_keymap("n", "p", prev)
  present_keymap("n", "<Left>", prev)
  present_keymap("n", "b", prev)
  present_keymap("n", "gg", function()
    ui.set_slide_content(1)
  end)
  present_keymap("n", "G", function()
    local n = vim.v.count
    ui.set_slide_content(n > 0 and n or #state.parsed.slides)
  end)
  present_keymap("n", "o", overlays.picker)
  present_keymap("n", "/", overlays.search)

  -- Execution / info ------------------------------------------------
  present_keymap("n", "X", function()
    overlays.run_code(false)
  end)
  present_keymap("n", "A", function()
    overlays.run_code(true)
  end)
  present_keymap("n", "s", overlays.notes)
  present_keymap("n", "r", reload)
  present_keymap("n", "?", overlays.help)
  present_keymap("n", "q", overlays.confirm_quit)

  -- Editor options during the presentation (restored on teardown) ---
  state.restore = {
    cmdheight = { original = vim.o.cmdheight, present = 0 },
    guicursor = { original = vim.o.guicursor, present = "n:NormalFloat" },
    wrap = { original = vim.o.wrap, present = true },
    breakindent = { original = vim.o.breakindent, present = true },
    breakindentopt = { original = vim.o.breakindentopt, present = "list:-1" },
    laststatus = { original = vim.o.laststatus, present = 0 }, -- hide statusline
    showtabline = { original = vim.o.showtabline, present = 0 }, -- hide tabline
  }
  for option, cfg in pairs(state.restore) do
    vim.opt[option] = cfg.present
  end

  -- Teardown follows the body WINDOW closing (not focus loss) so overlays are safe.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup("present-teardown", { clear = true }),
    pattern = tostring(state.floats.body.win),
    callback = ui.end_presentation,
  })

  -- Hot reload: saving the source buffer re-renders the current slide in place.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = vim.api.nvim_create_augroup("present-reload", { clear = true }),
    buffer = source_buf,
    callback = reload,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = vim.api.nvim_create_augroup("present-resized", { clear = true }),
    callback = function()
      if not state.active or not vim.api.nvim_win_is_valid(state.floats.body.win) then
        return
      end
      local updated = ui.window_configurations(state.banner)
      ui.foreach_float(function(name, _)
        vim.api.nvim_win_set_config(state.floats[name].win, updated[name])
      end)
      ui.set_slide_content(state.current_slide)
    end,
  })

  ui.set_slide_content(state.current_slide)
end

-- Exposed for tests.
M._parse_slides = function(lines)
  return parser.parse(lines, config.options.syntax)
end

return M
