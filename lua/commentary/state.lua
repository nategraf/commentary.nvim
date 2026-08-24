local M = {}

-- Storage backend
local storage = nil
local initialized = false
local known_comments = nil

local function comment_fingerprint(comment)
  return vim.json.encode({
    file = comment.file,
    line_start = comment.line_start,
    line_end = comment.line_end,
    author = comment.author,
    timestamp = comment.timestamp,
    comment = comment.comment,
    thread_id = comment.thread_id,
    parent_id = comment.parent_id,
    thread_status = comment.thread_status,
    anchor = comment.anchor,
  })
end

local function comment_identity(comment, index)
  if comment.id then
    return tostring(comment.id)
  end

  return string.format(
    "%s\0%s\0%s\0%s\0%d",
    comment.file or "",
    comment.author or "",
    comment.timestamp or "",
    comment.comment or "",
    index
  )
end

local function index_comments(comments)
  local indexed = {}
  for index, comment in ipairs(comments) do
    indexed[comment_identity(comment, index)] = {
      comment = vim.deepcopy(comment),
      fingerprint = comment_fingerprint(comment),
    }
  end
  return indexed
end

local function remember_comments(comments)
  known_comments = index_comments(comments or storage.get_all())
end

local function reconcile_comments(comments)
  local current = index_comments(comments)
  local previous = known_comments or {}
  local changes = { added = {}, removed = {}, updated = {} }

  for id, entry in pairs(current) do
    local old_entry = previous[id]
    if not old_entry then
      table.insert(changes.added, entry.comment)
    elseif old_entry.fingerprint ~= entry.fingerprint then
      table.insert(changes.updated, {
        before = old_entry.comment,
        after = entry.comment,
      })
    end
  end

  for id, entry in pairs(previous) do
    if not current[id] then
      table.insert(changes.removed, entry.comment)
    end
  end

  local function by_location(a, b)
    local a_comment = a.after or a
    local b_comment = b.after or b
    if (a_comment.file or "") ~= (b_comment.file or "") then
      return (a_comment.file or "") < (b_comment.file or "")
    end
    if (a_comment.line_start or 0) ~= (b_comment.line_start or 0) then
      return (a_comment.line_start or 0) < (b_comment.line_start or 0)
    end
    return (a_comment.timestamp or 0) < (b_comment.timestamp or 0)
  end

  table.sort(changes.added, by_location)
  table.sort(changes.removed, by_location)
  table.sort(changes.updated, by_location)
  known_comments = current
  return changes
end

local function emit_changes(changes, source)
  if #changes.added == 0 and #changes.removed == 0 and #changes.updated == 0 then
    return
  end

  vim.api.nvim_exec_autocmds("User", {
    pattern = "CommentaryCommentsChanged",
    modeline = false,
    data = vim.tbl_extend("force", { source = source }, changes),
  })
end

local function finish_change(source, reported_changes)
  local observed_changes = reconcile_comments(storage.get_all())
  local changes = reported_changes or observed_changes
  M.refresh_ui()
  emit_changes(changes, source)
  return changes
end

--- Initialize storage backend
function M.init()
  if initialized then
    return
  end

  local config = require("commentary.config")
  local backend = config.get("comment.storage.backend")

  if backend == "file" then
    storage = require("commentary.storage.file")
  else
    storage = require("commentary.storage.memory")
  end

  storage.init()
  remember_comments(storage.get_all())
  initialized = true
end

--- Get storage backend
---@return table
local function get_storage()
  assert(initialized, "State not initialized. Call require('commentary').setup() first.")
  return storage
end

--- Check if review session is active
---@return boolean
function M.is_active()
  return get_storage().is_active()
end

--- Refresh UI elements (markers, etc.) after state changes
function M.refresh_ui()
  -- Update visual indicators (signs and virtual text)
  require("commentary.comment").update_indicators()

  -- Future: Update other UI elements like statusline, floating windows, etc.
end

--- Sync state from storage and report loaded changes.
---@param source string? Change source; defaults to "storage"
---@return table changes
function M.sync_from_storage(source)
  require("commentary.anchor").invalidate_cache()
  -- Explicitly reload storage if it has reload method
  if storage and storage.reload then
    storage.reload()
  end

  return finish_change(source or "storage")
end

--- Clear all comments but keep session active
function M.clear()
  get_storage().clear()
  require("commentary.anchor").clear()
  finish_change("editor")
  vim.notify("All comments cleared")
end

--- Add a comment to the session
---@param comment_data table Comment data
function M.add_comment(comment_data)
  local storage_backend = get_storage()

  -- Prepare metadata for root comments
  if not comment_data.parent_id then
    comment_data.author = comment_data.author or vim.fn.expand("$USER")
    comment_data.replies = {}
  end

  -- Add comment to storage (this will generate the real ID)
  local id = storage_backend.add(comment_data)

  -- For root comments, set thread_id
  if not comment_data.parent_id then
    local thread_id = id .. "_thread"

    -- Get the comment and update it with thread info
    local comment = storage_backend.get(id)
    if comment then
      comment.thread_id = thread_id
      -- Status is now managed by filename (if status_management is enabled), not in data

      -- Re-save with thread info
      storage_backend.delete(id)
      storage_backend.add(comment)
    end
  end

  finish_change("editor")
  return id
end

--- Get all comments
---@return table[]
function M.get_comments()
  return require("commentary.anchor").resolve_all(get_storage().get_all())
