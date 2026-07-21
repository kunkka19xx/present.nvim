--- Image rendering for `>img <path> [width]` slides. The parser leaves a
--- `\1img:<spec>` sentinel line (staying pure); this module expands it into real
--- buffer lines plus a list of extmarks, cached per (file, mtime, size, backend).
---
--- Two encoders sit behind one seam:
---
---   kitty   the file is handed to the terminal with the kitty graphics
---           protocol and the slide gets UNICODE PLACEHOLDER cells - ordinary
---           text (U+10EEEE, the row as a combining diacritic, the image id as
---           the foreground colour) that the terminal paints over. Because they are
---           text, tmux tracks and redraws them, and they flow through this
---           plugin's normal render path (padding, reveals, spotlight) with no
---           compositing layer.
---   chafa   `chafa -f symbols` cell art for terminals without kitty graphics.
---           Its ANSI colours are parsed into extmarks over a cached highlight
---           group table, so a big image does not mint thousands of groups.
---
--- Anything missing (no backend, no file, unreadable header) degrades to a
--- readable stand-in line, so a deck never breaks over an image.
local config = require("present.config")

local M = {}

local SENTINEL = "^\1img:(.*)$"

local cache = {} -- key -> { lines: string[], marks: mark[][] }
local backend_probe = nil -- nil = not probed yet; false = probed, none available

---@class present.ImageMark
---@field col integer      byte column, 0-based
---@field end_col integer  byte column, exclusive
---@field hl string        highlight group name
---@field priority integer extmark priority

-- Terminal cells available to the body float. Mirrors ui.window_configurations'
-- `side_inset` on both sides; images are never wider than the slide.
local function body_width()
  return math.max(10, vim.o.columns - 16)
end

--- Split `<path> [width]`: a trailing all-digit token is the width, everything
--- before it is the path (so paths may contain spaces).
local function parse_spec(spec)
  local path, width = spec:match("^(.-)%s+(%d+)$")
  if not path or path == "" then
    return vim.trim(spec), nil
  end
  return vim.trim(path), tonumber(width)
end

--- Absolute path for `p`, resolving `~` and treating relatives as relative to
--- the deck file's own directory (not the editor's cwd).
local function resolve(p, base_dir)
  p = vim.fn.expand(p)
  if p:sub(1, 1) ~= "/" and base_dir and base_dir ~= "" then
    p = base_dir .. "/" .. p
  end
  return vim.fs.normalize(p)
end

-- Pixel dimensions -----------------------------------------------------------
-- Read straight from the file header so the primary (kitty) path needs no
-- external tooling at all. Only the aspect ratio is used. Unknown containers
-- return nil, which drops that image to the chafa encoder (which sizes itself).

local function u16be(s, i)
  return s:byte(i) * 256 + s:byte(i + 1)
end

local function u32be(s, i)
  return ((s:byte(i) * 256 + s:byte(i + 1)) * 256 + s:byte(i + 2)) * 256 + s:byte(i + 3)
end

--- Walk JPEG segments to the start-of-frame marker, which carries the size.
--- Layout at the marker: FF Cx | length(2) | precision(1) | height(2) | width(2).
local function jpeg_size(head)
  local i = 3
  while i + 8 <= #head do
    if head:byte(i) ~= 0xFF then
      i = i + 1 -- padding or desync; step until the next marker
    else
      local marker = head:byte(i + 1)
      if marker == 0xFF then
        i = i + 1 -- fill byte, markers may be padded with FFs
      elseif marker == 0x01 or (marker >= 0xD0 and marker <= 0xD9) then
        i = i + 2 -- standalone marker, no payload
      else
        -- SOF0..SOF15 carry the frame size; C4/C8/CC are tables, not frames.
        if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
          return u16be(head, i + 7), u16be(head, i + 5)
        end
        i = i + 2 + u16be(head, i + 2)
      end
    end
  end
end

