# present.nvim

A minimal, hackable markdown slideshow for Neovim. Present a markdown buffer
directly in floating windows - no external tooling, no build step.

Originally inspired by [tjdevries/present.nvim](https://github.com/tjdevries/present.nvim),
rewritten with a clearer, easier-to-type separator design and more features:

https://github.com/user-attachments/assets/2211f408-67e5-402c-80b4-a59e7e93bc1a

- `>`-prefixed markers that never collide with the markdown you render
- in-slide **reveals** that grow downward (no jumping)
- **sticky titles** and configurable **header / footer** text
- **callout boxes** (`>!note`, `>!tip`, `>!warning`, ...)
- **QR code** slides (`>qr <text>`) rendered right in the terminal
- **images** (`>img <path>`) - true terminal graphics, cell art everywhere else
- **spotlight** reveals - dim earlier chunks so the newest one stands out
- **hot reload** - edit the source, save, and the slide updates in place
- **run** code blocks live (lua, js, ts, python, bash, sh, go, rust, or your own)
- **fuzzy search** with a preview pane, a slide **picker**, and **speaker notes**
- every marker is **configurable**

## Separators

The rule is simple: **a `>` prefix is a slide-level directive, no prefix is
in-slide.**

| Marker (own line) | Meaning |
| --- | --- |
| `># Title` (also `>##`, `>###`) | new slide, with a title |
| `>---` | new slide, keeps the current title |
| `>#` (bare) | new slide, clears the title (no title box) |
| `---` | in-slide reveal - the next chunk appears on the next keypress |
| `#` / `##` / ... heading | in-slide reveal (the heading is shown as content) |
| `>hd <text>` | header text, shown dim above the title (outside the box) |
| `>ft <text>` | footer text, shown dim along the bottom |
| `>// ...` | comment - dropped, never shown |
| `>!note <text>` | callout box (`note` / `tip` / `warning` / `important` / ...) |
| `>qr <text>` | render `<text>` (e.g. a URL) as a QR code on the slide |
| `>img <path> [w]` | render an image file, `w` cells wide (default 40) |
| `Notes: ...` | speaker note - shown with `s`, never on the slide |

- **Sticky titles:** a `>#` title stays in the header across in-slide reveals and
  `>---` pages until the next `>#` changes it. A bare `>#` (no text) clears it.
- **Untitled slides:** a slide with no title drops the rounded title box entirely
  rather than showing an empty one, and its body claims those three rows. Reveal
  steps always share their slide's title, so this never shifts the body mid-reveal.
- **Header / footer scope:** `>hd` / `>ft` placed **above the first slide** are
  global (every slide); placed **inside a slide** they override just that slide.
  There is no fixed hint bar - the footer is yours (a small `page/total` counter
  sits at the far right).
- **Callouts:** `>!<type> <text>` opens a callout box. The type is any keyword
  (`note`, `tip`, `warning`, `important`, `caution`, ...); the box keeps absorbing
  lines until a **blank line** closes it. Rendering (border + colored icon) is
  provided by [`render-markdown.nvim`](https://github.com/MeanderingProgrammer/render-markdown.nvim);
  the icon needs a Nerd Font.

### Example

```markdown
>hd a hackable slideshow          <!-- global header, all slides -->
>ft present.nvim

># Welcome
This appears first.

---
This appears on the next keypress (in-slide reveal).

## A sub-point
This heading reveals too, and is shown as content.

>// a private note-to-self, never rendered
Notes: remember to breathe

>!tip A callout box - runs until the next blank line.

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
| `r` | reload from the source buffer (also automatic on `:w`) |
| `?` | help |
| `q` | quit (asks for confirmation, `y`/`n`) |

## Install

No dependencies. Optional: [`fzf-lua`](https://github.com/ibhagwan/fzf-lua) for
the `/` search preview pane (falls back to `vim.ui.select` without it).

**lazy.nvim**

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

**packer.nvim**

```lua
use {
  "kunkka19xx/present.nvim",
  cmd = "PresentStart", -- optional lazy-load
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
    callout     = ">!",       -- prefix: callout box, e.g. `>!note text`
    qr          = ">qr",      -- prefix: render the rest of the line as a QR code
    image       = ">img",     -- prefix: render an image, `>img <path> [width]`
    notes       = "Notes:",   -- prefix: speaker note (shown with `s`)
    reveal_on_heading = true, -- also treat plain markdown headings as reveals
  },
  center_vertical = false,        -- false: flow from the top; true: center the
                                  -- body (anchored so reveals grow downward)
  top_padding = 1,                -- blank lines above the body when not centering
  spotlight = false,              -- true: dim already-revealed chunks so the
                                  -- newest reveal stands out
  image = {
    backend = "auto",             -- "auto" probes the terminal; force with
                                  -- "kitty" / "chafa", or "off" for a stand-in
    width = 40,                   -- default width in cells (`>img p.png 60` wins)
    max_height = 0,               -- cap the height in cells, 0 = uncapped
    cell_aspect = 2.0,            -- cell height / width; raise if images squash
  },
  executors = {
    -- language = function(block) return { "output", "lines" } end
    -- built in: lua, javascript, typescript, python, bash, sh, go, rust
  },
}
```

> **Choosing custom markers.** Markers are matched **literally** at the start of a
> line (`slide_break`/`reveal` must be the *whole* line; the rest are line
> prefixes). Pick tokens that **cannot collide** with prose you write or markdown
> you render - avoid bare `#` (heading), `>` alone (blockquote), `-`/`*` (list or
> rule), and `` ` `` (code). The defaults use a `>`+non-space prefix on purpose,
> since that's not valid markdown or normal prose. Also make sure a marker can't
> appear as literal slide content.

## Code execution

Put a fenced code block on a slide and press `X` (first block) or `A` (all
blocks). Output opens in an overlay; the presentation stays running underneath.
Add languages by supplying an executor:

```lua
require("present").setup {
  executors = {
    deno = require("present").create_system_executor("deno", ".ts"),
    ruby = require("present").create_system_executor("ruby"),
  },
}
```

`create_system_executor(program, ext?)` writes the block to a temp file and runs
`program` on it. For full control, an executor is just
`function(block) -> string[]` (see `lua/present/executors.lua`).

## Hot reload

While a presentation is running, saving the source buffer (`:w`) re-parses the
deck and re-renders the current slide in place - no need to quit and restart.
Press `r` to reload manually. Your position is kept (clamped if the slide count
shrank), so tweak wording, save, and watch it update. (Adding or removing a
`>hd` header after start won't re-lay-out the top banner - restart for that.)

## QR codes

`>qr <text>` renders the text (usually a URL) as a scannable QR code right in the
terminal - no image protocol needed. It shells out to
[`qrencode`](https://fukuchi.org/works/qrencode/) (`-t UTF8`), so install that
first (`brew install qrencode`, `nix profile install nixpkgs#qrencode`, ...).
Renders are cached, and if `qrencode` is missing the slide simply shows the text
plus an install hint instead of breaking.

