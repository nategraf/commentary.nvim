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

T["comment input supports write and write-quit"] = function()
  local saved = {}
  ui.show_comment_input(function(text)
    table.insert(saved, text)
    return true
  end, nil, nil, "First draft")
  vim.cmd("stopinsert")

  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  MiniTest.expect.equality(vim.bo[buf].buftype, "acwrite")

  vim.cmd("write")
  MiniTest.expect.equality(saved, { "First draft" })
  MiniTest.expect.equality(vim.api.nvim_win_is_valid(win), true)
  MiniTest.expect.equality(vim.bo[buf].modified, false)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Second draft" })
  vim.cmd("wq")
  MiniTest.expect.equality(saved, { "First draft", "Second draft" })
  MiniTest.expect.equality(vim.api.nvim_win_is_valid(win), false)
end

T["comment input allows quit to discard changes"] = function()
  local saved = false
  ui.show_comment_input(function()
    saved = true
    return true
  end, nil, nil, "Draft")
  vim.cmd("stopinsert")

  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Discarded draft" })
  vim.cmd("q")

  MiniTest.expect.equality(saved, false)
  MiniTest.expect.equality(vim.api.nvim_win_is_valid(win), false)
end

T["comment input file navigation returns focus to the float"] = function()
  local path = vim.fn.tempname()
  vim.fn.writefile({ "target" }, path)
  local swapfile = vim.o.swapfile
  vim.o.swapfile = false

  ui.show_comment_input(function()
    return true
  end, nil, nil, path)
  vim.cmd("stopinsert")

  local comment_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(comment_win, { 1, 0 })

  for _, lhs in ipairs({ "gf", "<C-W>f" }) do
    local mapping = buffer_mapping(buf, lhs)
    MiniTest.expect.equality(mapping ~= nil, true)
    mapping.callback()

    local file_win = vim.api.nvim_get_current_win()
    MiniTest.expect.equality(file_win ~= comment_win, true)
    MiniTest.expect.equality(vim.api.nvim_buf_get_name(0), path)
    vim.api.nvim_win_close(file_win, true)
    vim.wait(100, function()
      return vim.api.nvim_get_current_win() == comment_win
    end)
    MiniTest.expect.equality(vim.api.nvim_get_current_win(), comment_win)
  end

  vim.api.nvim_win_close(comment_win, true)
  vim.o.swapfile = swapfile
  vim.fn.delete(path)
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
