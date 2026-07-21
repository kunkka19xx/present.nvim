--- Windows, chrome rendering, and teardown for the presentation floats.
local state = require("present.state")
local config = require("present.config")

local M = {}
local ns = vim.api.nvim_create_namespace("present-dim")

function M.create_floating_window(cfg, enter)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, enter or false, cfg)
  return { buf = buf, win = win }
end

--- Window configs for the deck. When `banner` is true a borderless dim header
--- line sits ABOVE the title box (row 0). The banner is reserved for the whole
--- deck so the body never shifts between slides.
function M.window_configurations(banner)
  local width = vim.o.columns
  local height = vim.o.lines
  local banner_h = banner and 1 or 0
  -- Body sits directly under the title box (banner + top border + title + bottom
  -- border). No body border, so the only gap under the title is `top_padding`.
  local body_row = banner_h + 3
  local body_height = height - body_row - 2

  local cfg = {
    background = { relative = "editor", width = width, height = height, style = "minimal", col = 0, row = 0, zindex = 1 },
    header = {
      relative = "editor",
      width = width,
      height = 1,
      style = "minimal",
      border = "rounded",
      col = 0,
      row = banner_h,
      zindex = 2,
    },
    body = {
      relative = "editor",
      width = width - 16,
      height = body_height,
      style = "minimal",
      col = 8,
      row = body_row,
    },
    footer = { relative = "editor", width = width, height = 1, style = "minimal", col = 0, row = height - 1, zindex = 3 },
  }
  if banner then
    cfg.banner = { relative = "editor", width = width, height = 1, style = "minimal", col = 0, row = 0, zindex = 2 }
  end
  return cfg
end

function M.foreach_float(cb)
  for name, float in pairs(state.floats) do
    cb(name, float)
  end
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
  -- the borderless banner (dim), outside the box.
  vim.api.nvim_buf_set_lines(state.floats.header.buf, 0, -1, false, { M.centered(slide.title or "", width) })
  if state.floats.banner then
    local eff_header = slide.header or global.header or ""
    vim.api.nvim_buf_clear_namespace(state.floats.banner.buf, ns, 0, -1)
    vim.api.nvim_buf_set_lines(state.floats.banner.buf, 0, -1, false, { M.centered(eff_header, width) })
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
  if opts.center_vertical then
    local body_height = vim.api.nvim_win_get_height(state.floats.body.win)
    local anchor = slide.anchor or #body
    local pad = math.max(0, math.floor((body_height - anchor) / 2))
    for _ = 1, pad do
      table.insert(body, 1, "")
    end
  else
    for _ = 1, math.max(0, opts.top_padding or 0) do
      table.insert(body, 1, "")
    end
  end
  vim.api.nvim_buf_set_lines(state.floats.body.buf, 0, -1, false, body)

  -- Footer: user text on the left, a small page counter on the right. Both dim.
  local eff_footer = slide.footer or global.footer or ""
  local counter = string.format("%d/%d%s ", idx, #state.parsed.slides, #slide.notes > 0 and " ●" or "")
  local left = eff_footer ~= "" and (" " .. eff_footer) or ""
  local gap = math.max(1, width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(counter))
  vim.api.nvim_buf_clear_namespace(state.floats.footer.buf, ns, 0, -1)
  vim.api.nvim_buf_set_lines(state.floats.footer.buf, 0, -1, false, { left .. string.rep(" ", gap) .. counter })
  dim_line(state.floats.footer.buf, 0)
end

--- Restore editor options and close every presentation float. Idempotent.
function M.end_presentation()
  if not state.active then
    return
  end
  state.active = false
  for option, cfg in pairs(state.restore) do
    pcall(function()
      vim.opt[option] = cfg.original
    end)
  end
  M.foreach_float(function(_, float)
    pcall(vim.api.nvim_win_close, float.win, true)
  end)
  state.floats = {}
end

return M
