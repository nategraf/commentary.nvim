local M = {}

local function git(root, args)
  local result = vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }):wait()
  return result.code == 0 and result.stdout or ""
end

local function key(anchor)
  return anchor.path .. "\0" .. anchor.buffer_hash
end

--- Explicit, bounded history search. Only an exact full-source hash match
--- establishes provenance. Run in the background worker, never the UI thread.
function M.recover(comments, root, evidence, search)
  evidence = vim.deepcopy(evidence or {})
  if not search and not next(evidence) then return comments, evidence end
  local wanted = {}
  for _, comment in ipairs(comments) do
    local anchor = comment.anchor
    if require("commentary.anchor").valid(comment) and anchor and anchor.buffer_hash and anchor.start and anchor.finish
      and not anchor.base_line_start and not evidence[key(anchor)] then
      wanted[anchor.path] = wanted[anchor.path] or {}
      wanted[anchor.path][anchor.buffer_hash] = true
    end
  end
  if search then
    local hashes = {}
    for path, targets in pairs(wanted) do
      local log = git(root, { "log", "--all", "-100", "--raw", "--no-abbrev", "--format=%H", "--", path })
      local commit
      for line in log:gmatch("[^\n]+") do
        if line:match("^%x+$") then commit = line end
        local blob = line:match("^:%d+ %d+ %x+ (%x+) ")
        if commit and blob and not blob:match("^0+$") then
          if not hashes[blob] then hashes[blob] = vim.fn.sha256(git(root, { "cat-file", "blob", blob })) end
          if targets[hashes[blob]] then
            evidence[path .. "\0" .. hashes[blob]] = { blob = blob, commit = commit }
          end
        end
      end
    end
  end
  local recovered = vim.deepcopy(comments)
  for _, comment in ipairs(recovered) do
    local anchor = comment.anchor
    local found = require("commentary.anchor").valid(comment) and type(anchor) == "table"
      and anchor.path and anchor.buffer_hash and evidence[key(anchor)]
    if found and anchor.start and anchor.finish then
      anchor.base_blob, anchor.base_commit = found.blob, found.commit
      anchor.base_line_start, anchor.base_line_end = anchor.start.line, anchor.finish.line
    end
  end
  return recovered, evidence
end

return M
