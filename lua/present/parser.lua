--- Markdown -> slides parser. Pure: give it lines and a syntax table.

---@class present.Block
---@field language string
---@field body string

---@class present.Slide
---@field title string
---@field body string[]
---@field blocks present.Block[]
---@field notes string[]
---@field header string?  Per-slide header text (below the title), overrides global
---@field footer string?  Per-slide footer text, overrides global

---@class present.Slides
---@field slides present.Slide[]
---@field global { header: string?, footer: string? }  Deck-wide header/footer

local M = {}

-- All markers are LITERAL tokens (see present.Syntax), matched two ways:
--   * whole-line : the trimmed line equals the token          (slide_break, reveal)
--   * prefix     : the line starts with the token, remainder = payload
-- Literal matching (rather than user-supplied Lua patterns) keeps custom markers
-- predictable and avoids accidental regex meta-character surprises.

-- Whole trimmed line equals `token`.
local function is_line(raw, token)
  return token and token ~= "" and vim.trim(raw) == token
end

-- Line begins with `token` followed by a space or end-of-line; returns the
-- trimmed remainder (possibly ""), else nil. The boundary stops `>hdx` matching
-- `>hd`. When `allow_repeat` is set, the marker's final char may repeat, so the
-- title marker `>#` also accepts `>##`, `>###`.
local function after_token(raw, token, allow_repeat)
  if not token or token == "" or raw:sub(1, #token) ~= token then
    return nil
  end
  local rest = raw:sub(#token + 1)
  if allow_repeat then
    local last = token:sub(-1)
    rest = rest:gsub("^" .. vim.pesc(last) .. "+", "")
  end
  if rest == "" or rest:match("^%s") then
    return vim.trim(rest)
  end
  return nil
end

--- Parse buffer lines into slides (with reveals expanded to sub-slides).
---@param lines string[]
---@param syntax present.Syntax
---@return present.Slides
function M.parse(lines, syntax)
  local S = syntax
  local slides = { slides = {}, global = { header = nil, footer = nil } }

  local new_slide = function()
    return { title = "", body = {}, blocks = {}, notes = {}, header = nil, footer = nil }
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

  -- A "group" is one logical slide; its reveal snapshots share a group id so
  -- they can all be vertically anchored to the group's fullest state.
  local group = 1
  local current = new_slide()
  current.group = group
  local in_code = false
  local code_lang, code_body = "", {}
  -- A callout (`>!note ...`) opens a render-markdown blockquote that keeps
  -- absorbing following lines until a blank line closes it.
  local in_callout = false

  -- Titles are "sticky": once `>#` sets one it stays in the header across
  -- reveals AND `>---` pages, until the next `>#` changes it.
  local last_title = ""

  -- `>hd` / `>ft` are global while still in the preamble (before any slide or
  -- content), otherwise they attach to the current slide.
  local seen_content = false

  for _, raw in ipairs(lines) do
    local trimmed = (raw:gsub("%s*$", ""))
    local fence = raw:match("^%s*```(%S*)") or raw:match("^%s*~~~(%S*)")

    -- Fenced code blocks -------------------------------------------
    if fence ~= nil then
      seen_content = true
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

    -- Open callout continuation: a blank line closes it, any other line
    -- becomes a quoted body line of the callout box.
    if in_callout then
      if vim.trim(raw) == "" then
        in_callout = false
        table.insert(current.body, "")
      else
        table.insert(current.body, "> " .. trimmed)
        seen_content = true
      end
      goto continue
    end

    -- Callout box (`>!note ...`) -> render-markdown blockquote ------
    do
      local ctok = S.callout
      if ctok and ctok ~= "" and raw:sub(1, #ctok) == ctok then
        local kind, first = raw:sub(#ctok + 1):match("^(%a+)%s*(.*)$")
        if kind then
          table.insert(current.body, "> [!" .. kind:upper() .. "]")
          if first ~= "" then
            table.insert(current.body, "> " .. first)
          end
          in_callout = true
          seen_content = true
          goto continue
        end
      end
    end

    -- QR code (`>qr <text>`) ----------------------------------------
    -- Left as a sentinel line; the impure render (qrencode) is expanded
    -- after parsing so this function stays pure and testable.
    do
      local qr = after_token(raw, S.qr)
      if qr ~= nil and qr ~= "" then
        table.insert(current.body, "\1qr:" .. qr)
        seen_content = true
        goto continue
      end
    end

    -- New slide with a title (`>#`, `>##`, ...) --------------------
    do
      local title = after_token(raw, S.slide, true)
      if title ~= nil then
        push(current)
        group = group + 1
        current = new_slide()
        current.group = group
        last_title = title
        current.title = title
        seen_content = true
        goto continue
      end
    end

    -- New slide, no title (`>---`) ---------------------------------
    if is_line(raw, S.slide_break) then
      push(current)
      group = group + 1
      current = new_slide()
      current.group = group
      current.title = last_title -- carry the title onto the new page
      seen_content = true
      goto continue
    end

    -- Header / footer directives (`>hd` / `>ft`) -------------------
    do
      local hd = after_token(raw, S.header)
      if hd ~= nil then
        if seen_content then
          current.header = hd
        else
          slides.global.header = hd
        end
        goto continue
      end
      local ft = after_token(raw, S.footer)
      if ft ~= nil then
        if seen_content then
          current.footer = ft
        else
          slides.global.footer = ft
        end
        goto continue
      end
    end

    -- Comment (`>//`), dropped -------------------------------------
    if S.comment and S.comment ~= "" and vim.startswith(raw, S.comment) then
      goto continue
    end

    -- Speaker note (`Notes:`) --------------------------------------
    do
      local note = after_token(raw, S.notes)
      if note ~= nil then
        table.insert(current.notes, note)
        goto continue
      end
    end

    -- In-slide reveal (`---`) --------------------------------------
    if is_line(raw, S.reveal) then
      reveal(current) -- the marker itself is not rendered
      goto continue
    end
    -- A plain markdown heading also reveals in-slide (and shows as content).
    if S.reveal_on_heading and raw:match("^#+%s") then
      reveal(current)
      table.insert(current.body, trimmed)
      seen_content = true
      goto continue
    end

    if vim.trim(trimmed) ~= "" then
      seen_content = true
    end
    table.insert(current.body, trimmed)
    ::continue::
  end

  push(current)

  -- Trim leading/trailing blank lines so the top gap is controlled purely by
  -- `top_padding` (and centering isn't thrown off by stray blanks).
  for _, s in ipairs(slides.slides) do
    while #s.body > 0 and vim.trim(s.body[1]) == "" do
      table.remove(s.body, 1)
    end
    while #s.body > 0 and vim.trim(s.body[#s.body]) == "" do
      table.remove(s.body)
    end
  end

  -- Each slide's `anchor` = the tallest body in its reveal group, so every
  -- reveal step keeps the same top offset and grows downward (no jumping).
  local group_max = {}
  for _, s in ipairs(slides.slides) do
    group_max[s.group] = math.max(group_max[s.group] or 0, #s.body)
  end
  for _, s in ipairs(slides.slides) do
    s.anchor = group_max[s.group]
  end

  -- `reveal_start` = how many leading body lines were already visible on the
  -- PREVIOUS reveal step of the same group. Spotlight dims those so the newest
  -- chunk stands out. Snapshots within a group are ordered and prefix-extending,
  -- so the previous snapshot's length is exactly the dim count.
  local prev_len = {}
  for _, s in ipairs(slides.slides) do
    s.reveal_start = prev_len[s.group] or 0
    prev_len[s.group] = #s.body
  end

  return slides
end

return M
