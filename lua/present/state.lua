--- Shared runtime state for an active presentation. A single mutable table so
--- every module reads/writes the same floats, current slide, etc.
return {
  parsed = { slides = {}, global = {} },
  current_slide = 1,
  floats = {}, -- name -> { buf, win }
  source_buf = nil, -- buffer the deck was started from (for hot reload)
  title = "", -- deck file name (unused in chrome, kept for reference)
  active = false,
  banner = false, -- whether a top header line is reserved for the deck
  restore = {}, -- editor options saved on start, restored on teardown
}
