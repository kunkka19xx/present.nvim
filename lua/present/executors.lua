--- Code-block executors. Each takes a `present.Block` and returns output lines.
local M = {}

--- Run lua in-process, capturing print() output.
---@param block present.Block
function M.lua(block)
  local original_print = print
  local output = {}
  print = function(...)
    local args = { ... }
    local message = table.concat(vim.tbl_map(tostring, args), "\t")
    for _, line in ipairs(vim.split(message, "\n")) do
      table.insert(output, line)
    end
  end
  local chunk = loadstring(block.body)
  pcall(function()
    if not chunk then
      table.insert(output, " <<<BROKEN CODE>>>")
    else
      chunk()
    end
  end)
  print = original_print
  return output
end

--- Build an executor that writes the block to a temp file and runs `program`.
--- `ext` (optional) sets the temp-file extension (some tools require one).
function M.create_system_executor(program, ext)
  return function(block)
    local tempfile = vim.fn.tempname() .. (ext or "")
    vim.fn.writefile(vim.split(block.body, "\n"), tempfile)
    local result = vim.system({ program, tempfile }, { text = true }):wait()
    local out = vim.split(result.stdout or "", "\n")
    if result.code ~= 0 and result.stderr and #result.stderr > 0 then
      table.insert(out, "")
      table.insert(out, "-- stderr --")
      vim.list_extend(out, vim.split(result.stderr, "\n"))
    end
    return out
  end
end

--- Compile-then-run executor for Rust.
function M.rust(block)
  local tempfile = vim.fn.tempname() .. ".rs"
  local outputfile = tempfile:sub(1, -4)
  vim.fn.writefile(vim.split(block.body, "\n"), tempfile)
  local result = vim.system({ "rustc", tempfile, "-o", outputfile }, { text = true }):wait()
  if result.code ~= 0 then
    return vim.split(result.stderr, "\n")
  end
  result = vim.system({ outputfile }, { text = true }):wait()
  return vim.split(result.stdout, "\n")
end

--- Compile-then-run executor for Go.
function M.go(block)
  local tempfile = vim.fn.tempname() .. ".go"
  vim.fn.writefile(vim.split(block.body, "\n"), tempfile)
  local result = vim.system({ "go", "run", tempfile }, { text = true }):wait()
  local out = vim.split(result.stdout or "", "\n")
  if result.code ~= 0 and result.stderr and #result.stderr > 0 then
    vim.list_extend(out, vim.split(result.stderr, "\n"))
  end
  return out
end

return M
