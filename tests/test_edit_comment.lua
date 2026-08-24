local state = require("commentary.state")
local memory = require("commentary.storage.memory")
local ui = require("commentary.ui")
local utils = require("commentary.utils")

require("commentary").setup({
  comment = {
    storage = { backend = "memory" },
  },
})

local T = nil
local original_select = vim.ui.select
local original_show_comment_input = ui.show_comment_input
local test_buf = nil

T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      state._reset()
      memory._reset()
      state.init()
      state.clear()

      test_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(test_buf, vim.fn.getcwd() .. "/edit-comment-test.lua")
      vim.api.nvim_buf_set_lines(test_buf, 0, -1, false, { "first", "second", "third" })
      vim.api.nvim_set_current_buf(test_buf)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
    end,
    post_case = function()
      vim.ui.select = original_select
      ui.show_comment_input = original_show_comment_input
      if test_buf and vim.api.nvim_buf_is_valid(test_buf) then
        vim.api.nvim_buf_delete(test_buf, { force = true })
      end
    end,
  },
})

local function add_root(text)
  return state.add_comment({
    file = utils.normalize_path(vim.api.nvim_buf_get_name(test_buf)),
    line_start = 2,
    line_end = 2,
    comment = text,
    context_lines = { "second" },
  })
end

T["default keymap and command are registered"] = function()
  MiniTest.expect.equality(require("commentary.config").get("keymaps.edit_comment").key, "<leader>re")
  MiniTest.expect.equality(vim.fn.exists(":CommentaryEditComment"), 2)
end

T["edits a single comment without opening a picker"] = function()
  local root_id = add_root("Original text")

  vim.ui.select = function()
    error("single-comment editing should not open a picker")
  end
  ui.show_comment_input = function(callback, context, title, initial_text)
    MiniTest.expect.equality(initial_text, "Original text")
    MiniTest.expect.equality(context.line_start, 2)
    MiniTest.expect.match(title, "Edit Comment")
    callback("Updated text")
  end

  require("commentary").edit_comment_at_cursor()
  MiniTest.expect.equality(state.get_comment(root_id).comment, "Updated text")
end

T["selects which comment in a thread to edit"] = function()
  local root_id = add_root("Root comment")
  local reply_id = state.add_reply(root_id, "Reply comment")
  local picker_opened = false

  vim.ui.select = function(items, opts, callback)
    picker_opened = true
    MiniTest.expect.equality(#items, 2)
    MiniTest.expect.match(opts.prompt, "edit")
    MiniTest.expect.match(opts.format_item(items[2]), "Reply comment")
    callback(items[2])
  end
  ui.show_comment_input = function(callback, _, _, initial_text)
    MiniTest.expect.equality(initial_text, "Reply comment")
    callback("Edited reply")
  end

  require("commentary").edit_comment_at_cursor()

  MiniTest.expect.equality(picker_opened, true)
  MiniTest.expect.equality(state.get_comment(root_id).comment, "Root comment")
  MiniTest.expect.equality(state.get_comment(reply_id).comment, "Edited reply")
end

return T
