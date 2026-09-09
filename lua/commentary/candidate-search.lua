local M = {}
local anchor = require("commentary.anchor")
local utils = require("commentary.utils")

-- Explicit repository search only. Limits bound IO and result transfer; an
-- incomplete search is reported, never presented as proof of no matches.
function M.search(comment, root)
  local result = { candidates = {}, truncated = false, scanned = 0 }
  local deadline = vim.uv.hrtime() + 8e9
  local seen, paths = {}, {}
  local storage = vim.fs.normalize(utils.get_storage_dir(require("commentary.config").get("comment.storage.file.dir")))
  local function add(path)
    if not path or path == "" then return end
    path = vim.fs.normalize(path:sub(1, 1) == "/" and path or root .. "/" .. path)
    if not vim.startswith(path, root .. "/") or path == storage or vim.startswith(path, storage .. "/") then return end
    if not seen[path] then seen[path] = true; table.insert(paths, path) end
  end
  add(comment.file)
  if type(comment.anchor) == "table" then add(comment.anchor.path) end
  local resolved = anchor.resolve_all({ comment })[1]
  add(resolved.file)

  local stored = type(comment.anchor) == "table" and comment.anchor or { selected = comment.context_lines }
  local seeds = {}
  for _, section in ipairs({ "selected", "before", "after" }) do
    local longest = ""
    for _, line in ipairs(type(stored[section]) == "table" and stored[section] or {}) do
      if type(line) == "string" then
        for token in line:gmatch("[%w_]+") do
          if #token > #longest then longest = token end
        end
      end
    end
    if #longest >= 4 then table.insert(seeds, longest) end
  end
  local command
  if #seeds > 0 and vim.fn.executable("rg") == 1 then
    command = { "rg", "--files-with-matches", "--null", "--hidden", "--fixed-strings", "--max-filesize", "2M", "-g", "!.git" }
    for _, seed in ipairs(seeds) do vim.list_extend(command, { "-e", seed }) end
    vim.list_extend(command, { "--", "." })
  else
    command = { "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard" }
  end
  local found = vim.system(command, { cwd = root, text = false, timeout = 5000 }):wait()
  if found.code ~= 0 and not (command[1] == "rg" and found.code == 1) then result.truncated = true end
  for path in (found.stdout or ""):gmatch("[^%z]+") do
    if #paths >= 2000 then result.truncated = true; break end
    add(path)
  end
  -- Include unsaved buffers even if the on-disk text did not match a seed.
  for name in pairs(anchor.buffer_map()) do if name:sub(1, 1) == "/" then add(name) end end
  for _, path in ipairs(paths) do
    if vim.uv.hrtime() > deadline or #result.candidates >= 200 then result.truncated = true; break end
    local stat = vim.uv.fs_lstat(path)
    local buf = anchor.find_buffer(path)
    if (not stat or stat.type == "file") and utils.find_git_root(path) == root then
      local lines
      if buf then
        lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      elseif stat and stat.size <= 2 * 1024 * 1024 then
        local ok, contents = pcall(vim.fn.readfile, path)
        if ok then lines = contents end
      elseif stat then
        result.truncated = true
      end
      if lines then
        result.scanned = result.scanned + 1
        local matches = anchor.candidates_in_lines(comment, lines)
        local hash = #matches > 0 and vim.fn.sha256(table.concat(lines, "\n")) or nil
        for _, candidate in ipairs(matches) do
          if #result.candidates >= 200 then result.truncated = true; break end
          candidate.file, candidate.hash = path, hash
          candidate.preview_start = math.max(1, candidate.line_start - 4)
          candidate.preview = vim.list_slice(lines, candidate.preview_start, math.min(#lines, candidate.line_end + 4, candidate.preview_start + 79))
          table.insert(result.candidates, candidate)
        end
      end
    end
  end
  local ranks = { exact = 1, whitespace = 2, context = 3 }
  table.sort(result.candidates, function(a, b)
    if a.evidence ~= b.evidence then return ranks[a.evidence] < ranks[b.evidence] end
    if (a.score or 0) ~= (b.score or 0) then return (a.score or 0) > (b.score or 0) end
    if a.file ~= b.file then return a.file < b.file end
    return a.line_start < b.line_start
  end)
  return result
end

return M
