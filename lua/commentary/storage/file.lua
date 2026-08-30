local M = {}

local utils = require("commentary.utils")

local storage_dir = nil
local comments_cache = nil
local cache_timestamp = 0

--- Parse a comment ID from its filename.
---@param filename string
---@return string? id
local function parse_id(filename)
  return filename:match("^(.+)%.md$")
end

--- Get storage directory
---@return string
local function get_storage_dir()
  if storage_dir then
    return storage_dir
  end

  local config = require("commentary.config")
  local dir = config.get("comment.storage.file.dir")
  storage_dir = utils.get_storage_dir(dir)
  return storage_dir
end

--- Generate filename for a comment
---@param comment_data table
---@return string
local function get_comment_filename(comment_data)
  if comment_data.id then
    return comment_data.id .. ".md"
  end

  return utils.generate_auto_save_filename()
end

--- Parse comment from file content
---@param content string
---@param filename string
---@return table[] comments
local function parse_comment_from_file(content, filename)
  local base_id = parse_id(filename)
  if not base_id then
    return {}
  end

  local lines = vim.split(content, "\n", { plain = true })
  local state = "start"
  local frontmatter = {}
  local context_lines = {}
  local anchor = nil
  local in_context_code = false
  local comments = {}

  -- Variables for parsing multiple comments
  local current_comment = nil
  local current_comment_lines = {}
  local in_comments_section = false

  for _, line in ipairs(lines) do
    if state == "start" and line == "---" then
      state = "frontmatter"
    elseif state == "frontmatter" and line == "---" then
      if frontmatter.anchor then
        local ok, decoded = pcall(vim.json.decode, frontmatter.anchor)
        if ok and type(decoded) == "table" then
          anchor = decoded
        end
      end
      state = "content"
    elseif state == "frontmatter" then
      -- Parse YAML line
      local key, value = line:match("^([^:]+):%s*(.+)$")
      if key and value then
        frontmatter[key] = value
      end
    elseif state == "content" then
      if line == "## Context" then
        state = "context"
      elseif line == "## Comments" then
        -- Multi-comment format
        state = "comments"
        in_comments_section = true
      end
    elseif state == "context" then
      if line == "## Comments" or line == "## Comment Thread" then
        state = "comments"
        in_comments_section = true
      elseif line:match("^```") then
        in_context_code = not in_context_code
      elseif in_context_code then
        table.insert(context_lines, line)
      end
    elseif state == "comment" then
      -- Old format: single comment
      table.insert(current_comment_lines, line)
    elseif state == "comments" then
      -- New format: multiple comments
      if line:match("^### ") then
        -- Save previous comment if exists
        if current_comment and #current_comment_lines > 0 then
          current_comment.comment = vim.trim(table.concat(current_comment_lines, "\n"))
          table.insert(comments, current_comment)
          current_comment_lines = {}
        end

        -- Parse comment header: "### Author - Timestamp"
        local header = line:sub(5) -- Remove "### "
        local author, timestamp_str = header:match("^(.+) %- (.+)$")
        local parsed_author = author or vim.fn.expand("$USER")

        -- Parse timestamp from string (format: "2025-07-08 10:43:54")
        local parsed_timestamp
        if timestamp_str then
          local year, month, day, hour, min, sec = timestamp_str:match("(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)")
          if year then
            parsed_timestamp = os.time({
              year = tonumber(year),
              month = tonumber(month),
              day = tonumber(day),
              hour = tonumber(hour),
              min = tonumber(min),
              sec = tonumber(sec),
            })
          else
            parsed_timestamp = os.time()
          end
        else
          parsed_timestamp = os.time()
        end

        -- Start new comment
        current_comment = {
          id = base_id .. "_comment_" .. #comments,
          file = frontmatter.file or "",
          line_start = tonumber(frontmatter.line_start) or 0,
          line_end = tonumber(frontmatter.line_end) or 0,
          author = parsed_author,
          timestamp = parsed_timestamp,
          context_lines = context_lines,
          anchor = anchor and vim.deepcopy(anchor) or nil,
          thread_id = frontmatter.thread_id,
        }
      elseif line == "---" and in_comments_section then -- luacheck: ignore 542
        -- Comment separator, ignore
      elseif line == "" and not current_comment then -- luacheck: ignore 542
        -- Empty line before first comment, ignore
      else
        -- Comment content
        table.insert(current_comment_lines, line)
      end
    end
  end

  -- Handle last comment
  if current_comment and #current_comment_lines > 0 then
    -- Save last comment in multi-comment format
    current_comment.comment = vim.trim(table.concat(current_comment_lines, "\n"))
    table.insert(comments, current_comment)
  end

  -- Reconstruct the flat thread relationship represented by this one file.
  -- Parent IDs are intentionally omitted from the Markdown format, so every
  -- comment after the first is a reply to the root comment.
  if #comments > 0 and comments[1] then
    comments[1].id = base_id
    for index = 2, #comments do
      comments[index].parent_id = base_id
    end
  end

  return comments