end

--- Get a specific comment by ID
---@param id string Comment ID
---@return table?
function M.get_comment(id)
  return get_storage().get(id)
end

--- Update a comment
---@param id string Comment ID
---@param updates table Fields to update
---@return boolean success
function M.update_comment(id, updates)
  local storage_backend = get_storage()
  local comment = storage_backend.get(id)
  if not comment then
    return false
  end

  -- Merge updates
  local updated_comment = vim.tbl_extend("force", comment, updates)
  -- Preserve id and timestamp
  updated_comment.id = comment.id
  updated_comment.timestamp = comment.timestamp

  if storage_backend.update then
    if storage_backend.update(id, updated_comment) then
      finish_change("editor")
      return true
    end
    return false
  end

  -- Compatibility fallback for third-party storage backends.
  if storage_backend.delete(id) then
    storage_backend.add(updated_comment)
    finish_change("editor")
    return true
  end
  return false
end

--- Delete a comment
---@param id string Comment ID
---@return boolean success
function M.delete_comment(id)
  local storage_backend = get_storage()
  local deleted_comment = storage_backend.get(id)
  local success = storage_backend.delete(id)
  if success then
    local reported_changes = nil
    if deleted_comment and deleted_comment.parent_id then
      -- Legacy thread files derive reply IDs from their position. Rewriting a
      -- thread can therefore renumber later replies; report the logical
      -- deletion rather than those storage-level identity changes.
      reported_changes = {
        added = {},
        removed = { deleted_comment },
        updated = {},
      }
    end
    finish_change("editor", reported_changes)
  end
  return success
end

--- Replace all comments (used for preview editing)
---@param new_comments table[] New comments array
function M.replace_comments(new_comments)
  local storage_backend = get_storage()

  require("commentary.anchor").clear()

  -- Clear existing comments
  storage_backend.clear()

  -- Add all new comments
  for _, comment in ipairs(new_comments) do
    storage_backend.add(comment)
  end

  finish_change("editor")
end

--- Get session metadata
---@return table
function M.get_metadata()
  local comments = get_storage().get_all()
  return {
    start_time = os.time(), -- For file storage, we don't track session start time
    comment_count = #comments,
  }
end

--- Get comments at specific location
---@param file string
---@param line number
---@return table[]
function M.get_comments_at_location(file, line)
  local results = {}
  local anchor = require("commentary.anchor")
  for _, comment in ipairs(M.get_comments()) do
    if anchor.is_attached(comment) and comment.file == file and line >= comment.line_start and line <= comment.line_end then
      table.insert(results, comment)
    end
  end
  return results
end

--- Add a reply to a comment
---@param parent_id string Parent comment ID (can be any comment in the thread)
---@param reply_text string Reply text
---@return string|nil reply_id
function M.add_reply(parent_id, reply_text)
  local parent = M.get_comment(parent_id)
  if not parent then
    vim.notify("Parent comment not found", vim.log.levels.ERROR)
    return nil
  end

  local thread = require("commentary.thread")

  -- Always create a reply to the thread, not nested under specific comment
  local reply = thread.create_reply(parent, reply_text)

  -- Add the reply
  local id = get_storage().add(reply)

  finish_change("editor")
  return id
end

--- Get all comments in a thread
---@param thread_id string Thread ID
---@return table[] comments
function M.get_thread_comments(thread_id)
  local all_comments = M.get_comments()
  local thread = require("commentary.thread")
  return thread.get_thread_comments(thread_id, all_comments)
end

--- Resolve a thread
---@param thread_id string Thread ID
---@return boolean success
function M.resolve_thread(thread_id)
  local storage_backend = get_storage()
  local resolved_by = vim.fn.expand("$USER")
  local success = storage_backend.update_thread_status(thread_id, "resolved", resolved_by)

  if success then
    finish_change("editor")
    vim.notify("Thread resolved", vim.log.levels.INFO)
  else
    -- Check if status management is disabled
    local config = require("commentary.config")
    if config.get("comment.storage.backend") == "file" and not config.get("comment.status_management") then
      vim.notify("Status management is disabled. Enable 'status_management' to resolve threads.", vim.log.levels.WARN)
    end
  end

  return success
end

--- Reopen a thread
---@param thread_id string Thread ID
---@return boolean success
function M.reopen_thread(thread_id)
  local storage_backend = get_storage()
  local success = storage_backend.update_thread_status(thread_id, "open", nil)

  if success then
    finish_change("editor")
    vim.notify("Thread reopened", vim.log.levels.INFO)
  else
    -- Check if status management is disabled
    local config = require("commentary.config")
    if config.get("comment.storage.backend") == "file" and not config.get("comment.status_management") then
      vim.notify("Status management is disabled. Enable 'status_management' to reopen threads.", vim.log.levels.WARN)
    end
  end

  return success
end

--- Get all thread statuses
---@return table<string, table>
function M.get_all_threads()
  local storage_backend = get_storage()
  if storage_backend.get_all_threads then
    return storage_backend.get_all_threads()
  end
  return {}
end

--- Get storage backend (for internal use)
---@return table storage
function M.get_storage()
  return get_storage()
end

--- Reset internal state (for testing purposes)
---@private
function M._reset()
  require("commentary.anchor").clear()
  initialized = false
  storage = nil
  known_comments = nil
end

return M
