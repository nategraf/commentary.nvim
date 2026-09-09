local config = require("commentary.config")
local state = require("commentary.state")
local memory = require("commentary.storage.memory")
local T = MiniTest.new_set()

for _, backend in ipairs({ "memory", "file" }) do
  T["reattachment preserves a complete " .. backend .. " thread"] = function()
    local directory = vim.fn.tempname()
    vim.fn.mkdir(directory, "p")
    local cwd = vim.fn.getcwd()
    vim.fn.chdir(directory)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_name(buf, directory .. "/new.lua")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "before", "new target", "after" })
    state._reset()
    memory._reset()
    config.setup({ comment = { storage = { backend = backend, file = { dir = directory .. "/reviews" } } } })
    require("commentary.storage.file").reload()
    state.init()
    local id = state.add_comment({ id = "root", file = "missing.lua", line_start = 99, line_end = 99,
      comment = "Root text", author = "Reviewer", timestamp = 1,
      anchor = { version = 1, path = "missing.lua", selected = { "old" } } })
    state.add_reply(id, "Reply text")
    local stored = state.get_comment(id)
    local context = { bufnr = buf, file = directory .. "/new.lua", line_start = 2, line_end = 2,
      lines = { "new target" }, before_lines = { "before" }, after_lines = { "after" } }
    MiniTest.expect.equality(state.reattach_thread(stored.thread_id, context), true)
    local comments = state.get_thread_comments(stored.thread_id)
    MiniTest.expect.equality(#comments, 2)
    for _, comment in ipairs(comments) do
      MiniTest.expect.equality(comment.line_start, 2)
      MiniTest.expect.equality(comment.anchor_status, "attached")
      MiniTest.expect.equality(comment.anchor.selected, { "new target" })
    end
    MiniTest.expect.equality(state.get_comment(id).timestamp, 1)
    MiniTest.expect.equality(comments[1].comment, "Root text")
    MiniTest.expect.equality(comments[2].comment, "Reply text")
    MiniTest.expect.equality(state.reattach_thread("nonexistent", context), false)
    state._reset()
    vim.fn.chdir(cwd)
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(directory, "rf")
  end
end

return T
