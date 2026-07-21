>// global header/footer, defined above the first slide -> apply to every slide
>hd a hackable markdown slideshow
>ft present.nvim

># present.nvim demo

>// this line is a comment and is never shown
Welcome to the demo deck.

---
This line reveals on the next keypress.

## Reveal via heading
Headings inside a slide reveal too - and show up as content.

Notes: tell them the plugin has no external dependencies

>---
>ft this slide has its own footer
Press `X` on the next slide to run code.

>---

```lua
for i = 1, 3 do
  print("hello " .. i)
end
```

>// end of deck
