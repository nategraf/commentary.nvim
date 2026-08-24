local M = {}

local formatter = require("commentary.formatter")

local function enable_wrapping(previewer)
  local winid = previewer.state and previewer.state.winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true
  vim.wo[winid].breakindent = true
end

--- Format a thread for picker previews.
---@param thread_info table Thread list entry with data and status fields
---@return string[] lines
function M.format_thread(thread_info)
  local root = thread_info.data.root_comment
  local comments = { root }
  vim.list_extend(comments, thread_info.data.replies or {})

  local lines = {
    "# Thread Overview",
    "",
    string.format("**Status**: %s", thread_info.status),
    string.format("**File**: %s", root.file),
    string.format("**Line**: %d", root.line_start),
    string.format("**Comments**: %d", #comments),
    "",
    "---",
    "",
  }

  for index, comment in ipairs(comments) do
    table.insert(lines, string.format("## Comment %d", index))
    table.insert(lines, "")
    vim.list_extend(lines, formatter.format_single(comment))
    if index < #comments then
      vim.list_extend(lines, { "", "---", "" })
    end
  end

  return lines
end

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
      enable_wrapping(self)

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

--- Create a Telescope previewer that shows an entire comment thread.
function M.telescope_thread_previewer()
  local previewers = require("telescope.previewers")

  return previewers.new_buffer_previewer({
    title = "Thread Details",
    get_buffer_by_name = function(_, entry)
      return entry.value.id or tostring(entry.value)
    end,
    define_preview = function(self, entry, status)
      local bufnr = self.state.bufnr
      local lines = M.format_thread(entry.value)
      enable_wrapping(self)

      vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_set_option_value("filetype", "markdown", { buf = bufnr })
      vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
    end,
  })
end

M._enable_wrapping = enable_wrapping

return M
