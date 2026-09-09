local state = require("commentary.state")
local memory = require("commentary.storage.memory")
local list = require("commentary.list")
local config = require("commentary.config")
local original_confirm, original_notify = vim.fn.confirm, vim.notify
local original_delete = memory.delete
local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    config.setup({ comment = { storage = { backend = "memory" } } })
    state._reset()
    memory._reset()
    state.init()
    vim.notify = function() end
  end,
  post_case = function()
    vim.fn.confirm, vim.notify = original_confirm, original_notify
    memory.delete = original_delete
  end,
} })

local function add_thread(text)
  local id = state.add_comment({ file = "example.lua", line_start = 1, line_end = 1, comment = text })
  state.add_reply(id, "Reply")
  local root = state.get_comment(id)
  return { id = root.thread_id, data = { root_comment = root, replies = { { comment = "Reply" } } } }
end

T["batch deduplicates and reports one event with every removed comment"] = function()
  local a, b, kept = add_thread("A"), add_thread("B"), add_thread("Kept")
  local events = {}
  local autocmd = vim.api.nvim_create_autocmd("User", {
    pattern = "CommentaryCommentsChanged", callback = function(args) table.insert(events, args.data) end,
  })
  local result = state.delete_threads({ a.id, b.id, a.id })
  vim.api.nvim_del_autocmd(autocmd)
  MiniTest.expect.equality({ result.threads, result.comments, #result.failures }, { 2, 4, 0 })
  MiniTest.expect.equality(#events, 1)
  MiniTest.expect.equality(#events[1].removed, 4)
  MiniTest.expect.equality(#state.get_comments(), 2)
  MiniTest.expect.equality(state.get_comment(kept.data.root_comment.id) ~= nil, true)
end

T["partial failure preserves failed threads and reports accurate counts"] = function()
  local a, b = add_thread("A"), add_thread("B")
  memory.delete = function(id)
    if id == b.data.root_comment.id then error("test failure") end
    return original_delete(id)
  end
  local result = state.delete_threads({ a.id, b.id, "missing" })
  MiniTest.expect.equality({ result.threads, result.comments, #result.failures }, { 1, 2, 2 })
  MiniTest.expect.equality(#state.get_comments(), 2)
end

T["confirmation cancels without closing or mutating"] = function()
  local a = add_thread("A")
  vim.fn.confirm = function(prompt, _, default)
    MiniTest.expect.match(prompt, "1 thread%(s%), containing 2 comment%(s%)")
    MiniTest.expect.equality(default, 2)
    return 2
  end
  list._delete_threads({ a, a }, function() error("should remain open") end)
  MiniTest.expect.equality(#state.get_comments(), 2)
end

T["Telescope deletes marked entries in preference to the cursor"] = function()
  local a, b, kept = add_thread("A"), add_thread("B"), add_thread("Kept")
  local old_actions, old_state = package.loaded["telescope.actions"], package.loaded["telescope.actions.state"]
  local closed = false
  package.loaded["telescope.actions"] = { close = function() closed = true end }
  package.loaded["telescope.actions.state"] = {
    get_current_picker = function() return { get_multi_selection = function() return { { value = a }, { value = b } } end } end,
    get_selected_entry = function() return { value = kept } end,
  }
  vim.fn.confirm = function() return 1 end
  local ok, err = pcall(list._delete_telescope_threads, 1)
  package.loaded["telescope.actions"], package.loaded["telescope.actions.state"] = old_actions, old_state
  assert(ok, err)
  MiniTest.expect.equality(closed, true)
  MiniTest.expect.equality(#state.get_comments(), 2)
end

T["fzf adapter supports duplicate rows and a configurable deletion key"] = function()
  add_thread("Identical")
  add_thread("Identical")
  config.setup({ comment = { storage = { backend = "memory" } }, integrations = { delete_threads_key = "<C-e>" } })
  local old_fzf, old_builtin = package.loaded["fzf-lua"], package.loaded["fzf-lua.previewer.builtin"]
  local captured, rows
  package.loaded["fzf-lua"] = { fzf_exec = function(entries, opts) rows, captured = entries, opts end }
  package.loaded["fzf-lua.previewer.builtin"] = { buffer_or_file = { extend = function() return {} end } }
  local ok, err = pcall(list.list_threads_with_fzf_lua)
  package.loaded["fzf-lua"], package.loaded["fzf-lua.previewer.builtin"] = old_fzf, old_builtin
  assert(ok, err)
  MiniTest.expect.equality(captured.fzf_opts["--multi"], true)
  MiniTest.expect.equality(rows[1] ~= rows[2], true)
  vim.fn.confirm = function() return 1 end
  captured.actions["ctrl-e"]({ rows[1], rows[2] })
  captured.fn_post()
  vim.wait(150, function() return false end)
  MiniTest.expect.equality(#state.get_comments(), 0)
end

return T
