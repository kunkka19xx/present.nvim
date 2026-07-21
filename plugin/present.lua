-- Registers the :PresentStart command. Cheap: the module is only required
-- when the command actually runs, so this is safe to load eagerly.
if vim.g.loaded_present then
  return
end
vim.g.loaded_present = true

vim.api.nvim_create_user_command("PresentStart", function()
  require("present").start_presentation { bufnr = 0 }
end, { desc = "Start the markdown presentation for the current buffer" })
