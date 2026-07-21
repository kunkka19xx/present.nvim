--- Code-block executors. An executor is `function(block) -> string[]`: it gets a
--- `present.Block` and returns the lines to show in the run overlay.
---
--- Out-of-process languages all share the same shape - dump the block to a
--- scratch file, run something on it, fold stdout/stderr into a report - so that
--- lives in three small helpers below and each language is a two-liner.
local M = {}

--- Append `text` to `out` as separate lines, dropping trailing blanks (a
--- process's final newline would otherwise leave a dangling empty line inside
--- the fenced output block).
local function append(out, text)
  if not text or text == "" then
    return
  end
  local lines = vim.split(text, "\n", { plain = true })
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  vim.list_extend(out, lines)
end

--- Dump `body` to a scratch file and return its path. `suffix` is appended when
--- the tool insists on a real extension (rustc, tsc, ...).
local function scratch_file(body, suffix)
  local path = vim.fn.tempname() .. (suffix or "")
  vim.fn.writefile(vim.split(body, "\n", { plain = true }), path)
  return path
end

--- Run `argv` to completion. Returns exit code, stdout, stderr.
local function capture(argv)
  local proc = vim.system(argv, { text = true }):wait()
  return proc.code, proc.stdout or "", proc.stderr or ""
end

--- Turn a finished process into display lines: stdout always, and on failure an
--- exit banner plus stderr. Takes `capture`'s three returns directly.
local function report(code, stdout, stderr)
  local out = {}
  append(out, stdout)
  if code ~= 0 then
    if #out > 0 then
      table.insert(out, "")
    end
    table.insert(out, string.format("-- exited %d --", code))
    append(out, stderr)
  end
  return out
end

--- Compile `src` with `env` as its global table, across Lua versions: LuaJIT
--- (what Neovim ships) needs setfenv, 5.2+ takes the env as a load() argument.
local function compile_with_env(src, env)
  if _G.setfenv then
    local chunk, err = loadstring(src, "@present-block")
    if chunk then
      _G.setfenv(chunk, env)
    end
    return chunk, err
  end
  return load(src, "@present-block", "t", env)
end

--- Run a lua block in-process. The chunk gets its own globals table whose
--- `print` collects into a buffer, with reads falling through to the real `_G`.
--- Sandboxing the environment (rather than swapping the global `print` and
--- putting it back) means a block that errors midway can't leave the editor's
--- own `print` broken, and nested runs stay independent.
---@param block present.Block
---@return string[]
function M.lua(block)
  local collected = {}
  local env = setmetatable({
    print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do
        parts[i] = tostring((select(i, ...)))
      end
      append(collected, table.concat(parts, "\t"))
    end,
  }, { __index = _G })

  local chunk, compile_err = compile_with_env(block.body, env)
  if not chunk then
    return { "-- compile error --", tostring(compile_err) }
  end

  local ok, run_err = pcall(chunk)
  if not ok then
    if #collected > 0 then
      table.insert(collected, "")
    end
    table.insert(collected, "-- runtime error --")
    append(collected, tostring(run_err))
  end
  return collected
end

--- Build an executor that runs `program` against the block's scratch file.
--- `ext` (optional) forces a file extension for tools that require one.
---@param program string
---@param ext string?
---@return fun(block: present.Block): string[]
function M.create_system_executor(program, ext)
  return function(block)
    return report(capture({ program, scratch_file(block.body, ext) }))
  end
end

--- Rust: compile to a scratch binary, then run it. Compiler diagnostics are
--- worth more than a bare exit code, so a failed build reports stderr on its own.
---@param block present.Block
---@return string[]
function M.rust(block)
  local src = scratch_file(block.body, ".rs")
  local binary = vim.fn.tempname()
  local code, _, stderr = capture({ "rustc", src, "-o", binary })
  if code ~= 0 then
    local out = { "-- rustc failed --" }
    append(out, stderr)
    return out
  end
  return report(capture({ binary }))
end

--- Go: `go run` handles the compile-and-execute round trip itself.
---@param block present.Block
---@return string[]
function M.go(block)
  return report(capture({ "go", "run", scratch_file(block.body, ".go") }))
end

return M
