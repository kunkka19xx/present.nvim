--- Auxiliary popups: help/notes/run output, the slide picker, fuzzy search, and
--- the quit confirmation. These float ON TOP of the deck without tearing it down
--- (teardown is tied to the body *window* closing, not to losing focus).
local state = require("present.state")
local config = require("present.config")
local ui = require("present.ui")

local M = {}

-- width/height: a fraction (<= 1) of the screen, or an absolute cell count (> 1).
function M.open_overlay(lines, opts)
  opts = opts or {}
  local ow, oh = opts.width or 0.6, opts.height or 0.6
  local w = ow <= 1 and math.floor(vim.o.columns * ow) or ow
  local h = oh <= 1 and math.floor(vim.o.lines * oh) or oh
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = opts.title and (" " .. opts.title .. " ") or nil,
    width = w,
    height = h,
    row = math.floor((vim.o.lines - h) / 2),
    col = math.floor((vim.o.columns - w) / 2),
    zindex = 50,
  })
  vim.bo[buf].filetype = opts.filetype or "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local close = function()
    pcall(vim.api.nvim_win_close, win, true)
    if state.active and vim.api.nvim_win_is_valid(state.floats.body.win) then
      vim.api.nvim_set_current_win(state.floats.body.win)
    end
  end
  vim.keymap.set("n", "q", close, { buffer = buf })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf })
  return { buf = buf, win = win, close = close }
end

-- "  12  Title  ·  first body line" - searchable, disambiguates reveal steps.
local function slide_label(slide, i)
  local title = slide.title ~= "" and slide.title or "(untitled)"
  local preview = ""
  for _, l in ipairs(slide.body) do
    local t = vim.trim(l)
    if t ~= "" and not t:match("^```") then
      preview = t
      break
    end
  end
  return string.format("%3d  %s  ·  %s", i, title, preview)
end

-- The markdown a preview pane should show for a given slide index.
local function slide_preview_lines(idx)
  local slide = state.parsed.slides[idx]
  if not slide then
    return {}
  end
  local lines = {}
  if slide.title ~= "" then
    table.insert(lines, "# " .. slide.title)
    table.insert(lines, "")
  end
  vim.list_extend(lines, slide.body)
  return lines
end

--- Slide overview: a simple list; <CR> jumps.
function M.picker()
  local items = {}
  for i, slide in ipairs(state.parsed.slides) do
    table.insert(items, slide_label(slide, i))
  end
  local overlay = M.open_overlay(items, { title = "Slides", filetype = "text", width = 0.6 })
  vim.api.nvim_win_set_cursor(overlay.win, { state.current_slide, 0 })
  vim.keymap.set("n", "<CR>", function()
    local row = vim.api.nvim_win_get_cursor(overlay.win)[1]
    overlay.close()
    ui.set_slide_content(row)
  end, { buffer = overlay.buf })
end

-- Build an fzf-lua custom previewer that renders each slide on the right,
-- Telescope/fzf style. Returns nil if the fzf-lua API isn't as expected.
local function build_slide_previewer()
  local ok, builtin = pcall(require, "fzf-lua.previewer.builtin")
  if not ok or not builtin.base then
    return nil
  end
  local Slide = builtin.base:extend()

  function Slide:new(o, opts)
    Slide.super.new(self, o, opts)
    setmetatable(self, Slide)
    return self
  end

  function Slide:populate_preview_buf(entry_str)
    local idx = tonumber(entry_str and entry_str:match("^%s*(%d+)"))
    local buf = self:get_tmp_buffer()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, slide_preview_lines(idx))
    vim.bo[buf].filetype = "markdown"
    self:set_preview_buf(buf)
  end

  function Slide:gen_winopts()
    return vim.tbl_extend("keep", { wrap = true, number = false, cursorline = false }, self.winopts)
  end

  return Slide
end

