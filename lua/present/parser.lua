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
---@field summary string  First body line as plain prose, for labelling the slide in lists
---@field image_marks table[]?  Extmarks colouring expanded `>img` lines (set by present.image)

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

-- Strip markdown decoration off a body line to get readable prose for a list
-- label. Returns "" for lines that carry no prose at all (a bare callout kind, a
-- rule, decoration only).
local function as_prose(line)
  local t = vim.trim(line)
  t = t:gsub("^>%s*", "") -- blockquote / callout body
  if t:match("^%[!") then -- the `[!NOTE]` marker line itself
    return ""
  end
  t = t:gsub("^#+%s*", "") -- heading
  t = t:gsub("^[-*+]%s+", "") -- bullet
  t = t:gsub("^%d+%.%s+", "") -- ordered item
  t = t:gsub("%[([^%]]*)%]%b()", "%1") -- links -> their text
  t = t:gsub("[`*_]", "") -- inline emphasis / code ticks
  if t:match("^[-=%s]+$") then -- horizontal rule / setext underline
    return ""
  end
  return vim.trim(t)
end

-- First line of `body` that reads as prose, for labelling the slide in the
-- overview and search popups. Table rows are skipped (pipes make terrible
-- labels), and so are the `\1` sentinels - which is why this runs at parse time,
-- while `>qr`/`>img` are still one line each rather than the many lines of art
-- they expand into.
--
-- A slide can legitimately have no prose at all: only a code block, only a
-- picture. Rather than label those with nothing, fall back to the first line of
-- code, then to whatever the sentinel was pointing at.
---@param body string[]
---@return string
local function summarize(body)
  local in_code = false
  local code, media = nil, nil
  for _, line in ipairs(body) do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      in_code = not in_code
    elseif in_code then
      code = code or (vim.trim(line) ~= "" and vim.trim(line) or nil)
    elseif line:sub(1, 1) == "\1" then
      -- `\1img:<path> [w]` -> the file's name; `\1qr:<text>` -> the text.
      local path = line:match("^\1img:(%S+)")
      media = media or (path and vim.fn.fnamemodify(path, ":t")) or line:match("^\1qr:(.*)$")
    elseif not vim.trim(line):match("^|") then
      local prose = as_prose(line)
      if prose ~= "" then
        return prose
      end
    end
  end
  return code or media or ""
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

    -- Image (`>img <path> [width]`) --------------------------------
    -- Same deal as `>qr`: the payload is carried verbatim on a sentinel line and
    -- resolved after parsing, so reading a file / probing the terminal never
    -- happens in here. `present.image` splits the path from the optional width.
    do
      local spec = after_token(raw, S.image)
      if spec ~= nil and spec ~= "" then
        table.insert(current.body, "\1img:" .. spec)
        seen_content = true
        goto continue
      end
    end

    -- Table of contents (`>toc`) ------------------------------------
    -- Another sentinel: the outline depends on slides that may not be parsed
    -- yet, so `present.toc` fills it in once the whole deck is known.
    do
      local toc = after_token(raw, S.toc)
      if toc ~= nil then
        table.insert(current.body, "\1toc")
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
    s.summary = summarize(s.body)
  end

  M.measure(slides.slides)
  return slides
end

--- Recompute the body-length-derived layout fields (`anchor`, `reveal_start`).
--- Both are line counts, so anything that rewrites a body after parsing - the
--- `>qr` and `>img` sentinel expansions, which turn one line into many - has to
--- call this again or the vertical anchor and the spotlight split drift.
---@param list present.Slide[]
function M.measure(list)
  -- Each slide's `anchor` = the tallest body in its reveal group, so every
  -- reveal step keeps the same top offset and grows downward (no jumping).
  local group_max = {}
  for _, s in ipairs(list) do
    group_max[s.group] = math.max(group_max[s.group] or 0, #s.body)
  end
  for _, s in ipairs(list) do
    s.anchor = group_max[s.group]
  end

  -- `reveal_start` = how many leading body lines were already visible on the
  -- PREVIOUS reveal step of the same group. Spotlight dims those so the newest
  -- chunk stands out. Snapshots within a group are ordered and prefix-extending,
  -- so the previous snapshot's length is exactly the dim count.
  local prev_len = {}
  for _, s in ipairs(list) do
    s.reveal_start = prev_len[s.group] or 0
    prev_len[s.group] = #s.body
  end
end

return M