end

--- Load all comments from storage directory
---@return table[]
local function load_comments()
  local dir = get_storage_dir()

  -- Check if directory exists
  if vim.fn.isdirectory(dir) == 0 then
    return {}
  end

  -- Check cache validity
  local dir_mtime = vim.fn.getftime(dir)
  if comments_cache and dir_mtime <= cache_timestamp then
    return comments_cache
  end

  local comments = {}

  -- Read all .md files in the directory
  local files = vim.fn.glob(dir .. "/*.md", false, true)
  for _, filepath in ipairs(files) do
    -- Use io.open to preserve trailing newlines
    local file = io.open(filepath, "r")
    if file then
      local content = file:read("*a")
      file:close()

      if content and #content > 0 then
        local filename = vim.fn.fnamemodify(filepath, ":t")
        local parsed_comments = parse_comment_from_file(content, filename)
        -- parse_comment_from_file now returns an array of comments
        for _, comment_data in ipairs(parsed_comments) do
          table.insert(comments, comment_data)
        end
      end
    end
  end

  -- Update cache
  comments_cache = comments
  cache_timestamp = dir_mtime

  return comments
end

--- Invalidate cache
local function invalidate_cache()
  comments_cache = nil
  cache_timestamp = 0
end

--- Reload before a read-modify-write operation. Updating an existing thread
--- file does not change the storage directory mtime, so the normal read cache
--- cannot establish that its contents are current.
---@return table[] comments
local function load_comments_for_update()
  invalidate_cache()
  return load_comments()
end

--- Ensure storage directory exists (lazy creation)
---@return string dir
local function ensure_storage_dir()
  local dir = get_storage_dir()
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  return dir
end

--- Initialize storage
function M.init()
  -- Only run migration if storage directory already exists
  local dir = get_storage_dir()
  if vim.fn.isdirectory(dir) == 0 then
    return
  end

  -- Migrate comments from comments/ subdirectory back to root
  local comments_dir = dir .. "/comments"
  if vim.fn.isdirectory(comments_dir) == 1 then
    local comment_files = vim.fn.glob(comments_dir .. "/*.md", false, true)
    for _, filepath in ipairs(comment_files) do
      local filename = vim.fn.fnamemodify(filepath, ":t")
      local new_filepath = dir .. "/" .. filename
      -- Move file to root directory
      if vim.fn.filereadable(new_filepath) == 0 then
        vim.fn.rename(filepath, new_filepath)
      end
    end
    -- Remove empty comments directory
    vim.fn.delete(comments_dir, "d")
  end
end

--- Check if storage is active
---@return boolean
function M.is_active()
  return true -- File storage is always active once initialized
end

--- Add a comment
---@param comment_data table
---@return string id
function M.add(comment_data)
  -- Add metadata
  comment_data.timestamp = comment_data.timestamp or os.time()

  -- If this is a reply, update the root comment's file instead
  if comment_data.parent_id and comment_data.thread_id then
    -- Find the root comment of this thread
    local comments = load_comments_for_update()
    local root_comment = nil

    for _, comment in ipairs(comments) do
      if comment.thread_id == comment_data.thread_id and not comment.parent_id then
        root_comment = comment
        break
      elseif not comment.parent_id and comment.id .. "_thread" == comment_data.thread_id then
        -- Fallback: check if comment ID + "_thread" matches thread_id
        root_comment = comment
        break
      end
    end

    if root_comment then
      -- Get all comments in this thread
      local thread_comments = {}
      for _, comment in ipairs(comments) do
        if comment.thread_id == comment_data.thread_id then
          table.insert(thread_comments, comment)
        end
      end

      -- Add the new reply
      table.insert(thread_comments, comment_data)

      -- Sort by timestamp to maintain chronological order
      table.sort(thread_comments, function(a, b)
        return (a.timestamp or 0) < (b.timestamp or 0)
      end)

      local filepath = get_storage_dir() .. "/" .. root_comment.id .. ".md"

      -- Format content
      local formatted_text = M.format_thread_as_markdown(thread_comments)

      if utils.save_to_file(filepath, formatted_text) then
        invalidate_cache()
        return comment_data.id
      else
        error("Failed to save reply to file")
      end
    end
  end

  -- For new comments (not replies), create a new file
  local dir = ensure_storage_dir()
  local filename = get_comment_filename(comment_data)
  comment_data.id = parse_id(filename)

  local filepath = dir .. "/" .. filename

  -- Format the comment with full context
  local formatted_text = M.format_comment_as_markdown(comment_data)

  if utils.save_to_file(filepath, formatted_text) then
    invalidate_cache()
    return comment_data.id
  else
    error("Failed to save comment to file")
  end
