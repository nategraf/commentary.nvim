local refresh = require("commentary.refresh")
local state = require("commentary.state")
local config = require("commentary.config")
local memory = require("commentary.storage.memory")
local original_system = vim.system
local eventignore
local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    eventignore = vim.o.eventignore
    vim.o.eventignore = "all"
    state._reset()
    config.setup({ comment = { storage = { backend = "memory" } } })
    memory._reset()
    state.init()
  end,
  post_case = function()
    vim.system = original_system
    state._reset()
    vim.wait(2000, function() return not refresh.is_running() end, 10)
    vim.o.eventignore = eventignore
  end,
} })

local function wait_for(predicate)
  MiniTest.expect.equality(vim.wait(5000, predicate, 10), true)
end

T["real worker loads comments without resolving synchronously in the editor"] = function()
  memory.add({ id = "async", file = "absent.lua", line_start = 1, line_end = 1,
    comment = "A", timestamp = 1 })
  local done = false
  state.request_sync(function() done = true end)
  MiniTest.expect.equality(done, false)
  wait_for(function() return done end)
  MiniTest.expect.equality(state.get_comments()[1].comment, "A")
  state.update_comment("async", { comment = "B" })
  MiniTest.expect.equality(state.get_comments()[1].comment, "B")
  wait_for(function() return not refresh.is_running() end)
  MiniTest.expect.equality(state.get_comments()[1].comment, "B")
end

T["superseded generations do not apply and requests coalesce"] = function()
  local jobs, applied = {}, {}
  vim.system = function(_, opts, callback)
    table.insert(jobs, { callback = callback, input = vim.json.decode(opts.stdin) })
  end
  local function request(label)
    refresh.request({}, function() table.insert(applied, label) end)
  end
  request("old")
  wait_for(function() return #jobs == 1 end)
  request("intermediate")
  request("latest")
  jobs[1].callback({ code = 0, stdout = '{"comments":[],"resolved":[]}' })
  wait_for(function() return #jobs == 2 end)
  MiniTest.expect.equality(applied, {})
  jobs[2].callback({ code = 0, stdout = '{"comments":[],"resolved":[]}' })
  wait_for(function() return not refresh.is_running() end)
  MiniTest.expect.equality(applied, { "latest" })
end

T["cancellation prevents a late result from applying"] = function()
  local callback, applied
  vim.system = function(_, _, done) callback = done end
  refresh.request({}, function() applied = true end)
  wait_for(function() return callback ~= nil end)
  refresh.cancel()
  callback({ code = 0, stdout = '{"comments":[],"resolved":[]}' })
  wait_for(function() return not refresh.is_running() end)
  MiniTest.expect.equality(applied, nil)
end

T["a changed source buffer invalidates and retries the snapshot"] = function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".lua")
  local jobs, applied = {}, 0
  vim.system = function(_, _, callback) table.insert(jobs, callback) end
  refresh.request({}, function() applied = applied + 1 end)
  wait_for(function() return #jobs == 1 end)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "edited" })
  jobs[1]({ code = 0, stdout = '{"comments":[],"resolved":[]}' })
  wait_for(function() return #jobs == 2 end)
  MiniTest.expect.equality(applied, 0)
  jobs[2]({ code = 0, stdout = '{"comments":[],"resolved":[]}' })
  wait_for(function() return not refresh.is_running() end)
  MiniTest.expect.equality(applied, 1)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["worker spawn failure does not wedge future refreshes"] = function()
  local notify, notices = vim.notify, {}
  vim.notify = function(message) table.insert(notices, message) end
  vim.system = function() error("spawn failed") end
  refresh.request({}, function() error("must not apply") end)
  wait_for(function() return not refresh.is_running() end)
  vim.system = original_system
  vim.notify = notify
  MiniTest.expect.equality(#notices, 1)
  local done = false
  refresh.request({}, function() done = true end)
  wait_for(function() return done end)
end

T["directory changes discard a completed job"] = function()
  local cwd = vim.fn.getcwd()
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  local callback, applied
  vim.system = function(_, _, done) callback = done end
  refresh.request({}, function() applied = true end)
  wait_for(function() return callback ~= nil end)
  vim.fn.chdir(directory)
  callback({ code=0, stdout='{"comments":[],"resolved":[]}' })
  wait_for(function() return not refresh.is_running() end)
  vim.fn.chdir(cwd)
  vim.fn.delete(directory, "rf")
  MiniTest.expect.equality(applied, nil)
end

T["failed refresh retains state and discards pending picker callbacks"] = function()
  memory.add({ id="kept", file="missing.lua", line_start=1, line_end=1, comment="Keep me", timestamp=1 })
  state.request_sync()
  wait_for(function() return not refresh.is_running() end)
  local callback, opened
  local notify = vim.notify
  vim.notify = function() end
  vim.system = function(_, _, done) callback = done end
  state.request_sync(function() opened = true end)
  wait_for(function() return callback ~= nil end)
  callback({code=0, stdout='not JSON'})
  wait_for(function() return not refresh.is_running() end)
  vim.notify, vim.system = notify, original_system
  MiniTest.expect.equality(state.get_comments()[1].comment, "Keep me")
  state.request_sync()
  wait_for(function() return not refresh.is_running() end)
  MiniTest.expect.equality(opened, nil)
end

return T
