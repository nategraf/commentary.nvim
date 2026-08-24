local memory = require("commentary.storage.memory")
local state = require("commentary.state")
local ui = require("commentary.ui")
local review = require("commentary")

review.setup({
  comment = {
    storage = { backend = "memory" },
  },
})

local original_select = vim.ui.select
local original_show_comment_input = ui.show_comment_input

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      state._reset()
      memory._reset()
      state.init()
    end,
    post_case = function()
      vim.ui.select = original_select
      ui.show_comment_input = original_show_comment_input
    end,
  },
})

local function add_thread()
  local root_id = state.add_comment({
    file = "example.lua",
    line_start = 1,
    line_end = 1,
    comment = "Root comment",
    context_lines = { "local value = 1" },
  })
  local reply_id = state.add_reply(root_id, "Reply comment")
  return state.get_comment(root_id), state.get_comment(reply_id)
end

T["explicit edit targets a reply"] = function()
  local root, reply = add_thread()
  ui.show_comment_input = function(callback, _, _, initial_text)
    MiniTest.expect.equality(initial_text, reply.comment)
    callback("Edited reply")
  end

  review.edit_comment(reply)

  MiniTest.expect.equality(state.get_comment(root.id).comment, "Root comment")
  MiniTest.expect.equality(state.get_comment(reply.id).comment, "Edited reply")
end

T["explicit delete confirms and removes a reply"] = function()
  local root, reply = add_thread()
  vim.ui.select = function(items, opts, callback)
    MiniTest.expect.equality(items, { "Yes", "No" })
    MiniTest.expect.match(opts.prompt, "Reply comment")
    callback("Yes")
  end

  review.delete_comment(reply)

  MiniTest.expect.equality(state.get_comment(root.id).comment, "Root comment")
  MiniTest.expect.equality(state.get_comment(reply.id), nil)
end

T["explicit reply and resolve act on the selected thread"] = function()
  local root, reply = add_thread()
  ui.show_comment_input = function(callback)
    callback("Follow-up reply")
  end

  review.reply_to_comment(reply)
  local comments = state.get_thread_comments(root.thread_id)
  MiniTest.expect.equality(#comments, 3)
  MiniTest.expect.equality(comments[3].comment, "Follow-up reply")

  MiniTest.expect.equality(review.resolve_comment_thread(reply), true)
  MiniTest.expect.equality(state.get_all_threads()[root.thread_id].status, "resolved")
end

return T