--- Fuzzy-search slides with a preview pane. Uses fzf-lua if installed,
--- otherwise falls back to the built-in vim.ui.select (no preview).
function M.search()
  local entries = {}
  for i, slide in ipairs(state.parsed.slides) do
    table.insert(entries, slide_label(slide, i))
  end
  local jump = function(line)
    local idx = tonumber(line and line:match("^%s*(%d+)"))
    if idx then
      ui.set_slide_content(idx)
    end
  end
  local ok, fzf = pcall(require, "fzf-lua")
  if ok then
    fzf.fzf_exec(entries, {
      prompt = "Slides> ",
      previewer = build_slide_previewer(),
      winopts = {
        title = " Search slides ",
        preview = { layout = "horizontal", horizontal = "right:55%" },
      },
      actions = {
        ["default"] = function(selected)
          if selected and selected[1] then
            jump(selected[1])
            if state.active and vim.api.nvim_win_is_valid(state.floats.body.win) then
              vim.api.nvim_set_current_win(state.floats.body.win)
            end
          end
        end,
      },
    })
  else
    vim.ui.select(entries, { prompt = "Go to slide" }, function(choice)
      if choice then
        jump(choice)
      end
    end)
  end
end

--- Toggle a floating pane with the current slide's speaker notes.
function M.notes()
  local slide = state.parsed.slides[state.current_slide]
  local lines = (#slide.notes > 0) and slide.notes or { "(no notes on this slide)" }
  M.open_overlay(lines, { title = "Speaker notes", width = 0.5, height = 0.4 })
end

--- Run code block(s) on the current slide, output in an overlay.
---@param all boolean run every block, else just the first
function M.run_code(all)
  local slide = state.parsed.slides[state.current_slide]
  if #slide.blocks == 0 then
    vim.notify("No code blocks on this slide", vim.log.levels.INFO)
    return
  end
  local blocks = all and slide.blocks or { slide.blocks[1] }
  local output = {}
  for i, block in ipairs(blocks) do
    local executor = config.options.executors[block.language]
    table.insert(output, string.format("# Block %d (%s)", i, block.language == "" and "?" or block.language))
    table.insert(output, "")
    table.insert(output, "```" .. block.language)
    vim.list_extend(output, vim.split(block.body, "\n"))
    table.insert(output, "```")
    table.insert(output, "")
    table.insert(output, "## Output")
    table.insert(output, "")
    table.insert(output, "```")
    if executor then
      vim.list_extend(output, executor(block))
    else
      table.insert(output, "-- no executor for '" .. block.language .. "' --")
    end
    table.insert(output, "```")
    table.insert(output, "")
  end
  M.open_overlay(output, { title = "Run", width = 0.8, height = 0.8 })
end

--- Ask before quitting the presentation. Compact, content-fit, centered.
--- Closing the body window (on `y`) triggers teardown via the WinClosed autocmd.
function M.confirm_quit()
  local prompt = "Quit the presentation?"
  local choices = "[y] yes     [n] no"
  local inner = math.max(vim.fn.strdisplaywidth(prompt), vim.fn.strdisplaywidth(choices))
  local w = inner + 6
  local lines = { "", ui.centered(prompt, w), "", ui.centered(choices, w), "" }
  local ov = M.open_overlay(lines, { title = "Confirm", filetype = "text", width = w, height = #lines })
  vim.keymap.set("n", "y", function()
    ov.close()
    if vim.api.nvim_win_is_valid(state.floats.body.win) then
      vim.api.nvim_win_close(state.floats.body.win, true)
    end
  end, { buffer = ov.buf })
  vim.keymap.set("n", "n", ov.close, { buffer = ov.buf })
end

--- The help popup listing keys and separators.
function M.help()
  M.open_overlay({
    "# present.nvim - keys",
    "",
    "  n / <Space> / <Right>   next slide",
    "  p / b / <Left>          previous slide",
    "  gg / G                  first / last slide",
    "  {count}G                jump to slide {count}",
    "  /                       fuzzy-search slides",
    "  o                       slide overview / picker",
    "  X / A                   run first / all code blocks",
    "  s                       toggle speaker notes",
    "  r                       reload from the source file",
    "  ? / q                   help / quit (q confirms y/n)",
    "",
    "# separators",
    "",
    "  ># Title   new slide (with title)",
    "  >---       new slide (no title)",
    "  ---        in-slide reveal step",
    "  # heading  in-slide reveal (shown as content)",
    "  >hd / >ft  header / footer text",
    "  >// ...     comment (dropped, never shown)",
    "  >!note ...  callout box (note/tip/warning/...)",
    "  >qr <text>  render text as a QR code",
  }, { title = "Help", width = 0.55, height = 0.78 })
end

return M
