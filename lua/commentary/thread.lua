---@class CommentaryComment
---@field id string Comment ID
---@field thread_id string Thread this comment belongs to
---@field parent_id string|nil Parent comment ID (nil for root comments)
---@field file string File path
---@field line_start number Start line
---@field line_end number End line
---@field comment string Comment text
---@field author string Comment author
---@field timestamp number Creation timestamp
---@field context_lines table Context lines from the file
---@field replies table List of reply comment IDs

local M = {}

local function sort_comments(comments)
  local original_position = {}
  for index, comment in ipairs(comments) do
    original_position[comment.id] = index
  end

  table.sort(comments, function(a, b)
    if (a.timestamp or 0) ~= (b.timestamp or 0) then
      return (a.timestamp or 0) < (b.timestamp or 0)
    end
    return original_position[a.id] < original_position[b.id]
  end)
end

--- Create a reply to a comment
---@param parent_comment table The parent comment
---@param reply_text string The reply text
---@param author string The author of the reply
---@return table reply
function M.create_reply(parent_comment, reply_text, author)
  local reply_id = vim.fn.localtime() .. "_reply_" .. math.random(1000, 9999)

  return {
    id = reply_id,
    thread_id = parent_comment.thread_id,
    parent_id = parent_comment.id, -- Keep for internal use, but not saved to frontmatter
    file = parent_comment.file,
    line_start = parent_comment.line_start,
    line_end = parent_comment.line_end,
    comment = reply_text,
    author = author or vim.fn.expand("$USER"),
    timestamp = os.time(),
    context_lines = parent_comment.context_lines, -- Inherit context from parent
    anchor = parent_comment.anchor and vim.deepcopy(parent_comment.anchor) or nil,
    replies = {},
  }
end

--- Build thread structure from flat comment list
---@param comments table[] List of comments
---@return table threads Thread structure with linear replies
function M.build_thread_tree(comments)
  local threads = {}
  local comment_map = {}

  -- First pass: create comment map
  for _, comment in ipairs(comments) do
    comment_map[comment.id] = vim.deepcopy(comment)
  end

  -- Second pass: organize into threads
  for _, comment in pairs(comment_map) do
    if not comment.parent_id then
      -- Root comment - create thread
      local thread_id = comment.thread_id or (comment.id .. "_thread")
      threads[thread_id] = {
        id = thread_id,
        root_comment = comment,
        replies = {}, -- Linear list of replies
      }
    end
  end

  -- Third pass: add replies to threads in chronological order
  for _, comment in ipairs(comments) do
    if comment.parent_id and comment.thread_id then
      local thread = threads[comment.thread_id]
      if thread then
        table.insert(thread.replies, comment)
      end
    end
  end

  for _, thread in pairs(threads) do
    sort_comments(thread.replies)
  end

  return threads
end

--- Flatten thread structure to comment list
---@param threads table Thread structure
---@return table[] comments Flat list of comments
function M.flatten_thread_tree(threads)
  local comments = {}

  for _, thread in pairs(threads) do
    if thread.root_comment then
      -- Add root comment
      table.insert(comments, thread.root_comment)

      -- Add all replies in order
      if thread.replies then
        for _, reply in ipairs(thread.replies) do
          table.insert(comments, reply)
        end
      end
    end
  end

  return comments
end

--- Get all comments in a thread
---@param thread_id string
---@param comments table[] All comments
---@return table[] thread_comments
function M.get_thread_comments(thread_id, comments)
  local thread_comments = {}

  for _, comment in ipairs(comments) do
    if comment.thread_id == thread_id then
      table.insert(thread_comments, comment)
    end
  end

  return thread_comments
end

--- Return a comment and every later comment in its linear thread.
---@param target table
---@param comments table[]
---@return table[]
function M.get_comment_and_followups(target, comments)
  if not target.thread_id then
    return { target }
  end

  local thread_comments = M.get_thread_comments(target.thread_id, comments)
  sort_comments(thread_comments)

  if not target.parent_id then
    return thread_comments
  end

  local followups = {}
  local found = false
  for _, comment in ipairs(thread_comments) do
    if comment.id == target.id then
      found = true
    end
    if found then
      table.insert(followups, comment)
    end
  end
  return followups
end

return M
