local M = {}
local utils = require("commentary.utils")

local ns = vim.api.nvim_create_namespace("CommentaryAnchors")
local live = {}
local path_cache = {}
local diff_cache = {}
local root_cache = {}
local buffer_cache = {}
local content_cache = {}

local function run_git(root, args)
  if not root or root == "" then
    return nil
  end

  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  if result.code ~= 0 then
    return nil
  end
  return result.stdout
end

local function git_root(path)
  local directory = path
  if path and vim.fn.isdirectory(path) == 0 then
    directory = vim.fn.fnamemodify(path, ":h")
  end
  directory = directory ~= "" and directory or vim.fn.getcwd()
  if root_cache[directory] ~= nil then
    return root_cache[directory] or nil
  end
  local root = utils.find_git_root(directory)
  root_cache[directory] = root or false
  return root
end

local function relative_path(root, path)
  local absolute = vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
  local normalized_root = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
  if absolute == normalized_root then
    return "."
  end
  if vim.startswith(absolute, normalized_root .. "/") then
    return absolute:sub(#normalized_root + 2)
  end
  return path
end

local function absolute_path(root, path)
  if path:match("^/") then
    local absolute = vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
    return absolute
  end
  local absolute = vim.fn.fnamemodify(root .. "/" .. path, ":p"):gsub("/$", "")
  return absolute
end

local function path_available(root, path)
  local absolute = absolute_path(root, path)
  return vim.fn.filereadable(absolute) == 1 or vim.fn.bufloaded(absolute) == 1
end

local function buffer_text(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = buffer_cache[bufnr]
  if cached and cached.tick == tick and cached.endofline == vim.bo[bufnr].endofline then
    return cached.text, cached.lines
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")
  if vim.bo[bufnr].endofline then
    text = text .. "\n"
  end
  buffer_cache[bufnr] = { tick = tick, text = text, lines = lines, endofline = vim.bo[bufnr].endofline }
  return text, lines
end

local function read_text(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end

local function text_lines(text)
  if text == "" then
    return { "" }
  end
  local without_final_newline = text:gsub("\n$", "")
  return vim.split(without_final_newline, "\n", { plain = true })
end

local function hash(text)
  return vim.fn.sha256(text)
end

local function positive_integer(value)
  return type(value) == "number" and value >= 1 and value < math.huge and value == math.floor(value)
end

--- Reject malformed metadata without hiding the comment or crashing a batch.
function M.valid(comment)
  if type(comment.file) ~= "string" or comment.file == "" or comment.file:find("\0", 1, true)
    or not positive_integer(comment.line_start) or not positive_integer(comment.line_end)
    or comment.line_end < comment.line_start then
    return false
  end
  local stored = comment.anchor
  if stored == nil then return true end
  if type(stored) ~= "table" or stored.version ~= 1 or type(stored.path) ~= "string" or stored.path == ""
    or stored.path:find("\0", 1, true) then return false end
  for _, field in ipairs({ "selected", "before", "after" }) do
    if stored[field] ~= nil then
      if type(stored[field]) ~= "table" or not vim.islist(stored[field]) then return false end
      for _, line in ipairs(stored[field]) do
        if type(line) ~= "string" then return false end
      end
    end
  end
  for _, field in ipairs({ "start", "finish" }) do
    if stored[field] ~= nil and (type(stored[field]) ~= "table" or not positive_integer(stored[field].line)) then
      return false
    end
  end
  if stored.start and stored.finish and stored.finish.line < stored.start.line then return false end
  if (stored.base_line_start ~= nil or stored.base_line_end ~= nil)
    and (not positive_integer(stored.base_line_start) or not positive_integer(stored.base_line_end)
      or stored.base_line_end < stored.base_line_start) then return false end
  for _, field in ipairs({ "base_commit", "base_blob", "buffer_hash" }) do
    if stored[field] ~= nil and (type(stored[field]) ~= "string" or not stored[field]:match("^%x+$")) then
      return false
    end
  end
  return true
end

local function anchor_key(comment)
  return comment.thread_id or comment.id
end

local function normalize_line(line)
  return vim.trim((line:gsub("%s+", " ")))
end

local function same_lines(left, right, normalize)
  if #left ~= #right then
    return false
  end
  for index, line in ipairs(left) do
    local expected = right[index]
    if normalize then
      line = normalize_line(line)
      expected = normalize_line(expected)
    end
    if line ~= expected then
      return false
    end
  end
  return true
end

local function context_score(anchor, lines, start_line, end_line, normalize)
  local score = 0
  local before = anchor.before or {}
  local after = anchor.after or {}

  for distance = 1, #before do
    local expected = before[#before - distance + 1]
    local actual = lines[start_line - distance]
    if not actual then
      break
    end
    if normalize then
      expected = normalize_line(expected)
      actual = normalize_line(actual)
    end
    if actual ~= expected then
      break
    end
    score = score + 1
  end

  for distance = 1, #after do
    local expected = after[distance]
    local actual = lines[end_line + distance]
    if not actual then
      break
    end
    if normalize then
      expected = normalize_line(expected)
      actual = normalize_line(actual)
    end
    if actual ~= expected then
      break
    end
    score = score + 1
  end

  return score
end

local function content_candidates(anchor, lines, normalize)
  local selected = anchor.selected or {}
  if #selected == 0 or #selected > #lines then
    return {}
  end

  local candidates = {}
  for start_line = 1, #lines - #selected + 1 do
    local candidate = {}
    for offset = 0, #selected - 1 do
      table.insert(candidate, lines[start_line + offset])
    end
    if same_lines(candidate, selected, normalize) then
      local end_line = start_line + #selected - 1
      table.insert(candidates, {
        line_start = start_line,
        line_end = end_line,
        score = context_score(anchor, lines, start_line, end_line, normalize),
      })
    end
  end

  table.sort(candidates, function(left, right)
    if left.score == right.score then
      return left.line_start < right.line_start
    end
    return left.score > right.score
  end)
  return candidates
end

local function choose_candidate(candidates)
  if #candidates == 0 then
    return nil, false
  end
  if #candidates > 1 and candidates[1].score == candidates[2].score then
    return nil, true
  end
  return candidates[1], false
end

-- Surviving context can identify a rewritten selection even when it was
-- created in an uncommitted/new file. Require both complete context blocks and
-- a unique bounded gap; never use proximity to the stale line as evidence.
local function context_range(anchor, lines)
  local before, after = anchor.before or {}, anchor.after or {}
  if #before == 0 or #after == 0 then return nil end
  local starts = content_candidates({ selected = before }, lines, false)
  local ends = content_candidates({ selected = after }, lines, false)
  local found
  for _, left in ipairs(starts) do
    for _, right in ipairs(ends) do
      local first, last = left.line_end + 1, right.line_start - 1
      if last >= first - 1 and last - first < math.max(20, #(anchor.selected or {}) * 4) then
        if found then return nil end
        found = { line_start = first, line_end = last, status = last < first and "deleted" or "modified" }
      end
    end
  end
  return found
end

--- Candidate locations in a user-chosen buffer. Never auto-accept a candidate.
function M.candidates(comment, bufnr)
  if not M.valid(comment) then return {} end
  local stored = comment.anchor or { selected = comment.context_lines or {} }
  local _, lines = buffer_text(bufnr)
  local candidates = content_candidates(stored, lines, false)
  if #candidates == 0 then candidates = content_candidates(stored, lines, true) end
  if #candidates == 0 then
    local surrounded = context_range(stored, lines)
    if surrounded and surrounded.status ~= "deleted" then candidates = { surrounded } end
  end
  for _, candidate in ipairs(candidates) do candidate.text = lines[candidate.line_start] end
  return candidates
end

local function parse_name_status(output, original_path)
  if not output or output == "" then
    return nil
  end

  local fields = vim.split(output, "\0", { plain = true, trimempty = true })
  local index = 1
  while index <= #fields do
    local status = fields[index]
    local kind = status:sub(1, 1)
    if kind == "R" or kind == "C" then
      local old_path = fields[index + 1]
      local new_path = fields[index + 2]
      if old_path == original_path then
        return new_path, kind
      end
      index = index + 3
    else
      local path = fields[index + 1]
      if path == original_path then
        if kind == "D" then
          return false, kind
        end
        return original_path, kind
      end
      index = index + 2
    end
  end
  return nil
end

local function resolve_path(anchor, root)
  local original_path = anchor.path
  if not anchor.base_commit then
    return path_available(root, original_path) and original_path or nil
  end

  local cache_key = root .. "\0" .. anchor.base_commit .. "\0" .. original_path
  if path_cache[cache_key] ~= nil then
    return path_cache[cache_key] or nil
  end

  local diff_key = root .. "\0" .. anchor.base_commit
  local output = diff_cache[diff_key]
  if output == nil then
    output = run_git(root, { "diff", "-M", "--name-status", "-z", anchor.base_commit }) or false
    diff_cache[diff_key] = output
  end
  output = output or nil
  local mapped, kind = parse_name_status(output, original_path)
  if mapped == false or kind == "D" then
    path_cache[cache_key] = false
    return nil
  end
  if mapped then
    path_cache[cache_key] = mapped
    return mapped
  end
  if path_available(root, original_path) then
    path_cache[cache_key] = original_path
    return original_path
  end
  path_cache[cache_key] = false
  return nil
end

local function find_buffer(root, path)
  local wanted = absolute_path(root, path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and vim.fn.fnamemodify(name, ":p"):gsub("/$", "") == wanted then
        return bufnr
      end
    end
  end
  return nil
end

local function target_content(root, path)
  local key = absolute_path(root, path)
  if content_cache[key] ~= nil then return content_cache[key] or nil end
  local bufnr = find_buffer(root, path)
  if bufnr then
    local text, lines = buffer_text(bufnr)
    content_cache[key] = {
      bufnr = bufnr,
      text = text,
      lines = lines,
    }
    return content_cache[key]
  end

  local full_path = absolute_path(root, path)
  local text = read_text(full_path)
  if not text then
    content_cache[key] = false
    return nil
  end
  content_cache[key] = {
    text = text,
    lines = text_lines(text),
  }
  return content_cache[key]
end

local function diff_function()
  return vim.text and vim.text.diff or vim.diff
end

local function diff_projection(anchor, base_text, target_text)
  if not anchor.base_line_start or not anchor.base_line_end then
    return nil
  end

  local hunks = diff_function()(base_text, target_text, {
    result_type = "indices",
    algorithm = "histogram",
    linematch = true,
  })
  local first, last = anchor.base_line_start, anchor.base_line_end
  local cursor, delta, changed = 1, 0, false
  local line_start, line_end
  local function include(start_line, end_line)
    line_start = line_start or start_line
    line_end = end_line
  end
  local function unchanged(start_line, end_line)
    start_line, end_line = math.max(first, start_line), math.min(last, end_line)
    if start_line <= end_line then include(start_line + delta, end_line + delta) end
  end
  -- Map intervals, not every source line. Empty hunks use the line *before*
  -- insertion/deletion; treating that coordinate as a normal line was off by
  -- one after deletions, including when mapping a dirty buffer back to Git.
  for _, hunk in ipairs(hunks) do
    local old_start, old_count, new_start, new_count = unpack(hunk)
    local boundary = old_start + (old_count == 0 and 1 or 0)
    unchanged(cursor, boundary - 1)
    if old_count == 0 then
      if first < boundary and boundary <= last then
        changed = true
        include(new_start, new_start + new_count - 1)
      end
    elseif old_start <= last and old_start + old_count > first then
      changed = true
      if new_count > 0 then
        include(new_start + math.min(math.max(first - old_start, 0), new_count - 1),
          new_start + math.min(math.min(last - old_start, old_count - 1), new_count - 1))
      end
    end
    delta = delta + new_count - old_count
    cursor = boundary + old_count
  end
  unchanged(cursor, last)
  if not line_start then return { status = "deleted" } end
  return {
    status = changed and "modified" or "attached",
    line_start = line_start,
    line_end = line_end,
  }
end

local function resolution(comment, path, status, line_start, line_end, bufnr)
  local resolved = vim.deepcopy(comment)
  resolved.file = type(path or comment.file) == "string" and (path or comment.file) or ""
  resolved.line_start = positive_integer(line_start or comment.line_start) and (line_start or comment.line_start) or 1
  resolved.line_end = positive_integer(line_end or comment.line_end) and (line_end or comment.line_end) or resolved.line_start
  resolved.line_end = math.max(resolved.line_start, resolved.line_end)
  resolved.anchor_resolved = status == "attached" or status == "modified"
  resolved.anchor_status = resolved.anchor_resolved and "attached" or "detached"
  resolved.anchor_reason = status
  resolved.anchor_bufnr = bufnr
  return resolved
end

local function range_from_extmark(record)
  if not vim.api.nvim_buf_is_valid(record.bufnr) or not vim.api.nvim_buf_is_loaded(record.bufnr) then
    return nil
  end
  local mark = vim.api.nvim_buf_get_extmark_by_id(record.bufnr, ns, record.id, { details = true })
  if #mark == 0 then
    return nil
  end

  local row, col, details = mark[1], mark[2], mark[3]
  local end_row = details.end_row or row
  local end_col = details.end_col or col
  local collapsed = row == end_row and col == end_col
  if details.invalid or (collapsed and not record.allow_empty) then
    return { status = "deleted" }
  end

  local line_end = end_col == 0 and end_row or end_row + 1
  line_end = math.max(row + 1, line_end)
  return {
    status = record.status,
    line_start = row + 1,
    line_end = line_end,
  }
end

local function extmark_end(bufnr, line_end)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_end < line_count then
    return line_end, 0, false
  end
  local end_row = line_count - 1
  local last_line = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or ""
  local end_col = #last_line
  return end_row, end_col, end_col == 0
end

local function move_extmark(record, line_start, line_end)
  local line_count = vim.api.nvim_buf_line_count(record.bufnr)
  local start_row = math.max(0, math.min(line_start - 1, line_count - 1))
  local end_row, end_col, empty = extmark_end(record.bufnr, line_end)
  record.id = vim.api.nvim_buf_set_extmark(record.bufnr, ns, start_row, 0, {
    id = record.id,
    end_row = end_row,
    end_col = end_col,
    right_gravity = true,
    end_right_gravity = false,
    invalidate = true,
    undo_restore = true,
    strict = false,
  })
  record.allow_empty = start_row == end_row and empty
end

local legacy_anchor

local function live_resolution(comment)
  local key = anchor_key(comment)
  local record = key and live[key] or nil
  if not record then
    return nil
  end

  local stored_anchor = comment.anchor
  if stored_anchor and stored_anchor.base_commit then
    local root = git_root(vim.fn.getcwd()) or vim.fn.getcwd()
    local current_path = resolve_path(stored_anchor, root)
    if current_path ~= record.path then
      if vim.api.nvim_buf_is_valid(record.bufnr) then
        pcall(vim.api.nvim_buf_del_extmark, record.bufnr, ns, record.id)
      end
      live[key] = nil
      return nil
    end
  end
  local range = range_from_extmark(record)
  if not range then
    live[key] = nil
    return nil
  end

  local anchor = comment.anchor or legacy_anchor(comment)
  if #(anchor.selected or {}) > 0 then
    local current_text, current_lines = buffer_text(record.bufnr)
    if range.status ~= "deleted" and same_lines(
      vim.list_slice(current_lines, range.line_start, range.line_end), anchor.selected, false
    ) then
      return resolution(comment, record.path, "attached", range.line_start, range.line_end, record.bufnr)
    end
    local exact, exact_ambiguous = choose_candidate(content_candidates(anchor, current_lines, false))
    if exact then
      move_extmark(record, exact.line_start, exact.line_end)
      record.status = "attached"
      return resolution(comment, record.path, "attached", exact.line_start, exact.line_end, record.bufnr)
    end

    local normalized, normalized_ambiguous = choose_candidate(content_candidates(anchor, current_lines, true))
    if normalized then
      move_extmark(record, normalized.line_start, normalized.line_end)
      record.status = "modified"
      return resolution(comment, record.path, "modified", normalized.line_start, normalized.line_end, record.bufnr)
    end

    local projected = diff_projection({
      base_line_start = record.snapshot_line_start,
      base_line_end = record.snapshot_line_end,
    }, record.snapshot_text, current_text)
    if projected and projected.status ~= "deleted" then
      move_extmark(record, projected.line_start, projected.line_end)
      record.status = projected.status
      return resolution(
        comment,
        record.path,
        projected.status,
        projected.line_start,
        projected.line_end,
        record.bufnr
      )
    end
    return resolution(comment, record.path, (exact_ambiguous or normalized_ambiguous) and "ambiguous" or "deleted")
  end
  return resolution(comment, record.path, range.status, range.line_start, range.line_end, record.bufnr)
end

local function bind_extmark(comment)
  if not comment.anchor_resolved or not comment.anchor_bufnr then
    return
  end
  local key = anchor_key(comment)
  if not key then
    return
  end
  local existing = live[key]
  if existing and existing.bufnr == comment.anchor_bufnr then
    return
  end
  if existing and vim.api.nvim_buf_is_valid(existing.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, existing.bufnr, ns, existing.id)
  end

  local bufnr = comment.anchor_bufnr
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local start_row = math.max(0, math.min(comment.line_start - 1, line_count - 1))
  local end_row, end_col, empty = extmark_end(bufnr, comment.line_end)
  local allow_empty = start_row == end_row and empty
  local id = vim.api.nvim_buf_set_extmark(bufnr, ns, start_row, 0, {
    end_row = end_row,
    end_col = end_col,
    right_gravity = true,
    end_right_gravity = false,
    invalidate = true,
    undo_restore = true,
    strict = false,
  })
  local snapshot_text = buffer_text(bufnr)
  live[key] = {
    bufnr = bufnr,
    id = id,
    path = comment.file,
    status = comment.anchor_reason or comment.anchor_status,
    allow_empty = allow_empty,
    snapshot_text = snapshot_text,
    snapshot_line_start = comment.line_start,
    snapshot_line_end = comment.line_end,
    anchor = vim.deepcopy(comment.anchor),
  }
end

legacy_anchor = function(comment)
  return {
    version = 0,
    path = comment.file,
    start = { line = comment.line_start, column = 0 },
    finish = { line = comment.line_end, column = 0 },
    selected = vim.deepcopy(comment.context_lines or {}),
    before = {},
    after = {},
  }
end

--- Capture an immutable anchor for a new comment.
---@param context table
---@return table
function M.capture(context)
  local bufnr = context.bufnr
  local name = vim.api.nvim_buf_get_name(bufnr)
  local root = git_root(name)
  local path = root and relative_path(root, name) or context.file
  local text = buffer_text(bufnr)
  local base_commit = root and run_git(root, { "rev-parse", "HEAD" }) or nil
  base_commit = base_commit and vim.trim(base_commit) or nil
  local base_blob = base_commit and run_git(root, { "rev-parse", base_commit .. ":" .. path }) or nil
  base_blob = base_blob and vim.trim(base_blob) or nil
  local base_text = base_blob and run_git(root, { "cat-file", "blob", base_blob }) or nil
  local clean = base_text ~= nil and base_text == text

  -- Edits elsewhere in a file should not discard usable Git provenance.
  -- Project backwards only if the selected range itself is unchanged.
  local base_range = clean and { status = "attached", line_start = context.line_start, line_end = context.line_end }
    or (base_text and diff_projection({ base_line_start = context.line_start, base_line_end = context.line_end }, text, base_text))
  if base_range and base_range.status ~= "attached" then base_range = nil end

  return {
    version = 1,
    path = path,
    base_commit = base_commit,
    base_blob = base_blob,
    buffer_hash = hash(text),
    start = { line = context.line_start, column = context.start_col or 0 },
    finish = { line = context.line_end, column = context.end_col or 0 },
    base_line_start = base_range and base_range.line_start or nil,
    base_line_end = base_range and base_range.line_end or nil,
    selected = vim.deepcopy(context.lines or {}),
    before = vim.deepcopy(context.before_lines or {}),
    after = vim.deepcopy(context.after_lines or {}),
  }
end

--- Resolve a stored comment against the current checkout or live buffer.
---@param comment table
---@param preserve_cache boolean? Keep the current batch's Git path cache
---@return table
function M.resolve(comment, preserve_cache)
  if not M.valid(comment) then
    return resolution(comment, nil, "invalid-anchor")
  end
  if not preserve_cache then
    path_cache = {}
    diff_cache = {}
    content_cache = {}
  end
  local live_comment = live_resolution(comment)
  if live_comment then
    return live_comment
  end

  -- Comments written before versioned anchors existed retain their original
  -- fixed-position behavior. If the file is available below, their stored
  -- context can still improve the location, but a missing file must not make
  -- legacy in-memory comments disappear from location-based operations.
  if not comment.anchor and vim.fn.filereadable(comment.file) == 0 and vim.fn.bufloaded(comment.file) == 0 then
    return resolution(comment, comment.file, "attached", comment.line_start, comment.line_end)
  end

  local anchor = comment.anchor or legacy_anchor(comment)
  local root = git_root(vim.fn.getcwd()) or vim.fn.getcwd()
  local path = resolve_path(anchor, root)
  if not path then
    if anchor.version == 0 then
      return resolution(comment, anchor.path, "attached", comment.line_start, comment.line_end)
    end
    return resolution(comment, anchor.path, "missing-file")
  end

  local target = target_content(root, path)
  if not target then
    if anchor.version == 0 then
      return resolution(comment, path, "attached", comment.line_start, comment.line_end)
    end
    return resolution(comment, path, "missing-file")
  end

  if anchor.buffer_hash and hash(target.text) == anchor.buffer_hash then
    local exact = resolution(
      comment,
      path,
      "attached",
      anchor.start and anchor.start.line or comment.line_start,
      anchor.finish and anchor.finish.line or comment.line_end,
      target.bufnr
    )
    bind_extmark(exact)
    return exact
  end

  local exact_candidates = content_candidates(anchor, target.lines, false)
  local exact, exact_ambiguous = choose_candidate(exact_candidates)
  if exact then
    local resolved = resolution(comment, path, "attached", exact.line_start, exact.line_end, target.bufnr)
    bind_extmark(resolved)
    return resolved
  end

  local normalized_candidates = content_candidates(anchor, target.lines, true)
  local normalized, normalized_ambiguous = choose_candidate(normalized_candidates)
  if normalized then
    local resolved = resolution(comment, path, "modified", normalized.line_start, normalized.line_end, target.bufnr)
    bind_extmark(resolved)
    return resolved
  end

  local projected = nil
  if anchor.base_blob and anchor.base_line_start then
    local base_text = run_git(root, { "cat-file", "blob", anchor.base_blob })
    if base_text then
      projected = diff_projection(anchor, base_text, target.text)
    end
  end
  if projected and projected.status == "attached" then
    local resolved = resolution(comment, path, "attached", projected.line_start, projected.line_end, target.bufnr)
    bind_extmark(resolved)
    return resolved
  elseif projected and projected.status == "modified" and not exact_ambiguous and not normalized_ambiguous then
    local score = context_score(anchor, target.lines, projected.line_start, projected.line_end, false)
    local has_context = #(anchor.before or {}) + #(anchor.after or {}) > 0
    if score > 0 or not has_context then
      local resolved = resolution(
        comment,
        path,
        "modified",
        projected.line_start,
        projected.line_end,
        target.bufnr
      )
      bind_extmark(resolved)
      return resolved
    end
  elseif projected and projected.status == "deleted" then
    return resolution(comment, path, "deleted")
  end

  if exact_ambiguous or normalized_ambiguous then
    return resolution(comment, path, "ambiguous")
  end
  local surrounded = context_range(anchor, target.lines)
  if surrounded then
    local resolved = resolution(comment, path, surrounded.status, surrounded.line_start, surrounded.line_end, target.bufnr)
    bind_extmark(resolved)
    return resolved
  end

  if anchor.version == 0 and comment.line_start <= #target.lines then
    local resolved = resolution(comment, path, "modified", comment.line_start, comment.line_end, target.bufnr)
    bind_extmark(resolved)
    return resolved
  end
  return resolution(comment, path, "unresolved")
end

function M.resolve_all(comments)
  -- A checkout or working-tree rename may have happened since the previous UI
  -- refresh. Keep caching scoped to this batch so comments sharing an anchor do
  -- not repeat Git work without retaining stale path mappings across refreshes.
  path_cache = {}
  diff_cache = {}
  content_cache = {}
  local resolved = {}
  local threads = {}
  for _, comment in ipairs(comments) do
    local key = anchor_key(comment)
    local previous = key and threads[key]
    if previous and vim.deep_equal(previous.anchor, comment.anchor) then
      local copy = vim.deepcopy(comment)
      for _, field in ipairs({ "file", "line_start", "line_end", "anchor_status", "anchor_reason", "anchor_resolved", "anchor_bufnr" }) do
        copy[field] = previous[field]
      end
      table.insert(resolved, copy)
    else
      local ok, result = pcall(M.resolve, comment, true)
      if not ok then
        local err = result
        result = resolution(comment, nil, "resolution-error")
        result.anchor_error = tostring(err)
      end
      if key then threads[key] = result end
      table.insert(resolved, result)
    end
  end
  return resolved
end

function M.is_attached(comment)
  return comment.anchor_status == nil or comment.anchor_status == "attached" or comment.anchor_status == "modified"
end

--- Install a worker result; Neovim objects belong only to the editor process.
function M.apply_snapshot(comments)
  local retained = {}
  local buffers = M.buffer_map()
  for _, comment in ipairs(comments) do
    local key = anchor_key(comment)
    local record = key and live[key]
    local range = record and range_from_extmark(record)
    if range and record.path == comment.file and vim.deep_equal(record.anchor, comment.anchor) then
      -- Extmarks are stronger evidence than a new content search, including
      -- ambiguous duplicate lines. Retain invalid marks too: undo restores
      -- them, whereas replacing them on each refresh loses that history.
      comment.anchor_bufnr = record.bufnr
      comment.line_start = range.line_start or comment.line_start
      comment.line_end = range.line_end or comment.line_end
      comment.anchor_resolved = range.status ~= "deleted"
      comment.anchor_status = comment.anchor_resolved and "attached" or "detached"
      comment.anchor_reason = range.status
    else
      if record and vim.api.nvim_buf_is_valid(record.bufnr) then
        pcall(vim.api.nvim_buf_del_extmark, record.bufnr, ns, record.id)
      end
      if key then live[key] = nil end
      comment.anchor_bufnr = buffers[comment.file]
      bind_extmark(comment)
    end
    if key then retained[key] = true end
  end
  for key, record in pairs(live) do
    if not retained[key] then
      if vim.api.nvim_buf_is_valid(record.bufnr) then
        pcall(vim.api.nvim_buf_del_extmark, record.bufnr, ns, record.id)
      end
      live[key] = nil
    end
  end
end

--- Read moving extmark positions without Git, disk IO, or content scans.
function M.current_positions(comments)
  local result = vim.deepcopy(comments)
  for _, comment in ipairs(result) do
    local record = live[anchor_key(comment)]
    local range = record and range_from_extmark(record)
    if range then
      comment.line_start = range.line_start or comment.line_start
      comment.line_end = range.line_end or comment.line_end
      comment.anchor_resolved = range.status ~= "deleted"
      comment.anchor_status = comment.anchor_resolved and "attached" or "detached"
      comment.anchor_reason = range.status
    end
  end
  return result
end

function M.find_buffer(path)
  local root = git_root(vim.fn.getcwd()) or vim.fn.getcwd()
  return find_buffer(root, path)
end

function M.absolute_file(path)
  return absolute_path(git_root(vim.fn.getcwd()) or vim.fn.getcwd(), path)
end

function M.buffer_map()
  local root = git_root(vim.fn.getcwd()) or vim.fn.getcwd()
  local buffers = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" then
        buffers[name] = bufnr
        buffers[relative_path(root, name)] = bufnr
      end
    end
  end
  return buffers
end

function M.detach_buffer(bufnr)
  buffer_cache[bufnr] = nil
  for key, record in pairs(live) do
    if record.bufnr == bufnr then
      live[key] = nil
    end
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  end
end

function M.invalidate_cache()
  path_cache = {}
  diff_cache = {}
  root_cache = {}
  content_cache = {}
end

function M.clear()
  for _, record in pairs(live) do
    if vim.api.nvim_buf_is_valid(record.bufnr) then
      pcall(vim.api.nvim_buf_del_extmark, record.bufnr, ns, record.id)
    end
  end
  live = {}
  path_cache = {}
  diff_cache = {}
  root_cache = {}
  buffer_cache = {}
  content_cache = {}
end

M._content_candidates = content_candidates
M._diff_projection = diff_projection
M._parse_name_status = parse_name_status

return M
