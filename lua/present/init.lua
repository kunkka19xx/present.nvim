--- present.nvim — a minimal, hackable markdown slideshow for Neovim.
---
--- Separator design ("`>` prefix = slide-level, no prefix = in-slide"):
---   ># Title      new slide, with a title (>#, >##, ... any level)
---   >---          new slide, no title
---   ---           in-slide reveal: the next chunk appears on keypress
---   # / ## / ...   a plain markdown heading is also an in-slide reveal
---                 (it appears as content on the next keypress)
---   >// ...        comment line, dropped from the slide (never shown)
---   Notes: ...     speaker note, shown with `s`, never on the slide
---
--- Keys during a presentation:
---   n / <Space> / <Right>   next    p / b / <Left>   previous
---   gg first   G last   {count}G goto   o overview
---   X run first block   A run all blocks   s notes   ? help   q quit

local M = {}

----------------------------------------------------------------------
-- Executors
----------------------------------------------------------------------

--- Run lua in-process, capturing print() output.
---@param block present.Block
local execute_lua_code = function(block)
  local original_print = print
  local output = {}
  print = function(...)
    local args = { ... }
    local message = table.concat(vim.tbl_map(tostring, args), "\t")
    for _, line in ipairs(vim.split(message, "\n")) do
      table.insert(output, line)
    end
  end
  local chunk = loadstring(block.body)
  pcall(function()
    if not chunk then
      table.insert(output, " <<<BROKEN CODE>>>")
    else
      chunk()
    end
  end)
  print = original_print
  return output
end

--- Build an executor that writes the block to a temp file and runs `program`.
--- `ext` (optional) sets the temp-file extension (some tools require one).
M.create_system_executor = function(program, ext)
  return function(block)
    local tempfile = vim.fn.tempname() .. (ext or "")
    vim.fn.writefile(vim.split(block.body, "\n"), tempfile)
    local result = vim.system({ program, tempfile }, { text = true }):wait()
    local out = vim.split(result.stdout or "", "\n")
    if result.code ~= 0 and result.stderr and #result.stderr > 0 then
      table.insert(out, "")
      table.insert(out, "-- stderr --")
      vim.list_extend(out, vim.split(result.stderr, "\n"))
    end
    return out
  end
end

--- Compile-then-run executor for Rust.
local execute_rust_code = function(block)
  local tempfile = vim.fn.tempname() .. ".rs"
  local outputfile = tempfile:sub(1, -4)
  vim.fn.writefile(vim.split(block.body, "\n"), tempfile)
  local result = vim.system({ "rustc", tempfile, "-o", outputfile }, { text = true }):wait()
  if result.code ~= 0 then
    return vim.split(result.stderr, "\n")
  end
  result = vim.system({ outputfile }, { text = true }):wait()
  return vim.split(result.stdout, "\n")
end

--- Compile-then-run executor for Go.
local execute_go_code = function(block)
  local tempfile = vim.fn.tempname() .. ".go"
  vim.fn.writefile(vim.split(block.body, "\n"), tempfile)
  local result = vim.system({ "go", "run", tempfile }, { text = true }):wait()
  local out = vim.split(result.stdout or "", "\n")
  if result.code ~= 0 and result.stderr and #result.stderr > 0 then
    vim.list_extend(out, vim.split(result.stderr, "\n"))
  end
  return out
end

----------------------------------------------------------------------
-- Options
----------------------------------------------------------------------

---@class present.Syntax
---@field comment string?          Prefix for dropped comment lines (startswith, not a pattern)
---@field notes string?            Lua pattern for speaker-note lines
---@field reveal_on_heading boolean Treat plain markdown headings as in-slide reveals

---@class present.Options
---@field syntax present.Syntax
---@field center_vertical boolean  Vertically center body content in the card
---@field executors table<string, fun(block: present.Block): string[]>

local defaults = {
  syntax = {
    comment = ">//",
    notes = "^[Nn]otes?:%s?",
    reveal_on_heading = true,
  },
  center_vertical = true,
  executors = {
    lua = execute_lua_code,
    javascript = M.create_system_executor("node"),
    typescript = M.create_system_executor("npx", ".ts"),
    python = M.create_system_executor("python3"),
    bash = M.create_system_executor("bash"),
    sh = M.create_system_executor("sh"),
    go = execute_go_code,
    rust = execute_rust_code,
  },
}

---@type present.Options
local options = vim.deepcopy(defaults)

--- Configure the plugin (optional — sensible defaults otherwise).
---@param opts present.Options?
M.setup = function(opts)
  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

----------------------------------------------------------------------
-- Parsing
----------------------------------------------------------------------

---@class present.Block
---@field language string
---@field body string

