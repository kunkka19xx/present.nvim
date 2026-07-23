--- Auxiliary popups: help/notes/run output, the slide picker, fuzzy search, and
--- the quit confirmation. These float ON TOP of the deck without tearing it down
--- (teardown is tied to the body *window* closing, not to losing focus).
local state = require("present.state")
local config = require("present.config")
local ui = require("present.ui")
local toc = require("present.toc")

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
-- The trailing prose is the parser's `summary`, so table pipes, callout markers
-- and expanded QR/image art never end up in the label.
local function slide_label(slide, i)
  local title = slide.title ~= "" and slide.title or "(untitled)"
  local summary = slide.summary or ""
  if summary == "" then
    return string.format("%3d  %s", i, title)
  end
  return string.format("%3d  %s  ·  %s", i, title, summary)
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

local TITLE = "Contents"

--- Type a slide number in the contents popup to go there.
---
--- The numbers on the left are slide numbers, so `7` should mean slide 7 - but a
--- digit is not always a whole number: in an eleven-slide deck `1` could still
--- grow into `10`. So digits accumulate, and the jump fires at the first moment
--- the number is settled:
---
---   * immediately, once no larger slide number starts with what was typed
---     (`3` in a 20-slide deck can only become 3 once 30 is off the end),
---   * on `<CR>`, which commits whatever is pending,
---   * otherwise after `timeoutlen` with no further digit - the same rule Vim
---     uses to resolve its own ambiguous mappings.
---
--- The cursor tracks every keystroke so the target is visible as it narrows, and
--- the pending digits are shown in the border title: `cmdheight` is 0 while
--- presenting, so the command line is not available to echo into.
---@param overlay { buf: integer, win: integer, close: fun() }
---@param entries present.TocEntry[]
---@param jump fun(idx: integer)
---@return fun(): boolean  Commits a pending number, if there is one
local function bind_number_jump(overlay, entries, jump)
  local last = #state.parsed.slides
  local pending = ""
  local generation = 0 -- invalidates the timers of superseded keystrokes

  local function show_pending()
    local title = pending == "" and (" " .. TITLE .. " ") or (" " .. TITLE .. "  " .. pending .. " ")
    pcall(vim.api.nvim_win_set_config, overlay.win, { title = title })
  end

  local function commit()
    local idx = tonumber(pending)
    pending = ""
    if idx then
      jump(idx) -- out-of-range numbers are clamped by set_slide_content
    end
    return idx ~= nil
  end

  for digit = 0, 9 do
    local key = tostring(digit)
    vim.keymap.set("n", key, function()
      local typed = pending .. key
      local slide = tonumber(typed)
      if slide == 0 then -- a leading zero names no slide
        return
      end
      pending = typed
      show_pending()
      if slide <= last then
        vim.api.nvim_win_set_cursor(overlay.win, { toc.entry_at(entries, slide), 0 })
      end
      if slide * 10 > last then -- no slide number extends this one
        commit()
        return
      end
      generation = generation + 1
      local mine = generation
      vim.defer_fn(function()
        -- Bail out if another digit followed, or the popup is already gone (`q`,
        -- `<Esc>`, or a jump) - a stale timer must not move the deck.
        if mine == generation and pending ~= "" and vim.api.nvim_win_is_valid(overlay.win) then
          commit()
        end
      end, vim.o.timeoutlen)
    end, { buffer = overlay.buf })
  end

  return commit
end

--- Table of contents: one row per logical slide - reveal steps and `>---` pages
--- are folded into the section they continue, so a title appears once and the
--- page range sits in the left column. <CR> jumps to a section's first page.
---
--- Rows are truncated rather than wrapped: the <CR> mapping reads the cursor's
--- row as an entry number, so a row spilling onto a second line would point at
--- the wrong section.
function M.picker()
  local entries = toc.entries(state.parsed.slides)
  local width = math.floor(vim.o.columns * 0.6)

  -- Left column: "6", or "1-5" for a section spanning several pages. Sized to
  -- the widest so the titles line up.
  local ranges, range_w = {}, 0
  for i, entry in ipairs(entries) do
    ranges[i] = entry.last > entry.index and (entry.index .. "-" .. entry.last) or tostring(entry.index)
    range_w = math.max(range_w, #ranges[i])
  end

  local items = {}
  for i, entry in ipairs(entries) do
    local label = entry.title
    if label == "" then -- an untitled section: name it after its first line
      label = entry.summary ~= "" and entry.summary or "(untitled)"
    end
    items[i] = string.format("  %" .. range_w .. "s   %s", ranges[i], ui.truncate(label, width - range_w - 7))
  end

  local height = math.max(1, math.min(#items, math.floor(vim.o.lines * 0.7)))
  local overlay = M.open_overlay(items, {
    title = TITLE,
    filetype = "text",
    width = width,
    height = height,
  })
  vim.wo[overlay.win].cursorline = true
  vim.api.nvim_win_set_cursor(overlay.win, { toc.entry_at(entries, state.current_slide), 0 })

  local function jump(idx)
    overlay.close()
    ui.set_slide_content(idx)
  end

  -- `<CR>` commits a half-typed number first (`1<CR>` means slide 1, not "the
  -- section the cursor happens to be resting on"), and otherwise takes the row.
  local commit_number = bind_number_jump(overlay, entries, jump)
  vim.keymap.set("n", "<CR>", function()
    if commit_number() then
      return
    end
    local row = vim.api.nvim_win_get_cursor(overlay.win)[1]
    jump(entries[row] and entries[row].index or row)
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
    "  o                       table of contents ({number} jumps)",
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
    "  >img <path> [w]  render an image, w cells wide",
    "  >toc        put the contents list here",
  }, { title = "Help", width = 0.55, height = 0.78 })
end

return M
