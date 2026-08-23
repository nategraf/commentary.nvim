local state = require("code-review.state")
local memory = require("code-review.storage.memory")

require("code-review").setup({
  comment = {
    storage = { backend = "memory" },
  },
})

local original_select = vim.ui.select
local original_notify = vim.notify

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      state._reset()
      memory._reset()
      state.init()
    end,
    post_case = function()
      vim.ui.select = original_select
      vim.notify = original_notify
    end,
  },
})

local function add_comment()
  state.add_comment({
    file = "clear-test.lua",
    line_start = 1,
    line_end = 1,
    comment = "Keep or clear",
  })
end

T["clear requires confirmation"] = function()
  add_comment()
  local prompt = nil
  vim.ui.select = function(items, opts, callback)
    MiniTest.expect.equality(items, { "No", "Yes" })
    prompt = opts.prompt
    callback("No")
  end

  require("code-review").clear()

  MiniTest.expect.match(prompt, "Delete all 1 review comment")
  MiniTest.expect.equality(#state.get_comments(), 1)
end

T["clear deletes comments after confirmation"] = function()
  add_comment()
  vim.ui.select = function(_, _, callback)
    callback("Yes")
  end

  require("code-review").clear()

  MiniTest.expect.equality(#state.get_comments(), 0)
end

T["clear skips confirmation when there are no comments"] = function()
  local notification = nil
  vim.ui.select = function()
    error("confirmation should not open")
  end
  vim.notify = function(message)
    notification = message
  end

  require("code-review").clear()

  MiniTest.expect.equality(notification, "No comments to clear")
end

return T