end

--- Get all comments
---@return table[]
function M.get_all()
  return load_comments()
end

--- Get a specific comment by ID
---@param id string
---@return table|nil
function M.get(id)
  local comments = load_comments()
  for _, comment in ipairs(comments) do
    if comment.id == id then
      return vim.deepcopy(comment)
    end
  end
  return nil
end

--- Update a comment while preserving the rest of its thread
---@param id string Comment ID
---@param updates table Fields to update
---@return boolean success
function M.update(id, updates)
  local comments = load_comments_for_update()
  local target = nil

  for _, comment in ipairs(comments) do
    if comment.id == id then
      target = comment
      break
    end
  end

  if not target then
    return false
  end

  local root_id = target.id
  if target.thread_id then
    root_id = target.thread_id:match("^(.+)_thread$") or target.id
  end

  local thread_comments = {}
  for _, comment in ipairs(comments) do
    local in_thread = target.thread_id and comment.thread_id == target.thread_id
    if in_thread or (not target.thread_id and comment.id == target.id) then
      local updated_comment = vim.deepcopy(comment)
      if comment.id == id then
        updated_comment = vim.tbl_extend("force", updated_comment, updates)
        updated_comment.id = comment.id
        updated_comment.timestamp = comment.timestamp
      end
      table.insert(thread_comments, updated_comment)
    end
  end

  local filepath = get_storage_dir() .. "/" .. root_id .. ".md"
  if vim.fn.filereadable(filepath) == 0 then
    return false
  end

  local formatted_text
  if target.thread_id then
    formatted_text = M.format_thread_as_markdown(thread_comments)
  else
    formatted_text = M.format_comment_as_markdown(thread_comments[1])
  end

  if not utils.save_to_file(filepath, formatted_text) then
    return false
  end

  invalidate_cache()
  return true
end

--- Delete a comment by ID
---@param id string
---@return boolean success
function M.delete(id)
  local dir = get_storage_dir()

  local comments = load_comments_for_update()
  local target = nil
  for _, comment in ipairs(comments) do
    if comment.id == id then
      target = comment
      break
    end
  end

  -- Replies share their root comment's file. A thread is linear, so deleting
  -- a reply also deletes every later reply below it in that file.
  if target and target.parent_id and target.thread_id then
    local root_id = target.thread_id:match("^(.+)_thread$") or target.parent_id
    local filepath = dir .. "/" .. root_id .. ".md"
    if vim.fn.filereadable(filepath) == 0 then
      return false
    end

    local removed = require("commentary.thread").get_comment_and_followups(target, comments)
    local removed_ids = {}
    for _, comment in ipairs(removed) do
      removed_ids[comment.id] = true
    end

    local remaining = {}
    for _, comment in ipairs(comments) do
      if comment.thread_id == target.thread_id and not removed_ids[comment.id] then
        table.insert(remaining, comment)
      end
    end

    if #remaining == 0 then
      return false
    end

    if not utils.save_to_file(filepath, M.format_thread_as_markdown(remaining)) then
      return false
    end

    invalidate_cache()
    return true
  end

  local filepath = dir .. "/" .. id .. ".md"
  if vim.fn.filereadable(filepath) == 1 then
    vim.fn.delete(filepath)
    invalidate_cache()
    return true
  end

  return false
end

--- Clear all comments
function M.clear()
  local dir = get_storage_dir()
  local files = vim.fn.glob(dir .. "/*.md", false, true)

  for _, filepath in ipairs(files) do
    vim.fn.delete(filepath)
  end

  invalidate_cache()
end

