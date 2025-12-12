local M = {}

local formatter = require("code-review.formatter")

--- Create a custom previewer for Telescope that shows comment content
function M.telescope_comment_previewer()
  local previewers = require("telescope.previewers")

  return previewers.new_buffer_previewer({
    title = "Comment Details",
    get_buffer_by_name = function(_, entry)
      return entry.value.id or tostring(entry.value)
    end,
    define_preview = function(self, entry, status)
      local comment_data = entry.value
      local bufnr = self.state.bufnr

      -- Use formatter for preview (no ANSI for Telescope)
      local lines = formatter.format_single(comment_data)

      -- Make buffer modifiable before setting content
      vim.api.nvim_buf_set_option(bufnr, "modifiable", true)

      -- Set buffer content
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_buf_set_option(bufnr, "filetype", "markdown")

      -- Make it read-only after setting content
      vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
    end,
  })
end

return M
