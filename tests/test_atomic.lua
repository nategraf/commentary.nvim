local atomic = require("commentary.storage.atomic")
local directory
local T = MiniTest.new_set({ hooks = {
  pre_case = function() directory = vim.fn.tempname(); vim.fn.mkdir(directory, "p") end,
  post_case = function() vim.fn.delete(directory, "rf") end,
} })

T["replacement preserves permissions and publishes complete content"] = function()
  local path = directory .. "/review.md"
  assert(atomic.write(path, "old\n"))
  vim.uv.fs_chmod(path, 416) -- 0640
  local rename = vim.uv.fs_rename
  vim.uv.fs_rename = function(from, to)
    MiniTest.expect.equality(vim.fn.readfile(to), { "old" })
    MiniTest.expect.equality(vim.fn.readfile(from), { "new", "", "body" })
    return rename(from, to)
  end
  local ok = atomic.write(path, "new\n\nbody\n")
  vim.uv.fs_rename = rename
  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(bit.band(vim.uv.fs_stat(path).mode, 511), 416)
  MiniTest.expect.equality(vim.fn.glob(directory .. "/.commentary-write-*", false, true), {})
end

for _, operation in ipairs({ "fs_write", "fs_fsync", "fs_rename" }) do
  T[operation .. " failure leaves original intact and cleans temporary file"] = function()
    local path = directory .. "/review.md"
    vim.fn.writefile({ "original" }, path)
    local original, notify = vim.uv[operation], vim.notify
    vim.uv[operation] = function() return nil, "injected failure" end
    vim.notify = function() end
    local ok = atomic.write(path, "replacement")
    vim.uv[operation], vim.notify = original, notify
    MiniTest.expect.equality(ok, false)
    MiniTest.expect.equality(vim.fn.readfile(path), { "original" })
    MiniTest.expect.equality(vim.fn.glob(directory .. "/.commentary-write-*", false, true), {})
  end
end

T["symlinks are refused without touching their targets"] = function()
  local path = directory .. "/review.md"
  vim.fn.writefile({ "original" }, path)
  vim.uv.fs_symlink(path, directory .. "/link.md")
  local notify = vim.notify
  vim.notify = function() end
  local ok = atomic.write(directory .. "/link.md", "replacement")
  vim.notify = notify
  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(vim.fn.readfile(path), { "original" })
end

return T
