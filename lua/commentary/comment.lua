local M = {}

local state = require("commentary.state")
local utils = require("commentary.utils")
local ui = require("commentary.ui")
local anchor = require("commentary.anchor")

-- Create namespaces once at module load
local ns_virtual_text = vim.api.nvim_create_namespace("CommentaryVirtualText")
local ns_context = vim.api.nvim_create_namespace("commentary_context")

--- Add a comment at the current location
---@param context_lines number? Number of context lines
function M.add(context_lines)
  -- Get the current selection context
  local context = utils.get_selection_context(context_lines)

  -- Create namespace for highlighting
  local bufnr = vim.api.nvim_get_current_buf()

  -- Clear previous highlights
  vim.api.nvim_buf_clear_namespace(bufnr, ns_context, 0, -1)

  -- Highlight the context range (always highlight at least the current line/selection)
  for line = context.line_start - 1, context.line_end - 1 do
    vim.api.nvim_buf_add_highlight(bufnr, ns_context, "Visual", line, 0, -1)
  end

  local saved_id

  -- Show input UI and get comment text
  ui.show_comment_input(function(comment_text)
    -- Clear highlights when done
    vim.api.nvim_buf_clear_namespace(bufnr, ns_context, 0, -1)

    if not comment_text or comment_text == "" then
      return false
    end

    if saved_id then
      return state.update_comment(saved_id, { comment = comment_text })
    end

    -- Always create a new comment (new thread)
    local comment_data = {
      file = context.file,
      line_start = context.line_start,
      line_end = context.line_end,
      comment = comment_text,
      context_lines = context.lines,
      anchor = anchor.capture(context),
    }

    -- Add to state (state will handle UI refresh)
    saved_id = state.add_comment(comment_data)

    -- Copy to clipboard if enabled
    local config = require("commentary.config")
    if config.get("comment.auto_copy_on_add") and comment_data then
      local formatter = require("commentary.formatter")
      local formatted_text = formatter.format({ comment_data })
      utils.copy_to_clipboard(formatted_text)
    end

    vim.notify(
      string.format(
        "Comment added to %s:%d%s",
        context.file,
        context.line_start,
        context.line_start ~= context.line_end and "-" .. context.line_end or ""
      )
    )
    return saved_id ~= nil
  end, context)
end

-- Forward declarations
local add_signs
local add_virtual_text

--- Update visual indicators (signs and virtual text)
function M.update_indicators()
  local config = require("commentary.config")
  local comments = state.get_comments()

  -- Clear existing indicators
  M.clear_indicators()

  -- Group comments by buffer
  local comments_by_buf = {}
  for _, comment in ipairs(comments) do
    if anchor.is_attached(comment) then
      local bufnr = comment.anchor_bufnr or anchor.find_buffer(comment.file)
      if bufnr then
        comments_by_buf[bufnr] = comments_by_buf[bufnr] or {}
        table.insert(comments_by_buf[bufnr], comment)
      end
    end
  end

  -- Add indicators for each buffer
  for bufnr, buf_comments in pairs(comments_by_buf) do
    if config.get("ui.signs.enabled") then
      add_signs(bufnr, buf_comments)
    end
    if config.get("ui.virtual_text.enabled") then
      add_virtual_text(bufnr, buf_comments)
    end
  end
end

--- Clear all indicators
function M.clear_indicators()
  -- Clear signs from all buffers
  -- Using pcall to handle different Neovim versions
  local ok, _ = pcall(vim.fn.sign_unplace, "CommentarySigns", {})
  if not ok then
    -- Fallback: clear signs buffer by buffer
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.fn.sign_unplace, "CommentarySigns", { buffer = buf })
      end
    end
  end

  -- Clear virtual text
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns_virtual_text, 0, -1)
    end
  end
end

--- Add signs to buffer
---@param bufnr number
---@param comments table[]
add_signs = function(bufnr, comments)
  local config = require("commentary.config").get("ui.signs")

  -- Remove existing signs first
  vim.fn.sign_unplace("CommentarySigns", { buffer = bufnr })

  vim.fn.sign_define("CommentaryComment", {
    text = config.text,
    texthl = config.texthl,
    linehl = config.linehl,
    numhl = config.numhl,
  })

  local lines = {}
  for _, comment in ipairs(comments) do
    for line = comment.line_start, comment.line_end do
      lines[line] = true
    end
  end

  for line in pairs(lines) do
    vim.fn.sign_place(0, "CommentarySigns", "CommentaryComment", bufnr, { lnum = line, priority = 100 })
  end
end

--- Add virtual text to buffer
---@param bufnr number
---@param comments table[]
add_virtual_text = function(bufnr, comments)
  local config = require("commentary.config").get("ui.virtual_text")

  -- Group comments by line and thread for virtual text
  local threads_by_line = {}
  for _, comment in ipairs(comments) do
    -- Only show on first line of range
    local line = comment.line_start
    if not threads_by_line[line] then
      threads_by_line[line] = {}
    end

    -- Group by thread
    local thread_id = comment.thread_id or comment.id
    if not threads_by_line[line][thread_id] then
      threads_by_line[line][thread_id] = {}
    end
    table.insert(threads_by_line[line][thread_id], comment)
  end

  -- Add virtual text
  for line, line_threads in pairs(threads_by_line) do
    local thread_count = vim.tbl_count(line_threads)
    local text = ""
    local highlight = config.hl

    if thread_count > 1 then
      -- Multiple threads on same line
      text = config.prefix .. string.format("(%d threads)", thread_count)
    else
      -- Single thread - find the latest comment
      local _, thread_comments = next(line_threads)
      local latest_comment = thread_comments[#thread_comments]

      if thread_comments[1].timestamp then
        table.sort(thread_comments, function(a, b)
          return (a.timestamp or 0) < (b.timestamp or 0)
        end)
        latest_comment = thread_comments[#thread_comments]
      end

      local first_line = latest_comment.comment:match("^[^\n]*") or latest_comment.comment
      if #first_line > 40 then
        first_line = first_line:sub(1, 37) .. "..."
      end
      text = config.prefix .. first_line
    end

    -- Ensure buffer is loaded and line is valid
    if text ~= "" and vim.api.nvim_buf_is_loaded(bufnr) then
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      if line <= line_count then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_virtual_text, line - 1, 0, {
          virt_text = { { text, highlight } },
          virt_text_pos = "eol",
        })
      end
    end
  end
end

return M