---@class present.Slide
---@field title string
---@field body string[]
---@field blocks present.Block[]
---@field notes string[]

---@class present.Slides
---@field slides present.Slide[]

-- Lua patterns, tested only when NOT inside a fenced code block.
local PAT = {
  slide_title = "^>%s*#+%s*(.-)%s*$", -- ># Title / >## Title  (capture = title)
  slide_break = "^>%s*%-%-%-+%s*$", -- >---
  reveal_rule = "^%s*%-%-%-+%s*$", -- ---
  reveal_head = "^#+%s", -- plain markdown heading
}

--- Parse buffer lines into slides (with reveals expanded to sub-slides).
---@param lines string[]
---@return present.Slides
local parse_slides = function(lines)
  local slides = { slides = {} }

  local new_slide = function()
    return { title = "", body = {}, blocks = {}, notes = {} }
  end

  local body_has_content = function(slide)
    for _, l in ipairs(slide.body) do
      if vim.trim(l) ~= "" then
        return true
      end
    end
    return false
  end

  local has_content = function(slide)
    return #slide.title > 0 or #slide.notes > 0 or body_has_content(slide)
  end

  local push = function(slide)
    if has_content(slide) then
      table.insert(slides.slides, slide)
    end
  end

  -- Snapshot the slide-so-far as a reveal step (only if it holds real content).
  local reveal = function(slide)
    if body_has_content(slide) then
      table.insert(slides.slides, vim.deepcopy(slide))
    end
  end

  local current = new_slide()
  local in_code = false
  local code_lang, code_body = "", {}

  local comment = options.syntax.comment
  local notes = options.syntax.notes
  local reveal_on_heading = options.syntax.reveal_on_heading

  -- Titles are "sticky": once `>#` sets one it stays in the header across
  -- reveals AND `>---` pages, until the next `>#` changes it.
  local last_title = ""

  for _, raw in ipairs(lines) do
    local trimmed = (raw:gsub("%s*$", ""))
    local fence = raw:match("^%s*```(%S*)") or raw:match("^%s*~~~(%S*)")

    -- Fenced code blocks -------------------------------------------
    if fence ~= nil then
      if not in_code then
        in_code, code_lang, code_body = true, vim.trim(fence), {}
      else
        in_code = false
        table.insert(current.blocks, { language = code_lang, body = table.concat(code_body, "\n") })
      end
      table.insert(current.body, trimmed)
      goto continue
    end
    if in_code then
      table.insert(code_body, raw)
      table.insert(current.body, trimmed)
      goto continue
    end

    -- Slide-level markers (`>` prefix) -----------------------------
    do
      local title = raw:match(PAT.slide_title)
      if title ~= nil then
        push(current)
        current = new_slide()
        last_title = title
        current.title = title
        goto continue
      end
    end
    if raw:match(PAT.slide_break) then
      push(current)
      current = new_slide()
      current.title = last_title -- carry the title onto the new page
      goto continue
    end

    -- Dropped / captured lines -------------------------------------
    if comment and vim.startswith(raw, comment) then
      goto continue
    end
    if notes and raw:match(notes) then
      table.insert(current.notes, (raw:gsub(notes, "")))
      goto continue
    end

    -- In-slide reveals ---------------------------------------------
    if raw:match(PAT.reveal_rule) then
      reveal(current) -- `---` marker itself is not rendered
      goto continue
    end
    if reveal_on_heading and raw:match(PAT.reveal_head) then
      reveal(current) -- heading reveals on the next keypress...
      table.insert(current.body, trimmed) -- ...and is shown as content
      goto continue
    end

    table.insert(current.body, trimmed)
    ::continue::
  end

  push(current)
  return slides
end

----------------------------------------------------------------------
-- Windows
----------------------------------------------------------------------

local function create_floating_window(config, enter)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, enter or false, config)
  return { buf = buf, win = win }
end

local create_window_configurations = function()
  local width = vim.o.columns
  local height = vim.o.lines
  local header_height = 1 + 2
  local footer_height = 1
  local body_height = height - header_height - footer_height - 2 - 1

  return {
    background = { relative = "editor", width = width, height = height, style = "minimal", col = 0, row = 0, zindex = 1 },
    header = {
      relative = "editor",
      width = width,
      height = 1,
      style = "minimal",
      border = "rounded",
      col = 0,
      row = 0,
      zindex = 2,
    },
    body = {
      relative = "editor",
      width = width - 8,
      height = body_height,
      style = "minimal",
      border = { " ", " ", " ", " ", " ", " ", " ", " " },
      col = 8,
      row = 4,
    },
    footer = { relative = "editor", width = width, height = 1, style = "minimal", col = 0, row = height - 1, zindex = 3 },
  }
end

