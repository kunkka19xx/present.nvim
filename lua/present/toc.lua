--- Table of contents. One entry per *logical* slide, shared by the `o` overview
--- popup and the in-deck `>toc` directive so both agree on what the deck's
--- outline is.
---
--- The flat slide list is not that outline: a reveal step is its own slide, and
--- so is every `>---` page, which means one titled section can span half a dozen
--- indices all repeating the same title. `entries` folds those back together.
local config = require("present.config")
local ui = require("present.ui")

local M = {}

local SENTINEL = "^\1toc$"

---@class present.TocEntry
---@field index integer  First slide index of the entry (the jump target)
---@field last integer   Last slide index it covers (== index when it's one page)
---@field title string   Slide title, "" when untitled
---@field summary string First meaningful body line, for untitled entries

--- Collapse the slide list into outline entries.
---
--- A slide continues the previous entry when it belongs to the same reveal
--- `group`, or when it carries the same sticky title (`>---` pages inherit the
--- title of the `>#` that opened the section). Anything else starts a new entry.
---@param slides present.Slide[]
---@return present.TocEntry[]
function M.entries(slides)
  local entries = {}
  for i, slide in ipairs(slides) do
    local title = slide.title or ""
    local prev = entries[#entries]
    local continues = prev ~= nil and (prev.group == slide.group or (title ~= "" and prev.title == title))
    if continues then
      prev.last = i
    else
      table.insert(entries, {
        index = i,
        last = i,
        title = title,
        group = slide.group,
        summary = slide.summary or "",
      })
    end
  end
  return entries
end

--- Which entry slide `idx` falls inside, as an index into `entries`.
---@param entries present.TocEntry[]
---@param idx integer
---@return integer
function M.entry_at(entries, idx)
  for n, entry in ipairs(entries) do
    if idx >= entry.index and idx <= entry.last then
      return n
    end
  end
  return 1
end

--- The section names a contents slide lists: every titled section except the one
--- the list itself sits on (an agenda that lists itself is just noise). Untitled
--- sections have no name to print, so they are left out too.
---@param entries present.TocEntry[]
---@param self_slide integer?  Index of the slide holding the list, if any
---@return string[]
local function listed_titles(entries, self_slide)
  local titles = {}
  for _, entry in ipairs(entries) do
    local is_self = self_slide ~= nil and self_slide >= entry.index and self_slide <= entry.last
    if entry.title ~= "" and not is_self then
      table.insert(titles, entry.title)
    end
  end
  return titles
end

-- How much room a contents slide really has. The body float does not scroll (the
-- cursor is pinned to its first line), so a list longer than this is not just
-- ugly, it is *invisible* - hence the columns and pages below. Measured off the
-- same geometry `ui` lays out, assuming the worst case (a banner row and a title
-- box) and reserving the top padding row.
local function body_size()
  local body = ui.window_configurations(true, true).body
  return math.max(1, body.height - 1), math.max(20, body.width)
end

local COLUMN_GAP = 4

-- One page of the list, `columns` wide. Single column keeps real markdown
-- bullets; multiple columns switch to a plain glyph, because render-markdown only
-- turns the FIRST `- ` on a line into a bullet and the rest would stay dashes.
-- Filled column-major so the reading order is down, then across.
local function page_lines(titles, rows, columns, width)
  if columns == 1 then
    local out = {}
    for _, title in ipairs(titles) do
      table.insert(out, "- " .. ui.truncate(title, width - 2))
    end
    return out
  end
  local col_width = math.floor((width - COLUMN_GAP * (columns - 1)) / columns)
  local used = math.min(rows, math.ceil(#titles / columns))
  local out = {}
  for row = 1, used do
    local cells = {}
    for col = 1, columns do
      local title = titles[(col - 1) * used + row]
      if title then
        local cell = "· " .. ui.truncate(title, col_width - 2)
        if col < columns then -- pad so the next column starts on its own edge
          cell = cell .. string.rep(" ", math.max(0, col_width - vim.fn.strdisplaywidth(cell)))
        end
        table.insert(cells, cell)
      end
    end
    table.insert(out, (table.concat(cells, string.rep(" ", COLUMN_GAP)):gsub("%s+$", "")))
  end
  return out
end

-- Rows, width, and the column count to lay `titles` out in: widen before
-- paginating, since one dense page beats flipping through several. Past three
-- columns titles get clipped too hard to read, which is what `max_columns`
-- guards - set it to 1 to keep the list a plain single column always.
local function shape(titles)
  local rows, width = body_size()
  local cap = math.max(1, config.options.toc.max_columns or 1)
  return rows, width, math.min(cap, math.max(1, math.ceil(#titles / rows)))
end

--- Lay `titles` out as contents pages that each fit on a slide. Only a list too
--- long for `max_columns` columns spills onto a second page.
---@param titles string[]
---@return string[][]  One entry per page, each a list of body lines
function M.pages(titles)
  if #titles == 0 then
    return {}
  end
  local rows, width, columns = shape(titles)
  local per_page = rows * columns
  local pages = {}
  for start = 1, #titles, per_page do
    local slice = vim.list_slice(titles, start, math.min(start + per_page - 1, #titles))
    table.insert(pages, page_lines(slice, rows, columns, width))
  end
  return pages
end

--- Lay `titles` out on exactly one slide, for a `>toc` that has to render where
--- the author put it. A list too long even in columns keeps what fits and says
--- how much it left out - two rows are given up to make room for saying so, since
--- a note pushed off the bottom edge would be no better than the silence it
--- replaces.
---@param titles string[]
---@return string[]
function M.single(titles)
  if #titles == 0 then
    return {}
  end
  local rows, width, columns = shape(titles)
  if #titles <= rows * columns then
    return page_lines(titles, rows, columns, width)
  end
  local room = math.max(1, rows - 2)
  local keep = room * columns
  local lines = page_lines(vim.list_slice(titles, 1, keep), room, columns, width)
  table.insert(lines, "")
  table.insert(lines, string.format("*... and %d more*", #titles - keep))
  return lines
end

--- True when the author placed a `>toc` themselves, anywhere in the deck.
---@param slides present.Slide[]
---@return boolean
function M.has_marker(slides)
  for _, slide in ipairs(slides) do
    for _, line in ipairs(slide.body) do
      if line:match(SENTINEL) then
        return true
      end
    end
  end
  return false
end

--- Add a contents slide to the deck without the author asking for one.
---
--- Skipped when the deck already has an explicit `>toc` (that placement wins),
--- and when the deck has fewer titled sections than `min_sections` - a contents
--- page for a three-slide deck is worse than none.
---
--- `after` names a slide index, but the slide lands on a *section* boundary: the
--- indices it names may be mid-reveal-group, and inserting there would split a
--- group whose snapshots have to stay contiguous.
---
--- A deck with more sections than fit on one slide gets several contents slides,
--- numbered `(1/2)`, `(2/2)`, ... in the title.
---@param slides present.Slide[]
---@param opts present.Toc
function M.insert_auto(slides, opts)
  if not opts or not opts.auto or M.has_marker(slides) then
    return
  end
  local entries = M.entries(slides)
  local titles = listed_titles(entries, nil)
  if #titles < (opts.min_sections or 0) then
    return
  end
  local pages = M.pages(titles)

  local at = 0
  local after = math.min(opts.after or 0, #slides)
  if after > 0 then
    at = entries[M.entry_at(entries, after)].last
  end

  -- Every page gets its own reveal group, past every existing one, so `measure`
  -- can neither anchor a page to a neighbour's height nor mistake the next page
  -- for a reveal of the last (which the spotlight would dim).
  local group = 0
  for _, slide in ipairs(slides) do
    group = math.max(group, slide.group or 0)
  end

  local base = opts.title or "Contents"
  for page, body in ipairs(pages) do
    local title = base
    if #pages > 1 then
      title = string.format("%s (%d/%d)", base, page, #pages)
    end
    table.insert(slides, at + page, {
      title = title,
      body = body,
      blocks = {},
      notes = {},
      summary = "",
      group = group + page,
    })
  end
end

--- Replace every `\1toc` sentinel line with the deck's contents list. Mutates
--- the slides in place; safe to call repeatedly.
---
--- Unlike the automatic slide this cannot paginate - the marker sits inside a
--- slide the author wrote, and adding slides around it would move their deck
--- about. So a list too long even in columns keeps the first page and admits to
--- the rest rather than clipping them off-screen in silence.
---@param slides present.Slide[]
function M.expand(slides)
  local entries = M.entries(slides)
  for i, slide in ipairs(slides) do
    local out = {}
    for _, line in ipairs(slide.body) do
      if line:match(SENTINEL) then
        vim.list_extend(out, M.single(listed_titles(entries, i)))
      else
        table.insert(out, line)
      end
    end
    slide.body = out
  end
end

return M
