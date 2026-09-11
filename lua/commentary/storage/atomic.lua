local M = {}

--- Replace a review file without exposing truncated/partially written contents.
--- This is atomic publication, not a concurrent read-modify-write transaction.
---@param path string
---@param content string
---@return boolean
function M.write(path, content)
  local uv = vim.uv
  local fd, temporary
  local ok, err = pcall(function()
    local stat, stat_err, code = uv.fs_lstat(path)
    if not stat and code ~= "ENOENT" then error(stat_err) end
    if stat and stat.type ~= "file" then error("Destination is not a regular file") end
    local dir = vim.fs.dirname(path)
    vim.fn.mkdir(dir, "p")
    local open_err
    fd, open_err = uv.fs_mkstemp(dir .. "/.commentary-write-XXXXXX")
    assert(fd, open_err)
    temporary = open_err
    if stat then assert(uv.fs_fchmod(fd, bit.band(stat.mode, 511))) end
    local offset = 0
    while offset < #content do
      local written, write_err = uv.fs_write(fd, content:sub(offset + 1), offset)
      assert(written and written > 0, write_err or "Short write")
      offset = offset + written
    end
    assert(uv.fs_fsync(fd))
    local closed, close_err = uv.fs_close(fd)
    fd = nil
    assert(closed, close_err)
    assert(uv.fs_rename(temporary, path))
    temporary = nil
  end)
  if fd then uv.fs_close(fd) end
  if temporary then uv.fs_unlink(temporary) end
  if not ok then vim.notify("Could not save review file " .. path .. ": " .. tostring(err), vim.log.levels.ERROR) end
  return ok
end

return M
