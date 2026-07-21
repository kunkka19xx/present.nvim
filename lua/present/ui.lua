--- Windows, chrome rendering, and teardown for the presentation floats.
local state = require("present.state")
local config = require("present.config")

local M = {}
local ns = vim.api.nvim_create_namespace("present-dim")

-- Back-to-front order of the deck's floats. Iterating a fixed list (rather than
-- hashing over `state.floats`) keeps resize and teardown deterministic.
local FLOAT_ORDER = { "background", "banner", "header", "body", "footer" }

--- Open a scratch-backed float. The buffer starts non-modifiable so a stray
--- keypress can't edit the deck; `set_lines` unlocks briefly to write.
function M.create_floating_window(cfg, enter)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].modifiable = false
  return { buf = buf, win = vim.api.nvim_open_win(buf, enter == true, cfg) }
end

-- Replace a float's contents. The buffers are kept non-modifiable so the viewer
-- can't type into the deck; we briefly unlock only for the plugin's own writes.
local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

--- Geometry for the deck's floats, laid out top to bottom:
---
---   row 0            banner    optional dim header text, borderless, no box
---   row banner..+2   header    the title, inside a rounded box (3 rows)
---   row body_top..   body      slide content, inset horizontally, no border
---   last row         footer    user footer text + page counter
---
--- The banner row is reserved for the whole deck whenever any header text
--- exists, so the body never shifts as you move between slides.
---
--- The title box, by contrast, is per-slide: an untitled slide would otherwise
--- show an empty rounded box, so it is hidden and the body claims those three
--- rows. Reveal steps within a group all carry the same title, so this can
--- never shift the body mid-reveal.
---@param banner boolean  reserve the deck-wide banner row
---@param titled boolean  show the title box (false for a slide with no title)
function M.window_configurations(banner, titled)
  local cols, rows = vim.o.columns, vim.o.lines
  local banner_rows = banner and 1 or 0
  local title_rows = titled and 3 or 0 -- text line plus the rounded border above/below
  local body_top = banner_rows + title_rows
  local side_inset = 8

  -- Full-width, borderless, editor-relative strip - the shape of every float
  -- here except the body.
  local function strip(row, height, zindex)
    return {
      relative = "editor",
      style = "minimal",
      width = cols,
      height = height,
      col = 0,
      row = row,
      zindex = zindex,
    }
  end

  local cfg = {
    background = strip(0, rows, 1),
    header = vim.tbl_extend("force", strip(banner_rows, 1, 2), { border = "rounded", hide = not titled }),
    footer = strip(rows - 1, 1, 3),
    body = {
      relative = "editor",
      style = "minimal",
      width = cols - side_inset * 2,
      height = rows - body_top - 2,
      col = side_inset,
      row = body_top,
    },
  }
  if banner then
    cfg.banner = strip(0, 1, 2)
  end
  return cfg
end

--- Run `cb(name, float)` over the live floats, back to front.
function M.foreach_float(cb)
  for _, name in ipairs(FLOAT_ORDER) do
    local float = state.floats[name]
    if float then
      cb(name, float)
    end
  end
end

--- Re-fit every float to the current terminal size and redraw the slide. Called
--- on VimResized; a no-op once the presentation is gone.
function M.relayout()
  if not state.active or not vim.api.nvim_win_is_valid(state.floats.body.win) then
    return
  end
  local cfg = M.window_configurations(state.banner, state.titled)
  M.foreach_float(function(name, float)
    if cfg[name] then
      pcall(vim.api.nvim_win_set_config, float.win, cfg[name])
    end
  end)
  M.set_slide_content(state.current_slide)
end

--- Left-pad `text` so it is centered within `width` columns.
function M.centered(text, width)
  local pad = math.max(0, math.floor((width - vim.fn.strdisplaywidth(text)) / 2))
  return string.rep(" ", pad) .. text
end

-- Dim the whole first line of `buf` (used for the mini gray header/footer text).
local function dim_line(buf, line)
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, line, 0, {
    end_row = line + 1,
    hl_group = "PresentDim",
    hl_eol = true,
  })
end

--- Show or hide the title box for the slide about to be drawn, handing its three
--- rows to the body when there is no title. Only touches the windows when the
--- state actually flips, so ordinary navigation reconfigures nothing.
local function set_chrome(titled)
  if state.titled == titled then
    return
  end
  state.titled = titled
  local cfg = M.window_configurations(state.banner, titled)
  pcall(vim.api.nvim_win_set_config, state.floats.header.win, cfg.header)
  pcall(vim.api.nvim_win_set_config, state.floats.body.win, cfg.body)
end

