local watch = require("commentary.watch")
local directory
local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    directory = vim.fn.tempname()
    vim.fn.mkdir(directory, "p")
  end,
  post_case = function()
    watch.stop()
    vim.fn.delete(directory, "rf")
  end,
} })

T["storage watch follows creation and edits, and stops cleanly"] = function()
  local count = 0
  local target = directory .. "/reviews"
  watch.start(target, function() count = count + 1 end)
  MiniTest.expect.equality(watch.active(), true)
  vim.fn.mkdir(target, "p")
  MiniTest.expect.equality(vim.wait(2000, function() return count > 0 end, 10), true)
  local before = count
  vim.fn.writefile({"comment"}, target .. "/thread.md")
  MiniTest.expect.equality(vim.wait(2000, function() return count > before end, 10), true)
  before = count
  vim.fn.writefile({"edited"}, target .. "/thread.md")
  MiniTest.expect.equality(vim.wait(2000, function() return count > before end, 10), true)
  watch.stop()
  before = count
  vim.fn.writefile({"ignored"}, target .. "/thread.md")
  vim.wait(150, function() return count > before end, 10)
  MiniTest.expect.equality(count, before)
end

return T