--- Get comments for a specific file and line range
---@param file string
---@param line number
---@return table[]
function M.get_at_location(file, line)
  local results = {}
  local comments = load_comments()

  for _, comment in ipairs(comments) do
    if comment.file == file and line >= comment.line_start and line <= comment.line_end then
      table.insert(results, vim.deepcopy(comment))
    end
  end

  return results
end

--- Format a comment as markdown (simplified version to avoid circular dependency)
---@param comment_data table
---@return string
function M.format_comment_as_markdown(comment_data)
  local lines = {}
  local config = require("commentary.config")
  local date_format = config.get("output.date_format")

  -- YAML frontmatter
  table.insert(lines, "---")
  table.insert(lines, "file: " .. comment_data.file)
  table.insert(lines, "line_start: " .. comment_data.line_start)
  table.insert(lines, "line_end: " .. comment_data.line_end)
  if comment_data.anchor then
    table.insert(lines, "anchor: " .. vim.json.encode(comment_data.anchor))
  end
  table.insert(lines, "time: " .. os.date(date_format, comment_data.timestamp))

  if comment_data.author then
    table.insert(lines, "author: " .. comment_data.author)
  end

  if comment_data.thread_id then
    table.insert(lines, "thread_id: " .. comment_data.thread_id)
  end

  table.insert(lines, "---")
  table.insert(lines, "")

  -- Code context if available
  if comment_data.context_lines and #comment_data.context_lines > 0 then
    table.insert(lines, "## Context")
    table.insert(lines, "")
    table.insert(lines, "```" .. vim.fn.fnamemodify(comment_data.file, ":e"))
    for _, line in ipairs(comment_data.context_lines) do
      table.insert(lines, line)
    end
    table.insert(lines, "```")
    table.insert(lines, "")
  end

  -- Comments section (even for single comment, use consistent format)
  table.insert(lines, "## Comments")
  table.insert(lines, "")
  table.insert(
    lines,
    "### " .. (comment_data.author or vim.fn.expand("$USER")) .. " - " .. os.date(date_format, comment_data.timestamp)
  )
  table.insert(lines, "")
  table.insert(lines, comment_data.comment)

  return table.concat(lines, "\n")
end

--- Reload comments from storage (invalidate cache)
function M.reload()
  invalidate_cache()
end

--- Format a thread (multiple comments) as markdown
---@param thread_comments table[] Comments in the thread, sorted by timestamp
---@return string
function M.format_thread_as_markdown(thread_comments)
  if #thread_comments == 0 then
    return ""
  end

  local lines = {}
  local config = require("commentary.config")
  local date_format = config.get("output.date_format")

  -- Find the root comment (should be the first one)
  local root_comment = thread_comments[1]

  -- YAML frontmatter from root comment
  table.insert(lines, "---")
  table.insert(lines, "file: " .. root_comment.file)
  table.insert(lines, "line_start: " .. root_comment.line_start)
  table.insert(lines, "line_end: " .. root_comment.line_end)
  if root_comment.anchor then
    table.insert(lines, "anchor: " .. vim.json.encode(root_comment.anchor))
  end
  table.insert(lines, "time: " .. os.date(date_format, root_comment.timestamp))

  if root_comment.author then
    table.insert(lines, "author: " .. root_comment.author)
  end

  if root_comment.thread_id then
    table.insert(lines, "thread_id: " .. root_comment.thread_id)
  end

  table.insert(lines, "---")
  table.insert(lines, "")

  -- Code context (from root comment)
  if root_comment.context_lines and #root_comment.context_lines > 0 then
    table.insert(lines, "## Context")
    table.insert(lines, "")
    table.insert(lines, "```" .. vim.fn.fnamemodify(root_comment.file, ":e"))
    for _, line in ipairs(root_comment.context_lines) do
      table.insert(lines, line)
    end
    table.insert(lines, "```")
    table.insert(lines, "")
  end

  -- Comments section
  table.insert(lines, "## Comments")
  table.insert(lines, "")

  -- Add each comment in the thread
  for i, comment in ipairs(thread_comments) do
    if i > 1 then
      table.insert(lines, "")
      table.insert(lines, "---")
      table.insert(lines, "")
    end

    -- Comment metadata
    table.insert(
      lines,
      "### " .. (comment.author or vim.fn.expand("$USER")) .. " - " .. os.date(date_format, comment.timestamp)
    )
    table.insert(lines, "")

    -- Comment content
    table.insert(lines, comment.comment)
  end

  return table.concat(lines, "\n")
end

M._parse_comment_from_file = parse_comment_from_file

return M