----------------------------------------------------------------------
-- State + lifecycle
----------------------------------------------------------------------

local state = {
  parsed = { slides = {} },
  current_slide = 1,
  floats = {},
  title = "",
  active = false,
}
local restore = {}

local foreach_float = function(cb)
  for name, float in pairs(state.floats) do
    cb(name, float)
  end
end

local set_slide_content = function(idx)
  if not state.active then
    return
  end
  idx = math.max(1, math.min(idx, #state.parsed.slides))
  state.current_slide = idx

  local slide = state.parsed.slides[idx]
  local width = vim.o.columns

  local title = slide.title or ""
  local title_pad = math.max(0, math.floor((width - vim.fn.strdisplaywidth(title)) / 2))
  vim.api.nvim_buf_set_lines(state.floats.header.buf, 0, -1, false, { string.rep(" ", title_pad) .. title })

  local body = vim.deepcopy(slide.body)
  if options.center_vertical then
    local body_height = vim.api.nvim_win_get_height(state.floats.body.win)
    local pad = math.floor((body_height - #body) / 2)
    for _ = 1, pad do
      table.insert(body, 1, "")
    end
  end
  vim.api.nvim_buf_set_lines(state.floats.body.buf, 0, -1, false, body)

  local hint = "  n/p move · / search · o overview · X/A run · s notes · ? help · q quit"
  local left = string.format("  %d / %d | %s", idx, #state.parsed.slides, state.title)
  if #slide.notes > 0 then
    left = left .. "  ●notes"
  end
  local gap = math.max(1, width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(hint) - 2)
  vim.api.nvim_buf_set_lines(state.floats.footer.buf, 0, -1, false, { left .. string.rep(" ", gap) .. hint })
end

--- Restore editor options and close every presentation float. Idempotent.
local end_presentation = function()
  if not state.active then
    return
  end
  state.active = false
  for option, config in pairs(restore) do
    pcall(function()
      vim.opt[option] = config.original
    end)
  end
  foreach_float(function(_, float)
    pcall(vim.api.nvim_win_close, float.win, true)
  end)
  state.floats = {}
end

----------------------------------------------------------------------
-- Overlays (picker / notes / run output)
----------------------------------------------------------------------

--- Auxiliary floats do NOT tear down the presentation: teardown is tied to
--- the body *window* closing, not to losing focus.
local open_overlay = function(lines, opts)
  opts = opts or {}
  local w = math.floor(vim.o.columns * (opts.width or 0.6))
  local h = math.floor(vim.o.lines * (opts.height or 0.6))
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

-- "  12  Title  ·  first body line" — searchable, disambiguates reveal steps.
local slide_label = function(slide, i)
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

local open_picker = function()
  local items = {}
  for i, slide in ipairs(state.parsed.slides) do
    table.insert(items, slide_label(slide, i))
  end
  local overlay = open_overlay(items, { title = "Slides", filetype = "text", width = 0.6 })
  vim.api.nvim_win_set_cursor(overlay.win, { state.current_slide, 0 })
  vim.keymap.set("n", "<CR>", function()
    local row = vim.api.nvim_win_get_cursor(overlay.win)[1]
    overlay.close()
    set_slide_content(row)
  end, { buffer = overlay.buf })
end

--- Fuzzy-search slide titles and jump. Uses fzf-lua if installed,
--- otherwise falls back to the built-in vim.ui.select.
local goto_search = function()
  local entries = {}
  for i, slide in ipairs(state.parsed.slides) do
    table.insert(entries, slide_label(slide, i))
  end
  local jump = function(line)
    local idx = tonumber(line and line:match("^%s*(%d+)"))
    if idx then
      set_slide_content(idx)
    end
  end
  local ok, fzf = pcall(require, "fzf-lua")
  if ok then
    fzf.fzf_exec(entries, {
      prompt = "Slides> ",
      winopts = { title = " Search slides " },
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

--- Ask before quitting the presentation.
local confirm_quit = function()
  local ov = open_overlay(
    { "", "  Quit the presentation?", "", "  [y] yes       [n] no", "" },
    { title = "Confirm", filetype = "text", width = 0.3, height = 0.28 }
  )
  vim.keymap.set("n", "y", function()
    ov.close()
    if vim.api.nvim_win_is_valid(state.floats.body.win) then
      vim.api.nvim_win_close(state.floats.body.win, true)
    end
  end, { buffer = ov.buf })
  vim.keymap.set("n", "n", ov.close, { buffer = ov.buf })
end

local show_notes = function()
  local slide = state.parsed.slides[state.current_slide]
  local lines = (#slide.notes > 0) and slide.notes or { "(no notes on this slide)" }
  open_overlay(lines, { title = "Speaker notes", width = 0.5, height = 0.4 })
end

---@param all boolean run every block, else just the first
local run_code = function(all)
  local slide = state.parsed.slides[state.current_slide]
  if #slide.blocks == 0 then
    vim.notify("No code blocks on this slide", vim.log.levels.INFO)
    return
  end
  local blocks = all and slide.blocks or { slide.blocks[1] }
  local output = {}
  for i, block in ipairs(blocks) do
    local executor = options.executors[block.language]
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
  open_overlay(output, { title = "Run", width = 0.8, height = 0.8 })
end

----------------------------------------------------------------------
-- Start
----------------------------------------------------------------------

local present_keymap = function(mode, key, callback)
  vim.keymap.set(mode, key, callback, { buffer = state.floats.body.buf })
end

M.start_presentation = function(opts)
  opts = opts or {}
  opts.bufnr = opts.bufnr or 0

  local lines = vim.api.nvim_buf_get_lines(opts.bufnr, 0, -1, false)
  state.parsed = parse_slides(lines)
  if #state.parsed.slides == 0 then
    vim.notify("present: no slides found (use `># Title` or `>---`)", vim.log.levels.WARN)
    return
  end
  state.current_slide = 1
  state.title = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(opts.bufnr), ":t")
  state.active = true

  local windows = create_window_configurations()
  state.floats.background = create_floating_window(windows.background)
  state.floats.header = create_floating_window(windows.header)
  state.floats.footer = create_floating_window(windows.footer)
  state.floats.body = create_floating_window(windows.body, true)

  foreach_float(function(_, float)
    vim.bo[float.buf].filetype = "markdown"
  end)
  vim.wo[state.floats.body.win].conceallevel = 2
  vim.wo[state.floats.body.win].concealcursor = "nc"

  local next = function()
    set_slide_content(state.current_slide + 1)
  end
  local prev = function()
    set_slide_content(state.current_slide - 1)
  end
  present_keymap("n", "n", next)
  present_keymap("n", "<Right>", next)
  present_keymap("n", "<Space>", next)
  present_keymap("n", "p", prev)
  present_keymap("n", "<Left>", prev)
  present_keymap("n", "b", prev)
  present_keymap("n", "gg", function()
    set_slide_content(1)
  end)
  present_keymap("n", "G", function()
    local n = vim.v.count
    set_slide_content(n > 0 and n or #state.parsed.slides)
  end)
  present_keymap("n", "o", open_picker)
  present_keymap("n", "/", goto_search)
  present_keymap("n", "X", function()
    run_code(false)
  end)
  present_keymap("n", "A", function()
    run_code(true)
  end)
  present_keymap("n", "s", show_notes)
  present_keymap("n", "?", function()
    open_overlay({
      "# present.nvim — keys",
      "",
      "  n / <Space> / <Right>   next slide",
      "  p / b / <Left>          previous slide",
      "  gg / G                  first / last slide",
      "  {count}G                jump to slide {count}",
      "  /                       fuzzy-search slide titles",
      "  o                       slide overview / picker",
      "  X / A                   run first / all code blocks",
      "  s                       toggle speaker notes",
      "  ? / q                   help / quit (q confirms y/n)",
      "",
      "# separators",
      "",
      "  ># Title   new slide (with title)",
      "  >---       new slide (no title)",
      "  ---        in-slide reveal step",
      "  # heading  in-slide reveal (shown as content)",
      "  >// ...     comment (dropped, never shown)",
    }, { title = "Help", width = 0.55, height = 0.7 })
  end)
  present_keymap("n", "q", confirm_quit)

  restore = {
    cmdheight = { original = vim.o.cmdheight, present = 0 },
    guicursor = { original = vim.o.guicursor, present = "n:NormalFloat" },
    wrap = { original = vim.o.wrap, present = true },
    breakindent = { original = vim.o.breakindent, present = true },
    breakindentopt = { original = vim.o.breakindentopt, present = "list:-1" },
  }
  for option, config in pairs(restore) do
    vim.opt[option] = config.present
  end

  -- Teardown follows the body WINDOW closing (not focus loss) so overlays are safe.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup("present-teardown", { clear = true }),
    pattern = tostring(state.floats.body.win),
    callback = end_presentation,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = vim.api.nvim_create_augroup("present-resized", { clear = true }),
    callback = function()
      if not state.active or not vim.api.nvim_win_is_valid(state.floats.body.win) then
        return
      end
      local updated = create_window_configurations()
      foreach_float(function(name, _)
        vim.api.nvim_win_set_config(state.floats[name].win, updated[name])
      end)
      set_slide_content(state.current_slide)
    end,
  })

  set_slide_content(state.current_slide)
end

M._parse_slides = parse_slides
return M
