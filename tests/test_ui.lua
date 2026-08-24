local ui = require("code-review.ui")

require("code-review.config").setup({})

local T = MiniTest.new_set()

local function buffer_mapping(bufnr, lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if mapping.lhs == lhs then
      return mapping
    end
  end
end

T["comment views navigate by wrapped screen lines"] = function()
  ui.show_comment_list({
    {
      id = "comment-1",
      file = "example.lua",
      line_start = 1,
      line_end = 1,
      comment = "A comment long enough to wrap in a narrow view",
      author = "Reviewer",
      timestamp = 1,
    },
  })

  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local down = buffer_mapping(buf, "j")
  local up = buffer_mapping(buf, "k")

  MiniTest.expect.equality(vim.wo[win].wrap, true)
  MiniTest.expect.equality(down.rhs, "gj")
  MiniTest.expect.equality(up.rhs, "gk")

  vim.api.nvim_win_close(win, true)
end

return T
