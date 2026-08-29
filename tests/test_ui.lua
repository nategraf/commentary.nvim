local ui = require("commentary.ui")

require("commentary.config").setup({})

local T = MiniTest.new_set()

local function buffer_mapping(bufnr, lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if mapping.lhs == lhs then
      return mapping
    end
  end
end

local function buffer_mapping_by_description(bufnr, description)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if mapping.desc == description then
      return mapping
    end
  end
end

local function comment(id, text, timestamp, parent_id)
  return {
    id = id,
    thread_id = "thread-1",
    parent_id = parent_id,
    file = "example.lua",
    line_start = 1,
    line_end = 1,
    comment = text,
    author = "Reviewer",
    timestamp = timestamp,
  }
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

T["comment view actions target the threaded comment under the cursor"] = function()
  local review = require("commentary")
  local root = comment("root", "Root comment", 1)
  local reply = comment("reply", "Reply comment", 2, root.id)
  local actions = {
    {
      method = "delete_comment",
      desc = "Delete displayed review comment",
    },
    {
      method = "edit_comment",
      desc = "Edit displayed review comment",
    },
    {
      method = "reply_to_comment",
      desc = "Reply to displayed review comment",
    },
  }

  for _, action in ipairs(actions) do
    local original = review[action.method]
    local selected
    review[action.method] = function(selected_comment)
      selected = selected_comment
    end

    ui.show_comment_list({ root, reply })
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local reply_line
    for index, line in ipairs(lines) do
      if line == reply.comment then
        reply_line = index
        break
      end
    end
    vim.api.nvim_win_set_cursor(win, { reply_line, 0 })

    local mapping = buffer_mapping_by_description(buf, action.desc)
    local invoked, err = pcall(mapping.callback)
    review[action.method] = original

    MiniTest.expect.equality(invoked, true)
    MiniTest.expect.equality(err, nil)
    MiniTest.expect.equality(selected.id, reply.id)
    MiniTest.expect.equality(vim.api.nvim_win_is_valid(win), false)
  end
end

return T
