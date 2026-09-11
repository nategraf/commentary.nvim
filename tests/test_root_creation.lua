local state = require("commentary.state")
local T = MiniTest.new_set()

for _, name in ipairs({ "file", "memory" }) do
  T[name .. " root is created once with its final thread ID"] = function()
    local directory = vim.fn.tempname()
    local storage = require("commentary.storage." .. name)
    state._reset()
    require("commentary.storage.memory")._reset()
    require("commentary.config").setup({ comment = { storage = { backend = name, file = { dir = directory } } } })
    state.init()
    local add, delete = storage.add, storage.delete
    local additions, deletions = 0, 0
    storage.add = function(data) additions = additions + 1; return add(data) end
    storage.delete = function(id) deletions = deletions + 1; return delete(id) end
    local ok, err = pcall(function()
      local id = state.add_comment({ file = "example.lua", line_start = 1, line_end = 1, comment = "Root" })
      MiniTest.expect.equality(state.get_comment(id).thread_id, id .. "_thread")
      MiniTest.expect.equality(additions, 1)
      MiniTest.expect.equality(deletions, 0)
      state.add_reply(id, "Reply")
      MiniTest.expect.equality(#state.get_thread_comments(id .. "_thread"), 2)
    end)
    storage.add, storage.delete = add, delete
    state._reset()
    vim.fn.delete(directory, "rf")
    assert(ok, err)
  end
end

return T
