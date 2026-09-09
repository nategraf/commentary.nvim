local state = require("commentary.state")
local config = require("commentary.config")
local memory = require("commentary.storage.memory")
local search = require("commentary.candidate-search").search
local reattach = require("commentary.reattach")
local directory, cwd, buffers, root
local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    vim.opt.swapfile = false
    cwd, directory, buffers = vim.fn.getcwd(), vim.fn.tempname(), {}
    vim.fn.mkdir(directory, "p")
    vim.fn.chdir(directory)
    assert(vim.system({ "git", "init", "-q" }):wait().code == 0)
    state._reset()
    memory._reset()
    config.setup({ comment = { storage = { backend = "memory", file = { dir = ".commentary" } } } })
    state.init()
    local id = state.add_comment({ id = "root", file = "missing.lua", line_start = 5, line_end = 5,
      comment = "Root", anchor = { version = 1, path = "missing.lua", selected = { "local target = 42" } } })
    root = vim.deepcopy(state.get_comment(id))
  end,
  post_case = function()
    state._reset()
    for _, buf in ipairs(buffers) do if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end end
    vim.fn.chdir(cwd)
    vim.fn.delete(directory, "rf")
  end,
} })

T["search finds cross-file duplicates and ranks exact before whitespace"] = function()
  vim.fn.writefile({ "local  target = 42" }, "a.lua")
  vim.fn.writefile({ "local target = 42", "local target = 42" }, "z.lua")
  local result = search(root, directory)
  MiniTest.expect.equality(#result.candidates, 3)
  MiniTest.expect.equality(result.candidates[1].file, directory .. "/z.lua")
  MiniTest.expect.equality(result.candidates[2].line_start, 2)
  MiniTest.expect.equality(result.candidates[3].evidence, "whitespace")
  MiniTest.expect.equality(result.truncated, false)
end

T["search includes unsaved text and excludes review files and symlinks"] = function()
  vim.fn.writefile({ "nothing" }, "dirty.lua")
  local buf = vim.fn.bufadd(directory .. "/dirty.lua")
  table.insert(buffers, buf)
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local target = 42" })
  vim.fn.mkdir(".commentary", "p")
  vim.fn.writefile({ "local target = 42" }, ".commentary/review.md")
  vim.uv.fs_symlink(directory .. "/dirty.lua", directory .. "/linked.lua")
  local result = search(root, directory)
  MiniTest.expect.equality(#result.candidates, 1)
  MiniTest.expect.equality(result.candidates[1].file, directory .. "/dirty.lua")
end

T["selection rejects changed source or attachment and preserves replies"] = function()
  vim.fn.writefile({ "local target = 42" }, "new.lua")
  local candidate = search(root, directory).candidates[1]
  vim.fn.writefile({ "changed" }, "new.lua")
  MiniTest.expect.equality(reattach.apply(root.thread_id, root, candidate, directory), false)
  local buf = vim.fn.bufnr(directory .. "/new.lua")
  table.insert(buffers, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local target = 42" })
  local wrong = vim.deepcopy(root)
  wrong.line_start = 999
  MiniTest.expect.equality(reattach.apply(root.thread_id, wrong, candidate, directory), false)
  state.add_reply(root.id, "Reply added while searching")
  MiniTest.expect.equality(reattach.apply(root.thread_id, root, candidate, directory), true)
  MiniTest.expect.equality(#state.get_thread_comments(root.thread_id), 2)
  MiniTest.expect.equality(state.get_comment(root.id).line_start, 1)
  MiniTest.expect.equality(reattach.apply(root.thread_id, root, candidate, directory), false)
end

T["bang infers the thread from a reply in the comment view"] = function()
  local reply = state.add_reply(root.id, "Reply target")
  local ui = require("commentary.ui")
  ui.show_comment_list(state.get_thread_comments(root.thread_id))
  local buf = vim.api.nvim_get_current_buf()
  table.insert(buffers, buf)
  for line, text in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if text:find("Reply target", 1, true) then vim.api.nvim_win_set_cursor(0, { line, 0 }); break end
  end
  MiniTest.expect.equality(ui.comment_under_cursor().id, reply)
  local original, selected = reattach.search
  reattach.search = function(id, comment) selected = { id, comment.id } end
  local ok, err = pcall(require("commentary").reattach_thread, nil, nil, true)
  reattach.search = original
  assert(ok, err)
  MiniTest.expect.equality(selected, { root.thread_id, root.id })
end

T["worker returns cross-file source previews without initializing storage"] = function()
  vim.fn.writefile({ "local target = 42" }, "new.lua")
  local result = vim.system({ vim.v.progpath, "--headless", "--noplugin", "-u", "NONE", "-n", "-i", "NONE",
    "-l", cwd .. "/lua/commentary/worker.lua" }, { text = true,
    stdin = vim.json.encode({ operation = "candidates", runtime = cwd, cwd = directory, buffers = {},
      comment = root, config = { comment = { storage = { backend = "memory" } } } }),
  }):wait(15000)
  MiniTest.expect.equality(result.code, 0)
  local data = vim.json.decode(result.stdout)
  MiniTest.expect.equality(data.candidates[1].preview, { "local target = 42" })
  MiniTest.expect.equality(vim.fn.isdirectory(".commentary"), 0)
end

T["cancelling a pending picker kills its worker and ignores late results"] = function()
  local names = { "telescope.pickers", "telescope.actions", "telescope.finders", "telescope.config", "telescope.previewers" }
  local saved = {}
  for _, name in ipairs(names) do saved[name] = package.loaded[name] end
  local system, callback, killed, refreshed = vim.system, nil, false, false
  local prompt = vim.api.nvim_create_buf(false, true)
  table.insert(buffers, prompt)
  package.loaded["telescope.pickers"] = { new = function(_, opts)
    return { find = function() opts.attach_mappings(prompt, function() end) end,
      refresh = function() refreshed = true end }
  end }
  package.loaded["telescope.actions"] = { select_default = { replace = function() end } }
  package.loaded["telescope.finders"] = { new_table = function(opts) return opts end }
  package.loaded["telescope.config"] = { values = { generic_sorter = function() end } }
  package.loaded["telescope.previewers"] = { new_buffer_previewer = function(opts) return opts end }
  vim.system = function(_, _, on_exit)
    callback = on_exit
    return { kill = function() killed = true end }
  end
  local ok, err = pcall(function()
    reattach.search(root.thread_id, root)
    vim.api.nvim_buf_delete(prompt, { force = true })
    MiniTest.expect.equality(killed, true)
    callback({ code = 0, stdout = '{"candidates":[],"truncated":false}' })
    vim.wait(20)
    MiniTest.expect.equality(refreshed, false)
    MiniTest.expect.equality(state.get_comment(root.id).line_start, 5)
  end)
  vim.system = system
  for _, name in ipairs(names) do package.loaded[name] = saved[name] end
  assert(ok, err)
end

T["selection rejects a symlink substituted after search"] = function()
  vim.fn.writefile({ "local target = 42" }, "new.lua")
  local candidate = search(root, directory).candidates[1]
  vim.fn.rename("new.lua", "other.lua")
  vim.uv.fs_symlink(directory .. "/other.lua", directory .. "/new.lua")
  MiniTest.expect.equality(reattach.apply(root.thread_id, root, candidate, directory), false)
end

return T