```markdown
># Scan me
>qr https://github.com/kunkka19xx/present.nvim
```

## Images

`>img <path> [width]` puts a picture on the slide. The path is resolved relative
to **the deck file**, so a deck travels with its assets, and `width` is in
terminal cells (default 40; the height follows the image's aspect ratio).

```markdown
># Architecture
>img diagrams/pipeline.png 60
```

### What you need to install

Nothing, if you only want cell art in a terminal that already has `chafa`. The
table below is the whole dependency story - `>img` is the only feature in this
plugin with external requirements, and it degrades instead of failing.

| You want | You need | Install |
| --- | --- | --- |
| **Real images** | kitty **0.28+** or **Ghostty** | already have it, or `brew install --cask ghostty` |
| **Cell art** (anywhere else) | [`chafa`](https://hpjansson.org/chafa/) | `brew install chafa` · `apt install chafa` · `dnf install chafa` · `pacman -S chafa` · `nix profile install nixpkgs#chafa` |
| Nothing installed | - | the slide shows `[image: path]` and the deck runs fine |

**Only kitty and Ghostty render real images here.** That is narrower than the
list of terminals supporting the kitty graphics protocol, because this plugin
uses *unicode placeholders*, a separate part of the spec. WezTerm speaks the
graphics protocol fluently but does **not** implement placeholders (checked by
hand: you get a block of tofu, not a picture); iTerm2 and Konsole are the same.
Those terminals get `chafa` instead - which is the right outcome, so don't force
`backend = "kitty"` there.

One editor setting is also required, because the placeholder cells carry the
image id as an exact 24-bit foreground color:

```lua
vim.o.termguicolors = true
```

Without it (or, under tmux, without the setting in the next section) `auto`
quietly falls back to `chafa` rather than drawing something broken.

### If you use tmux

tmux is fully supported - that is *why* this plugin uses unicode placeholders
rather than painting pixels over the terminal. You need **tmux 3.3 or newer**
(`tmux -V`) and one line in `~/.tmux.conf`:

```tmux
set -g allow-passthrough on
```

It is **off by default**, and without it tmux swallows the graphics escapes
instead of forwarding them to the terminal. After adding it, reload with
`tmux source-file ~/.tmux.conf`; if tmux was already running you may need to
restart the server (`tmux kill-server`) for a stale value to clear.

Check what you have:

```sh
tmux -V                              # need 3.3+
tmux show -gv allow-passthrough      # want: on
```

tmux 3.4+ also accepts `all`, which additionally allows passthrough from panes
that aren't currently visible. `on` is enough here, since a deck transmits its
images while you're looking at it.

Two things that are *not* required, but often assumed to be: you do **not** need
to change `default-terminal`, and you do **not** need a terminal-specific
`terminal-overrides` entry. Placeholder cells are ordinary text as far as tmux is
concerned, so it tracks and redraws them correctly with no extra help.

### How it works, and why

The `kitty` path hands the image to the terminal once, then the slide holds
ordinary text cells (`U+10EEEE`, the row as a combining diacritic, the image id
as the foreground color) that the terminal paints over. Because they are real
buffer lines, the image flows through the normal render path and picks up
`top_padding`, reveals and spotlight for free - and tmux tracks them as text, so
there is no smearing and no re-emit-on-redraw hack.

Only PNGs take that path; every other format (jpeg, gif, webp, ...) is decoded by
`chafa`. Renders are cached per file, size and modification time, so hot reload
picks up an image you edited outside the editor.

Force a renderer with `image.backend` if `auto` guesses wrong:

```lua
require("present").setup { image = { backend = "chafa" } }  -- or "kitty" / "off"
```

## Spotlight

With `spotlight = true`, each reveal step dims the chunks that were already on
screen so the newest one is the bright, focused line - attention follows you down
the slide instead of the audience reading ahead. Off by default; it only affects
in-slide reveals (`---` / headings), not standalone slides.

## Project layout

The code is small and split by concern so it stays easy to hack on:

| File | Responsibility |
| --- | --- |
| `lua/present/init.lua` | public API, keymaps, lifecycle |
| `lua/present/config.lua` | defaults + `setup()` |
| `lua/present/parser.lua` | markdown -> slides (pure, testable) |
| `lua/present/executors.lua` | code-block runners |
| `lua/present/qr.lua` | `>qr` rendering via qrencode (cached) |
| `lua/present/image.lua` | `>img` rendering (kitty graphics / chafa, cached) |
| `lua/present/state.lua` | shared runtime state |
| `lua/present/ui.lua` | floating windows + slide rendering |
| `lua/present/overlays.lua` | picker, search, notes, run, help, confirm |
| `plugin/present.lua` | registers `:PresentStart` |

`require("present")._parse_slides(lines)` returns the parsed slide table, handy
for testing the parser in isolation.