--- Container format and pixel size, or nil for anything unrecognised.
---@return integer? width, integer? height, string? format
local function dimensions(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local head = f:read(128 * 1024) or ""
  f:close()
  if head:sub(1, 8) == "\137PNG\r\n\26\n" and #head >= 24 then
    return u32be(head, 17), u32be(head, 21), "png" -- IHDR width/height
  end
  if head:sub(1, 3) == "GIF" and #head >= 10 then
    return head:byte(7) + head:byte(8) * 256, head:byte(9) + head:byte(10) * 256, "gif"
  end
  if head:byte(1) == 0xFF and head:byte(2) == 0xD8 then
    local w, h = jpeg_size(head)
    if w then
      return w, h, "jpeg"
    end
  end
end

--- Cell box for an image of `px_w` x `px_h`, honouring an explicit `want` width.
--- Cells are about twice as tall as they are wide, hence `cell_aspect`.
local function geometry(px_w, px_h, want, opts)
  local cols = math.max(1, math.min(want or opts.width, body_width()))
  local rows = math.max(1, math.floor(cols * px_h / px_w / opts.cell_aspect + 0.5))
  if opts.max_height > 0 and rows > opts.max_height then
    -- Too tall: cap the height and shrink the width to keep the aspect ratio.
    rows = opts.max_height
    cols = math.max(1, math.floor(rows * opts.cell_aspect * px_w / px_h + 0.5))
  end
  return cols, rows
end

-- Backend detection ----------------------------------------------------------

local function tmux_get(args)
  local result = vim.system(vim.list_extend({ "tmux" }, args), { text = true }):wait()
  if result.code == 0 and result.stdout then
    return vim.trim(result.stdout)
  end
end

--- Which encoder this terminal can actually drive. Probed once, then cached.
---@return "kitty"|"chafa"|nil
local function detect_backend()
  local kitty = true
  -- Placeholder cells carry the image id as an exact 24-bit foreground colour,
  -- which only survives with termguicolors on.
  if not vim.o.termguicolors then
    kitty = false
  end
  local term = os.getenv("TERM") or ""
  if os.getenv("TMUX") then
    -- Inside tmux $TERM describes tmux, not the terminal drawing the pixels,
    -- and the graphics escapes only reach it if passthrough is enabled.
    if tmux_get({ "show", "-gv", "allow-passthrough" }) ~= "on" then
      kitty = false
    end
    term = tmux_get({ "display-message", "-p", "#{client_termname}" }) or term
  end
  -- Deliberately a short list. Unicode placeholders are a separate feature from
  -- the graphics protocol, and terminals that implement the latter without the
  -- former paint the placeholder codepoints as tofu rather than as an image.
  -- WezTerm was checked by hand and does exactly that, despite speaking the
  -- graphics protocol fluently; iTerm2 and Konsole are the same story. Guessing
  -- wrong upward gives the user a wall of tofu, guessing wrong downward just
  -- gives chafa art, so only terminals known to handle placeholders get here.
  if
    kitty
    and (
      term:match("kitty")
      or term:match("ghostty")
      or os.getenv("KITTY_WINDOW_ID")
      or os.getenv("GHOSTTY_RESOURCES_DIR")
    )
  then
    return "kitty"
  end
  if vim.fn.executable("chafa") == 1 then
    return "chafa"
  end
end

--- The encoder in use, honouring `image.backend` (`"auto"` probes the terminal).
---@return "kitty"|"chafa"|nil
function M.backend()
  local want = config.options.image.backend
  if want == "off" then
    return nil
  end
  if want ~= "auto" then
    return want
  end
  if backend_probe == nil then
    backend_probe = detect_backend() or false
  end
  return backend_probe or nil
end

-- kitty graphics + unicode placeholders --------------------------------------

-- A placeholder cell names its row with a combining diacritic, and the protocol
-- fixes WHICH diacritic means row 1, row 2, and so on: the codepoints of general
-- category Mn and combining class 230 as of Unicode 6.0.0, in ascending order,
-- minus a handful that normalisation would fuse into the base character. That
-- rule cannot be evaluated at runtime (it needs UnicodeData.txt), so the list is
-- a constant, written as ranges since it is mostly whole Unicode blocks.
-- Position n in the expansion addresses row n.
local DIACRITIC_RANGES = [[
  0305 030D-030E 0310 0312 033D-033F 0346 034A-034C 0350-0352 0357 035B
  0363-036F 0483-0487 0592-0595 0597-0599 059C-05A1 05A8-05A9 05AB-05AC 05AF
  05C4 0610-0617 0657-065B 065D-065E 06D6-06DC 06DF-06E2 06E4 06E7-06E8
  06EB-06EC 0730 0732-0733 0735-0736 073A 073D 073F-0741 0743 0745 0747
  0749-074A 07EB-07F1 07F3 0816-0819 081B-0823 0825-0827 0829-082D 0951
  0953-0954 0F82-0F83 0F86-0F87 135D-135F 17DD 193A 1A17 1A75-1A7C 1B6B
  1B6D-1B73 1CD0-1CD2 1CDA-1CDB 1CE0 1DC0-1DC1 1DC3-1DC9 1DCB-1DCC 1DD1-1DE6
  1DFE 20D0-20D1 20D4-20D7 20DB-20DC 20E1 20E7 20E9 20F0 2CEF-2CF1 2DE0-2DFF
  A66F A67C-A67D A6F0-A6F1 A8E0-A8F1 AAB0 AAB2-AAB3 AAB7-AAB8 AABE-AABF AAC1
  FE20-FE26 10A0F 10A38 1D185-1D189 1D1AA-1D1AD 1D242-1D244
]]

local diacritic -- lazily expanded list of encoded combining chars

local function diacritics()
  if not diacritic then
    diacritic = {}
    for token in DIACRITIC_RANGES:gmatch("%S+") do
      local lo, hi = token:match("^(%x+)%-(%x+)$")
      lo = tonumber(lo or token, 16)
      hi = hi and tonumber(hi, 16) or lo
      for cp = lo, hi do
        table.insert(diacritic, vim.fn.nr2char(cp, 1))
      end
    end
  end
  return diacritic
end

-- Image ids double as the placeholder cells' foreground colour, so they must fit
-- in 24 bits. The high byte is picked to sit clear of the small ids other tools
-- hand out in the same terminal.
local next_image_id = 0x0A0000

--- Write a raw escape sequence to the terminal, wrapping it for tmux (which
--- otherwise swallows the graphics APC instead of forwarding it).
local function emit(seq)
  if os.getenv("TMUX") then
    seq = "\27Ptmux;" .. seq:gsub("\27", "\27\27") .. "\27\\"
  end
  io.stdout:write(seq)
  io.stdout:flush()
end

--- Hand `path` to the terminal and create a virtual placement `cols` x `rows`
--- cells in size. `q=2` silences the protocol's replies so they cannot leak
--- into the buffer.
---@return integer id
local function transmit(path, cols, rows)
  next_image_id = next_image_id + 1
  local id = next_image_id
  emit(("\27_Ga=t,t=f,f=100,i=%d,q=2;%s\27\\"):format(id, vim.base64.encode(path)))
  emit(("\27_Ga=p,U=1,i=%d,c=%d,r=%d,q=2\27\\"):format(id, cols, rows))
  return id
end

--- Placeholder cells for image `id`. Only the leading cell of each row is
--- addressed - the protocol lets a bare placeholder inherit the row of the cell
--- to its left and take the next column, provided the two share a foreground
--- colour, which the single line-wide highlight below guarantees.
local function kitty_cells(id, cols, rows)
  local d = diacritics()
  local cell = vim.fn.nr2char(0x10EEEE, 1)
  local group = "PresentImageId" .. id
  vim.api.nvim_set_hl(0, group, { fg = ("#%06x"):format(id) })

  local lines, marks = {}, {}
  for r = 1, rows do
    local line = cell .. d[r] .. d[1] .. cell:rep(cols - 1) -- row r, from column 0
    lines[r] = line
    -- That highlight carries the image id, so it has to outrank the spotlight's
    -- dimming: overwrite the foreground and the placement stops resolving.
    marks[r] = { { col = 0, end_col = #line, hl = group, priority = 400 } }
  end
  return { lines = lines, marks = marks }
end

local function kitty_render(path, cols, rows)
  if rows > #diacritics() then
    return nil -- taller than the row encoding can address
  end
  return kitty_cells(transmit(path, cols, rows), cols, rows)
end

-- chafa symbol art -----------------------------------------------------------

local hl_cache = {} -- "fg,bg" -> group name
local hl_count = 0

local function color_group(fg, bg)
  local key = (fg or "-") .. "," .. (bg or "-")
  local group = hl_cache[key]
  if not group then
    hl_count = hl_count + 1
    group = "PresentImage" .. hl_count
    vim.api.nvim_set_hl(0, group, { fg = fg, bg = bg })
    hl_cache[key] = group
  end
  return group
end

--- Apply one SGR parameter string to the running colour state. Only the codes
--- `chafa -c full` emits are honoured; anything else resets to "inherit".
local function apply_sgr(params, state)
  local codes = {}
  for n in params:gmatch("%d+") do
    table.insert(codes, tonumber(n))
  end
  if #codes == 0 then
    codes = { 0 } -- a bare `ESC[m` is `ESC[0m`
  end
  local i = 1
  while i <= #codes do
    local code = codes[i]
    if code == 0 then
      state.fg, state.bg = nil, nil
    elseif code == 39 then
      state.fg = nil
    elseif code == 49 then
      state.bg = nil
    elseif (code == 38 or code == 48) and codes[i + 1] == 2 then
      local hex = ("#%02x%02x%02x"):format(codes[i + 2] or 0, codes[i + 3] or 0, codes[i + 4] or 0)
      if code == 38 then
        state.fg = hex
      else
        state.bg = hex
      end
      i = i + 4
    end
    i = i + 1
  end
end

--- Split one ANSI-coloured line into plain text plus the extmarks that restore
--- its colours.
---@return string text, present.ImageMark[] marks
local function parse_ansi(raw)
  -- Drop non-SGR CSI sequences (cursor moves and the like); only colour matters.
  raw = raw:gsub("\27%[[%d;?]*[A-Za-ln-z]", "")
  local parts, marks = {}, {}
  local state = { fg = nil, bg = nil }
  local len, pos = 0, 1
  while pos <= #raw do
    local s, e, params = raw:find("\27%[([%d;]*)m", pos)
    local chunk = raw:sub(pos, (s or #raw + 1) - 1)
    if #chunk > 0 then
      if state.fg or state.bg then
        -- Below the spotlight's priority, so a carried-over image dims along
        -- with the rest of the already-revealed content.
        table.insert(marks, {
          col = len,
          end_col = len + #chunk,
          hl = color_group(state.fg, state.bg),
          priority = 200,
        })
      end
      table.insert(parts, chunk)
      len = len + #chunk
    end
    if not s then
      break
    end
    apply_sgr(params, state)
    pos = e + 1
  end
  return table.concat(parts), marks
end

local function chafa_render(path, cols, rows)
  local result = vim.system({
    "chafa",
    "-f",
    "symbols",
    "-c",
    "full", -- truecolor, so only `38;2;r;g;b` needs parsing
    "--animate",
    "off",
    "--exact-size",
    "off", -- fit the box, preserving the aspect ratio
    "-s",
    ("%dx%d"):format(cols, rows),
    "--",
    path,
  }, { text = true }):wait()
  if result.code ~= 0 or not result.stdout or result.stdout == "" then
    return nil
  end
  local lines, marks = {}, {}
  for i, raw in ipairs(vim.split(result.stdout:gsub("\n$", ""), "\n")) do
    lines[i], marks[i] = parse_ansi(raw)
  end
  -- chafa signs off with a bare colour reset, which parses to an empty line;
  -- left in, it pads the image and skews the slide's vertical anchor.
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  if #lines == 0 then
    return nil
  end
  return { lines = lines, marks = marks }
end

-- Expansion ------------------------------------------------------------------

local function standin(text)
  return { lines = { text }, marks = {} }
end

--- Render one `>img` spec to lines plus per-line marks, cached. The cache key
--- carries the file's mtime and the target size, so hot reload picks up both an
--- edited deck and an edited image.
local function render(spec, base_dir)
  local opts = config.options.image
  local path, want = parse_spec(spec)
  local abs = resolve(path, base_dir)

  local stat = vim.uv.fs_stat(abs)
  if not stat or stat.type ~= "file" then
    return standin("[image not found: " .. path .. "]")
  end
  local backend = M.backend()
  if not backend then
    if opts.backend == "off" then
      return standin("[image: " .. path .. "]")
    end
    return standin("[image: " .. path .. "] (install `chafa`, or use a kitty-graphics terminal)")
  end

  local px_w, px_h, format = dimensions(abs)
  local cols, rows
  if px_w and px_h and px_w > 0 and px_h > 0 then
    cols, rows = geometry(px_w, px_h, want, opts)
    if format ~= "png" then
      -- The graphics protocol only takes PNG bytes directly; chafa decodes the
      -- rest (jpeg, gif, webp, ...) itself.
      backend = backend == "kitty" and "chafa" or backend
    end
  else
    -- Unreadable header: no aspect ratio to work from, so hand the sizing to
    -- chafa inside a box of our width. A kitty placement needs an exact cell
    -- rectangle we cannot infer, so that path is out.
    cols = math.max(1, math.min(want or opts.width, body_width()))
    rows = opts.max_height > 0 and opts.max_height or math.floor(cols / opts.cell_aspect + 0.5)
    backend = backend == "kitty" and "chafa" or backend
  end

  local key = table.concat({ abs, stat.mtime.sec, stat.size, cols, rows, backend }, "|")
  if cache[key] then
    return cache[key]
  end

  local out
  if backend == "kitty" then
    out = kitty_render(abs, cols, rows)
  elseif backend == "chafa" and vim.fn.executable("chafa") == 1 then
    out = chafa_render(abs, cols, rows)
  end
  out = out or standin("[image: " .. path .. "] (could not be rendered)")
  cache[key] = out
  return out
end

--- Replace every `\1img:` sentinel line in each slide's body with the rendered
--- image, collecting the extmarks that colour it into `slide.image_marks`
--- (body-relative rows; `ui` offsets them by the slide's top padding).
--- Safe to call repeatedly - renders are cached; mutates the slides in place.
---@param slides present.Slide[]
---@param base_dir string?  directory the deck lives in, for relative paths
function M.expand(slides, base_dir)
  for _, slide in ipairs(slides) do
    local body, marks = {}, {}
    for _, line in ipairs(slide.body) do
      local spec = line:match(SENTINEL)
      if spec and spec ~= "" then
        local img = render(spec, base_dir)
        for i, l in ipairs(img.lines) do
          table.insert(body, l)
          for _, mark in ipairs(img.marks[i] or {}) do
            table.insert(marks, vim.tbl_extend("force", mark, { row = #body - 1 }))
          end
        end
      else
        table.insert(body, line)
      end
    end
    slide.body = body
    slide.image_marks = #marks > 0 and marks or nil
  end
end

--- Forget every render and the terminal probe. For tests, and for picking up a
--- terminal that gained graphics support mid-session.
function M.reset()
  cache, backend_probe = {}, nil
end

return M