--- Render slide `idx` into the header/banner/body/footer floats.
function M.set_slide_content(idx)
  if not state.active then
    return
  end
  local opts = config.options
  idx = math.max(1, math.min(idx, #state.parsed.slides))
  state.current_slide = idx

  local slide = state.parsed.slides[idx]
  local global = state.parsed.global or {}
  local width = vim.o.columns

  -- Title goes in the rounded box; the optional header text sits ABOVE it in
  -- the borderless banner (dim), outside the box. An untitled slide drops the
  -- box entirely rather than showing an empty one.
  set_chrome((slide.title or "") ~= "")
  set_lines(state.floats.header.buf, { M.centered(slide.title or "", width) })
  if state.floats.banner then
    local eff_header = slide.header or global.header or ""
    vim.api.nvim_buf_clear_namespace(state.floats.banner.buf, ns, 0, -1)
    set_lines(state.floats.banner.buf, { M.centered(eff_header, width) })
    if eff_header ~= "" then
      dim_line(state.floats.banner.buf, 0)
    end
  end

  -- NB: body text is NOT indented - fenced code and headings must start at
  -- column 0 or treesitter / render-markdown won't parse them. Horizontal
  -- placement is left to the body window's position (see window config).
  local body = vim.deepcopy(slide.body)

  -- Vertical placement. Default: flow from the top with a small gap. Optional
  -- center_vertical anchors to the group's fullest reveal so the top stays put
  -- and reveals grow downward, rather than the whole block jumping.
  local first_is_table = body[1] ~= nil and body[1]:match("^%s*|") ~= nil

  local pad = 0
  if opts.center_vertical then
    local body_height = vim.api.nvim_win_get_height(state.floats.body.win)
    local anchor = slide.anchor or #body
    pad = math.max(0, math.floor((body_height - anchor) / 2))
  else
    pad = math.max(0, opts.top_padding or 0)
  end
  -- Always keep a blank line at the very top for the cursor to rest on (below the
  -- title). render-markdown's anti-conceal shows the RAW text of the cursor's
  -- line, so parking on a blank, un-rendered line keeps every slide fully drawn.
  -- A leading table needs TWO blank lines: render-markdown draws the table's top
  -- border on the blank line directly above it, so that border line must be a
  -- different blank line than the one the cursor sits on.
  pad = math.max(pad, 1)
  if first_is_table then
    pad = math.max(pad, 2)
  end
  for _ = 1, pad do
    table.insert(body, 1, "")
  end
  set_lines(state.floats.body.buf, body)

  -- Cursor on the top blank line: nothing renders there, and the view stays
  -- anchored at the top (no scrolling, even for tall slides).
  if vim.api.nvim_win_is_valid(state.floats.body.win) then
    pcall(vim.api.nvim_win_set_cursor, state.floats.body.win, { 1, 0 })
  end

  vim.api.nvim_buf_clear_namespace(state.floats.body.buf, ns, 0, -1)

  -- Colour the lines an expanded `>img` produced. These carry the picture: for
  -- chafa art the per-cell foreground/background, for kitty placeholders the
  -- image id. Rows are body-relative, so shift them past the top padding.
  for _, mark in ipairs(slide.image_marks or {}) do
    pcall(vim.api.nvim_buf_set_extmark, state.floats.body.buf, ns, pad + mark.row, mark.col, {
      end_col = mark.end_col,
      hl_group = mark.hl,
      priority = mark.priority,
    })
  end

  -- Spotlight: dim the lines carried over from the previous reveal step so the
  -- newest chunk is the bright one. `reveal_start` counts those leading lines.
  if opts.spotlight then
    local dim = math.min(slide.reveal_start or 0, #slide.body)
    for row = pad, pad + dim - 1 do
      pcall(vim.api.nvim_buf_set_extmark, state.floats.body.buf, ns, row, 0, {
        end_row = row + 1,
        hl_group = "PresentDim",
        hl_eol = true,
        priority = 300,
      })
    end
  end

  -- Footer: user text on the left, a small page counter on the right. Both dim.
  local eff_footer = slide.footer or global.footer or ""
  local counter = string.format("%d/%d%s ", idx, #state.parsed.slides, #slide.notes > 0 and " ●" or "")
  local left = eff_footer ~= "" and (" " .. eff_footer) or ""
  local gap = math.max(1, width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(counter))
  vim.api.nvim_buf_clear_namespace(state.floats.footer.buf, ns, 0, -1)
  set_lines(state.floats.footer.buf, { left .. string.rep(" ", gap) .. counter })
  dim_line(state.floats.footer.buf, 0)
end

--- Restore editor options and close every presentation float. Idempotent.
function M.end_presentation()
  if not state.active then
    return
  end
  state.active = false
  state.titled = nil
  for name, original in pairs(state.restore) do
    pcall(function()
      vim.o[name] = original
    end)
  end
  state.restore = {}
  M.foreach_float(function(_, float)
    pcall(vim.api.nvim_win_close, float.win, true)
  end)
  state.floats = {}
end

return M
