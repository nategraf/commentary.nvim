local M = {}

local config = require("commentary.config")
local state = require("commentary.state")
local comment = require("commentary.comment")
local ui = require("commentary.ui")
local formatter = require("commentary.formatter")
local utils = require("commentary.utils")

--- Setup function to initialize the plugin
---@param opts table? User configuration
function M.setup(opts)
  config.setup(opts or {})
  state.init()
  require("commentary.notification").setup()

  -- Create commands
  vim.api.nvim_create_user_command("CommentaryClear", function()
    M.clear()
  end, { desc = "Clear all review comments" })

  vim.api.nvim_create_user_command("CommentaryComment", function(args)
    local context_lines = tonumber(args.args)
    M.add_comment(context_lines)
  end, {
    desc = "Add a comment at current location",
    nargs = "?",
  })

  vim.api.nvim_create_user_command("CommentaryPreview", function()
    M.preview()
  end, { desc = "Preview the code review" })

  vim.api.nvim_create_user_command("CommentarySave", function(args)
    M.save(args.args ~= "" and args.args or nil)
  end, {
    desc = "Save review to file",
    nargs = "?",
    complete = "file",
  })

  vim.api.nvim_create_user_command("CommentaryCopy", function()
    M.copy()
  end, { desc = "Copy review to clipboard" })

  vim.api.nvim_create_user_command("CommentaryShowComment", function()
    M.show_comment_at_cursor()
  end, { desc = "Show comment at cursor position" })

  vim.api.nvim_create_user_command("CommentaryList", function()
    M.list_comments()
  end, { desc = "List all comments" })

  vim.api.nvim_create_user_command("CommentaryDeleteComment", function()
    M.delete_comment_at_cursor()
  end, { desc = "Delete comment at cursor position" })

  vim.api.nvim_create_user_command("CommentaryEditComment", function()
    M.edit_comment_at_cursor()
  end, { desc = "Edit comment at cursor position" })

  vim.api.nvim_create_user_command("CommentaryReply", function()
    M.reply_to_comment_at_cursor()
  end, { desc = "Reply to comment at cursor position" })

  vim.api.nvim_create_user_command("CommentaryPreviousComment", function()
    M.previous_comment()
  end, { desc = "Jump to the previous review comment" })

  vim.api.nvim_create_user_command("CommentaryNextComment", function()
    M.next_comment()
  end, { desc = "Jump to the next review comment" })

  -- Setup keymaps if enabled
  local keymaps = config.get("keymaps")
  if keymaps then
    for action, mapping in pairs(keymaps) do
      if mapping then
        local key, mode
        -- Support both old format (string) and new format (table)
        if type(mapping) == "string" then
          key = mapping
          mode = action == "add_comment" and { "n", "v" } or "n"
        elseif type(mapping) == "table" and mapping.key then
          key = mapping.key
          mode = mapping.mode or (action == "add_comment" and { "n", "v" } or "n")
        end

        if key then
          local desc = {
            clear = "Clear review comments",
            add_comment = "Add review comment",
            preview = "Preview review",
            save = "Save review to file",
            copy = "Copy review to clipboard",
            show_comment = "Show comment at cursor",
            list_comments = "List all comments",
            delete_comment = "Delete comment at cursor",
            edit_comment = "Edit comment at cursor",
            reply_comment = "Reply to comment at cursor",
            previous_comment = "Previous review comment",
            next_comment = "Next review comment",
          }

          local func = {
            clear = M.clear,
            add_comment = function()
              M.add_comment(vim.v.count > 0 and vim.v.count or nil)
            end,
            preview = M.preview,
            save = M.save,
            copy = M.copy,
            show_comment = M.show_comment_at_cursor,
            list_comments = M.list_comments,
            delete_comment = M.delete_comment_at_cursor,
            edit_comment = M.edit_comment_at_cursor,
            reply_comment = M.reply_to_comment_at_cursor,
            previous_comment = M.previous_comment,
            next_comment = M.next_comment,
          }

          if func[action] then
            vim.keymap.set(mode, key, func[action], { desc = desc[action] })
          end
        end
      end
    end
  end

  -- Setup autocmd to sync state and update UI (only for file backend)
  if config.get("comment.storage.backend") == "file" then
    -- TODO: Add a debounced vim.uv.new_fs_event watcher for the storage
    -- directory so external comments load without waiting for an editor event.
    vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "CursorHold" }, {
      group = vim.api.nvim_create_augroup("CommentarySync", { clear = true }),
      callback = function()
        -- Sync from storage and update UI
        require("commentary.state").sync_from_storage()
      end,
      desc = "Sync code review state and update UI",
    })
  end

  local anchor = require("commentary.anchor")
  local anchor_group = vim.api.nvim_create_augroup("CommentaryAnchors", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufFilePost", "FileChangedShellPost" }, {
    group = anchor_group,
    callback = function(args)
      anchor.detach_buffer(args.buf)
      anchor.invalidate_cache()
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(args.buf) then
          state.sync_from_storage()
        end
      end)
    end,
    desc = "Re-resolve code review anchors after external file changes",
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = anchor_group,
    callback = function(args)
      anchor.detach_buffer(args.buf)
    end,
    desc = "Release code review anchors for deleted buffers",
  })
  vim.api.nvim_create_autocmd("DirChanged", {
    group = anchor_group,
    callback = function()
      anchor.clear()
      state.sync_from_storage()
    end,
    desc = "Re-resolve code review anchors in the new project",
  })
