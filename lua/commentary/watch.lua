local M = {}
local handle, epoch = nil, 0

function M.stop()
  epoch = epoch + 1
  if handle then
    handle:stop()
    handle:close()
    handle = nil
  end
end

--- Watch the storage directory, or its nearest existing parent until created.
--- A nonrecursive watch is enough: each thread is one immediate Markdown file.
function M.start(directory, callback)
  M.stop()
  directory = vim.fs.normalize(vim.fn.fnamemodify(directory, ":p"))
  local parent = directory
  while not vim.uv.fs_stat(parent) do
    local next_parent = vim.fs.dirname(parent)
    if not next_parent or next_parent == parent then return end
    parent = next_parent
  end
  local token, queued = epoch, false
  handle = vim.uv.new_fs_event()
  local ok = handle:start(parent, {}, function(err, filename)
    if err or token ~= epoch then return end
    if parent ~= directory and filename then
      local expected = directory:sub(#parent + 2):match("^[^/]+")
      if filename ~= expected then return end
    elseif filename and not filename:match("%.md$") and vim.uv.fs_stat(directory) then
      return
    end
    if queued then return end
    queued = true
    vim.schedule(function()
      vim.defer_fn(function()
        if token ~= epoch then return end
        M.start(directory, callback)
        callback()
      end, 60)
    end)
  end)
  if not ok then M.stop() end
end

function M.active() return handle ~= nil end
return M
