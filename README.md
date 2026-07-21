# present.nvim

A minimal, hackable markdown slideshow for Neovim. Present a markdown buffer
directly in floating windows - no external tooling, no build step.

Originally inspired by [tjdevries/present.nvim](https://github.com/tjdevries/present.nvim),
rewritten with a clearer, easier-to-type separator design and more features.

## Separators

The rule is simple: **a `>` prefix is a slide-level directive, no prefix is
in-slide.**

| Marker (own line) | Meaning |
| --- | --- |
| `># Title` (or `>##`, …) | new slide, with a title |
| `>---` | new slide, no title |
| `---` | in-slide reveal - the next chunk appears on the next keypress |
| `#` / `##` / … heading | in-slide reveal (the heading is shown as content) |
| `>hd <text>` | header text, shown dim above the title (outside the box) |
| `>ft <text>` | footer text, shown dim along the bottom |
| `>// ...` | comment - dropped, never shown |
| `Notes: ...` | speaker note - shown with `s`, never on the slide |

`>hd` / `>ft` placed **above the first slide** are global (every slide); placed
**inside a slide** they override just that slide. There is no fixed hint bar -
the footer is yours (a small `page/total` counter sits at the far right).

### Example

```markdown
># Welcome
This appears first.

---
This appears on the next keypress (in-slide reveal).

## A sub-point
This heading reveals too, and is shown as content.

>// this is a private note-to-self, never rendered
Notes: remember to breathe

>---
A brand new slide, with no title.

​```lua
print("press X to run me")
​```
```

## Keys (during a presentation)

| Key | Action |
| --- | --- |
| `n` / `<Space>` / `<Right>` | next |
| `p` / `b` / `<Left>` | previous |
| `gg` / `G` | first / last slide |
| `{count}G` | jump to slide number |
| `/` | fuzzy-search slides with a live preview pane (fzf-lua; falls back to `vim.ui.select`) |
| `o` | slide overview / picker |
| `X` / `A` | run first / all code blocks |
| `s` | toggle speaker notes |
| `?` | help |
| `q` | quit (asks for confirmation, `y`/`n`) |

Titles are **sticky**: a `>#` title stays in the header across in-slide reveals
and `>---` pages until the next `>#` changes it.

## Install (lazy.nvim)

```lua
{
  "kunkka19xx/present.nvim", -- or a local `dir = ...`
  cmd = "PresentStart",
  ft = "markdown",
  config = function()
    require("present").setup {}
  end,
}
```

Then run `:PresentStart` on a markdown buffer.

## Configuration

```lua
require("present").setup {
  -- Every marker is configurable. Values are LITERAL tokens (not patterns).
  syntax = {
    slide       = ">#",       -- prefix: new slide, text after = title (also >##)
    slide_break = ">---",     -- whole line: new slide, no title
    reveal      = "---",      -- whole line: in-slide reveal step
    header      = ">hd",      -- prefix: header text (dim, above the title)
    footer      = ">ft",      -- prefix: footer text (dim, along the bottom)
    comment     = ">//",      -- prefix: line dropped, never shown
    notes       = "Notes:",   -- prefix: speaker note (shown with `s`)
    reveal_on_heading = true, -- also treat plain markdown headings as reveals
  },
  center_vertical = false,        -- false: flow from the top; true: center the
                                  -- body (anchored so reveals grow downward)
  top_padding = 1,                -- blank lines above the body when not centering
  executors = {
    -- language = function(block) return { "output", "lines" } end
    -- built in: lua, javascript, typescript, python, bash, sh, go, rust
  },
}
```

> **⚠️ Choosing custom markers.** Markers are matched **literally** at the start
> of a line (`slide_break`/`reveal` must be the *whole* line; the rest are line
> prefixes). Pick tokens that **cannot collide** with prose you write or markdown
> you render — avoid bare `#` (heading), `>` alone (blockquote), `-`/`*` (list or
> rule), and `` ` `` (code). The defaults use a `>`+non-space prefix on purpose,
> since that's not valid markdown or normal prose. Also make sure a marker can't
> appear as literal slide content.

## Code execution

Put a fenced code block on a slide and press `X` (first block) or `A` (all
blocks). Output opens in an overlay; the presentation stays running underneath.
Add languages by supplying an executor - `require("present").create_system_executor("deno", ".ts")`
builds one that writes the block to a temp file and runs a program on it.