end

local function attached_comment_lines()
  local bufnr = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(bufnr)
  if filename == "" then
    return {}
  end

  local file = utils.normalize_path(filename)
  local anchor = require("commentary.anchor")
  local seen = {}
  local lines = {}
  for _, review_comment in ipairs(state.get_comments()) do
    if anchor.is_attached(review_comment) and review_comment.file == file then
      local line = review_comment.line_start
      if not seen[line] then
        seen[line] = true
        table.insert(lines, line)
      end
    end
  end
  table.sort(lines)
  return lines
end

local function jump_comment(direction)
  local lines = attached_comment_lines()
  if #lines == 0 then
    vim.notify("No attached review comments in this buffer", vim.log.levels.INFO)
    return false
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  local index = nil
  if direction > 0 then
    for candidate, line in ipairs(lines) do
      if line > row then
        index = candidate
        break
      end
    end
    index = index or 1
  else
    for candidate = #lines, 1, -1 do
      if lines[candidate] < row then
        index = candidate
        break
      end
    end
    index = index or #lines
  end

  local count = vim.v.count1
  index = ((index - 1 + direction * (count - 1)) % #lines) + 1
  vim.api.nvim_win_set_cursor(0, { lines[index], 0 })
  vim.cmd("normal! zv")
  return true
end

--- Jump to the previous attached review comment in the current buffer.
function M.previous_comment()
  return jump_comment(-1)
end

--- Jump to the next attached review comment in the current buffer.
function M.next_comment()
  return jump_comment(1)
end

--- Clear all comments
function M.clear()
  local comment_count = #state.get_comments()
  if comment_count == 0 then
    vim.notify("No comments to clear", vim.log.levels.INFO)
    return
  end

  vim.ui.select({ "No", "Yes" }, {
    prompt = string.format(
      "Delete all %d review comment%s?",
      comment_count,
      comment_count == 1 and "" or "s"
    ),
  }, function(choice)
    if choice == "Yes" then
      state.clear()
    end
  end)
end

--- Add a comment at the current location
---@param context_lines number? Number of lines before/after to include
function M.add_comment(context_lines)
  comment.add(context_lines)
end

--- Show preview of the review
function M.preview()
  local comments = state.get_comments()
  if #comments == 0 then
    vim.notify("No comments to preview", vim.log.levels.WARN)
    return
  end

  local content = formatter.format(comments)
  ui.show_preview(content, "markdown")
end

--- Save review to file
---@param path string? File path to save to
function M.save(path)
  local comments = state.get_comments()
  if #comments == 0 then
    vim.notify("No comments to save", vim.log.levels.WARN)
    return
  end

  local review_utils = require("commentary.utils")

  -- Generate default path if not provided
  if not path then
    local save_dir = config.get("output.save_dir") or vim.fn.getcwd()
    local filename = review_utils.generate_filename("markdown")
    local default_path = vim.fn.fnamemodify(save_dir .. "/" .. filename, ":p")

    -- Use vim.ui.input to get the save path
    vim.ui.input({
      prompt = "Save to: ",
      default = default_path,
      completion = "file",
    }, function(input)
      if input and input ~= "" then
        local content = formatter.format(comments)
        formatter.save_to_file(content, input)
      end
    end)
  else
    -- If path is provided, save directly
    local content = formatter.format(comments)
    formatter.save_to_file(content, path)
  end
end

--- Copy review to clipboard
function M.copy()
  local comments = state.get_comments()
  if #comments == 0 then
    vim.notify("No comments to copy", vim.log.levels.WARN)
    return
  end

  local content = formatter.format(comments)
  vim.fn.setreg("+", content)
  vim.notify("Code reviews copied to clipboard")
end

--- Show comment at cursor position
function M.show_comment_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = utils.normalize_path(vim.api.nvim_buf_get_name(bufnr))
  local row = vim.api.nvim_win_get_cursor(0)[1]

  -- Find comments for current line
  local line_comments = state.get_comments_at_location(file, row)

  if #line_comments == 0 then
    return
  end

  -- Group comments by thread
  local threads = {}
  for _, line_comment in ipairs(line_comments) do
    local thread_id = line_comment.thread_id
    if thread_id then
      if not threads[thread_id] then
        threads[thread_id] = {}
      end
      table.insert(threads[thread_id], line_comment)
    end
  end

  local thread_count = vim.tbl_count(threads)

  if thread_count == 0 then
    -- No threads, show all comments
    ui.show_comment_list(line_comments)
  elseif thread_count == 1 then
    -- Single thread, show all its comments
    local thread_id = next(threads)
    local thread_comments = state.get_thread_comments(thread_id)
    ui.show_comment_list(thread_comments)
  else
    -- Multiple threads, let user choose
    local thread_list = {}
    for thread_id, _ in pairs(threads) do
      local thread_comments = state.get_thread_comments(thread_id)
      local preview = ""
      if #thread_comments > 0 then
        preview = thread_comments[1].comment:sub(1, 50)
        if #thread_comments[1].comment > 50 then
          preview = preview .. "..."
        end
      end

      table.insert(thread_list, {
        id = thread_id,
        display = string.format("%s (%d comments)", preview, #thread_comments),
        thread_id = thread_id,
      })
    end

    -- Sort by thread ID for consistent ordering
    table.sort(thread_list, function(a, b)
      return a.id < b.id
    end)

    -- Show selection UI
    vim.ui.select(thread_list, {
      prompt = "Select thread to view:",
      format_item = function(item)
        return item.display
      end,
    }, function(choice)
      if choice then
        local thread_comments = state.get_thread_comments(choice.thread_id)
        ui.show_comment_list(thread_comments)
      end
    end)
  end
end

--- List all comments
function M.list_comments()
  require("commentary.list").list_threads()
end

--- Reply to a specific comment's thread
---@param comment_data table Comment to reply to
function M.reply_to_comment(comment_data)
  ui.show_comment_input(function(reply_text)
    if reply_text and reply_text ~= "" then
      state.add_reply(comment_data.id, reply_text)
      vim.notify("Reply added", vim.log.levels.INFO)
    end
  end, {
    file = comment_data.file,
    line_start = comment_data.line_start,
    line_end = comment_data.line_end,
    lines = comment_data.context_lines or {},
  }, " Reply to Comment (C-CR to submit) ")
end

--- Reply to comment at cursor position
function M.reply_to_comment_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = utils.normalize_path(vim.api.nvim_buf_get_name(bufnr))
  local row = vim.api.nvim_win_get_cursor(0)[1]

  -- Find comments for current line
  local line_comments = state.get_comments_at_location(file, row)

  if #line_comments == 0 then
    vim.notify("No comment at cursor position", vim.log.levels.WARN)
    return
  end

  -- Group comments by thread
  local threads = {}
  for _, c in ipairs(line_comments) do
    local thread_id = c.thread_id or c.id
    if not threads[thread_id] then
      threads[thread_id] = {
        id = thread_id,
        root_comment = nil,
        comments = {},
      }
    end
    table.insert(threads[thread_id].comments, c)
    -- Track root comment
    if not c.parent_id then
      threads[thread_id].root_comment = c
    end
  end

  -- Select thread if multiple threads exist
  local thread_count = vim.tbl_count(threads)

  if thread_count == 1 then
    -- Single thread case
    local selected_thread = threads[next(threads)]
    local comment_to_reply = selected_thread.root_comment or selected_thread.comments[1]

    M.reply_to_comment(comment_to_reply)
  else
    -- Create thread selection items
    local thread_items = {}
    for _, thread in pairs(threads) do
      -- Always use the first comment (oldest) for preview
      local first_comment = thread.comments[1]
      local preview = first_comment.comment:sub(1, 50)
      if #first_comment.comment > 50 then
        preview = preview .. "..."
      end
      local item = {
        display = string.format("%d. %s (%d comments)", #thread_items + 1, preview, #thread.comments),
        thread = thread,
      }
      table.insert(thread_items, item)
    end

    -- Show thread selection
    vim.ui.select(thread_items, {
      prompt = "Select thread to reply to:",
      format_item = function(item)
        return item.display
      end,
    }, function(choice)
      if not choice then
        return
      end

      local selected_thread = choice.thread

      -- Continue with reply process inside callback
      local comment_to_reply = selected_thread.root_comment or selected_thread.comments[1]

      M.reply_to_comment(comment_to_reply)
    end)
  end
end

local function comment_picker_label(item)
  local first_line = item.comment:match("^[^\n]*") or item.comment
  if #first_line > 50 then
    first_line = first_line:sub(1, 47) .. "..."
  end
  return string.format("Line %d-%d [%s]: %s", item.line_start, item.line_end, item.author or "unknown", first_line)
end

local function select_comment(comments, prompt, callback)
  vim.ui.select(comments, {
    prompt = prompt,
    format_item = comment_picker_label,
  }, callback)
end

local function show_comment_editor(comment_data)
  ui.show_comment_input(function(updated_text)
    if updated_text == nil then
      return
    end
    if vim.trim(updated_text) == "" then
      vim.notify("Comment cannot be empty; use delete to remove it", vim.log.levels.WARN)
      return
    end
    if updated_text == comment_data.comment then
      return
    end

    if state.update_comment(comment_data.id, { comment = updated_text }) then
      vim.notify("Comment updated")
    else
      vim.notify("Failed to update comment", vim.log.levels.ERROR)
    end
  end, {
    file = comment_data.file,
    line_start = comment_data.line_start,
    line_end = comment_data.line_end,
    lines = comment_data.context_lines or {},
  }, " Edit Comment (C-CR to submit) ", comment_data.comment)
end

--- Edit a specific comment
---@param comment_data table Comment to edit
function M.edit_comment(comment_data)
  show_comment_editor(comment_data)
end

--- Edit comment at cursor position
function M.edit_comment_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = utils.normalize_path(vim.api.nvim_buf_get_name(bufnr))
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line_comments = state.get_comments_at_location(file, row)

  if #line_comments == 0 then
    vim.notify("No comment at cursor position", vim.log.levels.WARN)
    return
  end

  if #line_comments > 1 then
    select_comment(line_comments, "Select comment to edit:", function(choice)
      if choice then
        M.edit_comment(choice)
      end
    end)
  else
    M.edit_comment(line_comments[1])
  end
end

local function delete_comment(comment_data)
  if state.delete_comment(comment_data.id) then
    vim.notify("Comment deleted")
  else
    vim.notify("Failed to delete comment", vim.log.levels.ERROR)
  end
end

--- Delete a specific comment after confirmation
---@param comment_data table Comment to delete
function M.delete_comment(comment_data)
  local first_line = comment_data.comment:match("^[^\n]*") or comment_data.comment
  if #first_line > 50 then
    first_line = first_line:sub(1, 47) .. "..."
  end

  vim.ui.select({ "Yes", "No" }, {
    prompt = string.format("Delete comment: %s?", first_line),
  }, function(choice)
    if choice == "Yes" then
      delete_comment(comment_data)
    end
  end)
end

--- Delete comment at cursor position
function M.delete_comment_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = utils.normalize_path(vim.api.nvim_buf_get_name(bufnr))
  local row = vim.api.nvim_win_get_cursor(0)[1]

  -- Find comments for current line
  local line_comments = state.get_comments_at_location(file, row)

  if #line_comments == 0 then
    vim.notify("No comment at cursor position", vim.log.levels.WARN)
    return
  end

  -- If multiple comments, let user choose
  if #line_comments > 1 then
    select_comment(line_comments, "Select comment to delete:", function(choice)
      if choice then
        delete_comment(choice)
      end
    end)
  else
    M.delete_comment(line_comments[1])
  end
end

--- Get input buffer functions for keymapping
---@param bufnr number Buffer number
---@return table Functions for the buffer
function M.get_input_buffer_functions(bufnr)
  -- We need to store the callback function somewhere accessible
  -- This will be set by the UI module
  return {
    submit = function()
      -- Trigger submit action for this buffer
      if vim.b[bufnr]._commentary_submit then
        vim.b[bufnr]._commentary_submit()
      end
    end,
    cancel = function()
      -- Trigger cancel action for this buffer
      if vim.b[bufnr]._commentary_cancel then
        vim.b[bufnr]._commentary_cancel()
      end
    end,
  }
end

return M
