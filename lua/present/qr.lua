--- QR rendering for `>qr <text>` slides. The parser leaves a `\1qr:<text>`
--- sentinel line (staying pure); this module expands it to terminal QR art by
--- shelling out to `qrencode`, cached per text. Degrades to the raw text plus an
--- install hint when qrencode is missing, so a deck never breaks over it.
local M = {}

local SENTINEL = "^\1qr:(.*)$"
local cache = {} -- text -> string[] (rendered lines)

--- Render `text` to QR art lines (cached). Falls back to a readable stand-in
--- when qrencode is unavailable.
---@param text string
---@return string[]
function M.generate(text)
  if cache[text] then
    return cache[text]
  end
  local lines
  if vim.fn.executable("qrencode") == 1 then
    -- `-t UTF8` packs two QR rows per text line with half-block glyphs; an EVEN
    -- margin (`-m 2`) makes the first data row land on a glyph's top half, so the
    -- top edge renders full instead of as a thin, clipped-looking lower half.
    local result = vim.system({ "qrencode", "-t", "UTF8", "-m", "2", text }, { text = true }):wait()
    if result.code == 0 and result.stdout and #result.stdout > 0 then
      lines = vim.split(result.stdout:gsub("\n$", ""), "\n")
      table.insert(lines, "")
      table.insert(lines, text) -- show the encoded value under the code
    end
  end
  if not lines then
    lines = { text, "", "(install `qrencode` to render this as a QR code)" }
  end
  cache[text] = lines
  return lines
end

--- Replace any `\1qr:` sentinel line in every slide's body with rendered QR art.
--- Safe to call repeatedly (renders are cached); mutates the slides in place.
---@param slides present.Slide[]
function M.expand(slides)
  for _, slide in ipairs(slides) do
    local out = {}
    for _, line in ipairs(slide.body) do
      local text = line:match(SENTINEL)
      if text then
        vim.list_extend(out, M.generate(text))
      else
        table.insert(out, line)
      end
    end
    slide.body = out
  end
end

return M
