local M = {}

local anchor = require("code-review.anchor")
local state = require("code-review.state")
local preview = require("code-review.list-preview")

local function anchor_label(comment)
  local status = comment.anchor_status
  if status and status ~= "attached" then
    return string.format("[%s] ", status)
  end
  return ""
end

local function telescope_thread_entry_parts(thread_info)
  local root = thread_info.data.root_comment
  local filename = vim.fn.fnamemodify(root.file, ":~:.")
  local line = root.line_start == root.line_end and tostring(root.line_start)
    or string.format("%d-%d", root.line_start, root.line_end)
  local text = root.comment:match("^[^\n]*") or root.comment
  return filename, line, anchor_label(root) .. text
end

local function format_telescope_thread_entry(thread_info)
  local filename, line, text = telescope_thread_entry_parts(thread_info)
  return string.format("%s:%s: %s", filename, line, text)
end

local function make_telescope_thread_displayer(entry_display)
  local displayer = entry_display.create({
    separator = "",
    items = {
      {},
      {},
      { remaining = true },
    },
  })

  return function(entry)
    local filename, line, text = telescope_thread_entry_parts(entry.value)
    return displayer({
      { filename .. ":", "TelescopeResultsIdentifier" },
      { line .. ": ", "TelescopeResultsNumber" },
      { text, "TelescopeResultsComment" },
    })
  end
end

local function jump_to_comment(comment)
  if not anchor.is_attached(comment) then
    vim.notify(
      string.format("Comment anchor is %s; reattachment is required", comment.anchor_status or "unresolved"),
      vim.log.levels.WARN
    )
    return false
  end

  vim.cmd("edit " .. vim.fn.fnameescape(comment.file))
  local line = math.max(1, math.min(comment.line_start, vim.api.nvim_buf_line_count(0)))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  return true
end

--- Convert comment to quickfix item
---@param comment table
---@return table
local function comment_to_qf_item(comment)
  -- Get first line of comment for preview
  local text = comment.comment:match("^[^\n]*") or comment.comment
  if #text > 80 then
    text = text:sub(1, 77) .. "..."
  end

  local attached = anchor.is_attached(comment)
  return {
    filename = attached and comment.file or "",
    lnum = attached and comment.line_start or 0,
    col = attached and 1 or 0,
    valid = attached and 1 or 0,
    text = anchor_label(comment) .. text,
    -- Store full comment in user data
    user_data = comment,
  }
end

--- List all comments using quickfix
function M.list_with_quickfix()
  local comments = state.get_comments()

  if #comments == 0 then
    vim.notify("No comments to display", vim.log.levels.INFO)
    return
  end

  -- Build thread tree
  local thread = require("code-review.thread")
  local threads = thread.build_thread_tree(comments)

  -- Get thread statuses from storage
  local all_threads = state.get_all_threads()

  -- Sort threads by file and line
  local sorted_threads = {}
  for _, thread_data in pairs(threads) do
    table.insert(sorted_threads, thread_data)
  end
  table.sort(sorted_threads, function(a, b)
    local a_root = a.root_comment
    local b_root = b.root_comment
    if a_root.file ~= b_root.file then
      return a_root.file < b_root.file
    end
    return a_root.line_start < b_root.line_start
  end)

  -- Convert to quickfix items with thread grouping
  local qf_items = {}
  for _, thread_data in ipairs(sorted_threads) do
    local thread_info = all_threads[thread_data.id]
    local status_indicator = ""

    if thread_info then
      if thread_info.status == "resolved" then
        status_indicator = "[✓] "
      elseif thread_data.root_comment.thread_status == "waiting-review" then
        status_indicator = "[󰇮] " -- Mail icon, match virtual text
      elseif thread_data.root_comment.thread_status == "action-required" then
        status_indicator = "[○] " -- Match virtual text
      else
        status_indicator = "[•] "
      end
    else
      -- Check thread_status from comment
      if thread_data.root_comment.thread_status == "waiting-review" then
        status_indicator = "[󰇮] " -- Mail icon, match virtual text
      elseif thread_data.root_comment.thread_status == "action-required" then
        status_indicator = "[○] " -- Match virtual text
      end
    end

    -- Add root comment with thread indicator
    local root_item = comment_to_qf_item(thread_data.root_comment)
    root_item.text = status_indicator .. "THREAD: " .. root_item.text
    table.insert(qf_items, root_item)

    -- Add replies in linear order
    if thread_data.replies then
      for _, reply in ipairs(thread_data.replies) do
        local reply_item = comment_to_qf_item(reply)
        reply_item.text = "  └─ " .. reply_item.text
        table.insert(qf_items, reply_item)
      end
    end
  end

  -- Set quickfix list
  vim.fn.setqflist({}, "r", {
    title = "Code Review Comments",
    items = qf_items,
  })

  -- Open quickfix window
  vim.cmd("copen")
end

--- List all comments using Telescope
function M.list_with_telescope()
  local ok = pcall(require, "telescope")
  if not ok then
    return false
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local comments = state.get_comments()

  if #comments == 0 then
    vim.notify("No comments to display", vim.log.levels.INFO)
    return true
  end

  -- Sort by file and line
  table.sort(comments, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.line_start < b.line_start
  end)

  -- Create displayer
  local displayer = entry_display.create({
    separator = " │ ",
    items = {
      { width = 30 }, -- file
      { width = 6 }, -- line
      { remaining = true }, -- comment
    },
  })

  local function make_display(entry)
    local comment = entry.value
    local filename = comment.file -- Use full path
    local line_info = comment.line_start == comment.line_end and tostring(comment.line_start)
      or string.format("%d-%d", comment.line_start, comment.line_end)
    local text = anchor_label(comment) .. (comment.comment:match("^[^\n]*") or comment.comment)

    return displayer({
      { filename, "TelescopeResultsIdentifier" },
      { line_info, "TelescopeResultsNumber" },
      { text, "TelescopeResultsComment" },
    })
  end

  pickers
    .new({}, {
      prompt_title = "Code Review Comments",
      finder = finders.new_table({
        results = comments,
        entry_maker = function(comment)
          return {
            value = comment,
            display = make_display,
            ordinal = string.format("%s:%d %s", comment.file, comment.line_start, comment.comment),
            filename = comment.file,
            lnum = comment.line_start,
            col = 1,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = preview.telescope_comment_previewer(),
      layout_strategy = "horizontal",
      layout_config = {
        preview_width = 0.5,
      },
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            jump_to_comment(selection.value)
          end
        end)
        return true
      end,
    })
    :find()

  return true
end

--- List all comments using fzf-lua
function M.list_with_fzf_lua()
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    return false
  end

  local comments = state.get_comments()

  if #comments == 0 then
    vim.notify("No comments to display", vim.log.levels.INFO)
    return true
  end

  -- Sort by file and line
  table.sort(comments, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.line_start < b.line_start
  end)

  -- Clean up any previous temp buffers
  if M._temp_buffers then
    for _, bufnr in ipairs(M._temp_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end

  -- Create preview buffers for all comments
  local formatter = require("code-review.formatter")
  local preview_buffers = {}
  M._temp_buffers = {}

  for i, comment in ipairs(comments) do
    -- Create a scratch buffer
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
    vim.api.nvim_buf_set_option(bufnr, "bufhidden", "hide")
    vim.api.nvim_buf_set_option(bufnr, "swapfile", false)
    vim.api.nvim_buf_set_option(bufnr, "filetype", "markdown")

    -- Set content
    local lines = formatter.format_single(comment)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    preview_buffers[i] = bufnr
    table.insert(M._temp_buffers, bufnr)
  end

  -- Create custom previewer using builtin.buffer_or_file as base
  local builtin = require("fzf-lua.previewer.builtin")
  local CommentPreviewer = builtin.buffer_or_file:extend()

  function CommentPreviewer:new(o, opts, fzf_win)
    CommentPreviewer.super.new(self, o, opts, fzf_win)
    self.title = "Comment Details"
    self.syntax = true
    self.syntax_limit_l = 0
    self.comments_data = comments -- Store comments for title update
    return self
  end

  function CommentPreviewer:populate_preview_buf(entry_str)
    if not self.win or not self.win:validate_preview() then
      return
    end

    -- Find the matching comment based on the entry string
    local filepath, line_num = entry_str:match("^([^:]+):(%d+)")
    if not filepath or not line_num then
      filepath, line_num = entry_str:match("^([^:]+):(%d+)%-")
    end

    -- Find matching comment by full path and line
    local matched_buffer = nil
    for i, c in ipairs(comments) do
      if c.file == filepath and tostring(c.line_start):match(line_num) then
        -- Store current comment info for title
        self.current_comment = c
        self.current_index = i
        matched_buffer = preview_buffers[i]
        break
      end
    end

    if not matched_buffer then
      return
    end

    -- Get content from the prepared buffer
    local lines = vim.api.nvim_buf_get_lines(matched_buffer, 0, -1, false)

    -- Get or create temp buffer for preview
    local tmpbuf = self:get_tmp_buffer()

    -- Set the content
    vim.api.nvim_buf_set_lines(tmpbuf, 0, -1, false, lines)

    -- Set filetype for syntax highlighting
    vim.api.nvim_buf_set_option(tmpbuf, "filetype", "markdown")

    -- Set preview buffer
    self:set_preview_buf(tmpbuf)

    -- Update title and other post processing
    self:preview_buf_post({ path = "comment.md", line = 1, col = 1 })
  end

  function CommentPreviewer:parse_entry(entry_str)
    -- We handle everything in populate_preview_buf, so just return a dummy entry
    return { path = "dummy", line = 1, col = 1 }
  end

  function CommentPreviewer:update_title(entry)
    -- Override the title update to show comment info instead of temp file name
    if self.current_comment then
      local line_info = self.current_comment.line_start == self.current_comment.line_end
          and tostring(self.current_comment.line_start)
        or string.format("%d-%d", self.current_comment.line_start, self.current_comment.line_end)
      local title = string.format("%s:%s", self.current_comment.file, line_info)
      -- Don't apply title_fnamemodify - we want full path
      self.win:update_preview_title(" " .. title .. " ")
    else
      -- Fallback to parent implementation
      CommentPreviewer.super.update_title(self, entry)
    end
  end

  -- Create entries for display (use full path like yank function)
  local entries = {}
  local comments_by_entry = {}
  for _, comment_data in ipairs(comments) do
    local line_info = comment_data.line_start == comment_data.line_end and tostring(comment_data.line_start)
      or string.format("%d-%d", comment_data.line_start, comment_data.line_end)
    local text = comment_data.comment:match("^[^\n]*") or comment_data.comment

    -- Use full path:line: format for display (same as yank)
    local entry = string.format("%s:%s: %s%s", comment_data.file, line_info, anchor_label(comment_data), text)
    table.insert(entries, entry)
    comments_by_entry[entry] = comment_data
  end

  -- Setup cleanup function
  local function cleanup_temp_buffers()
    if M._temp_buffers then
      for _, bufnr in ipairs(M._temp_buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
      end
      M._temp_buffers = nil
    end
  end

  fzf.fzf_exec(entries, {
    prompt = "Code Review Comments> ",
    previewer = {
      _ctor = function()
        return CommentPreviewer
      end,
    },
    preview_window = "right:50%:wrap",
    -- Called when fzf window is closed (including ESC)
    fn_post = function()
      vim.defer_fn(cleanup_temp_buffers, 100)
    end,
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then
          return
        end

        local comment = comments_by_entry[selected[1]]
        if comment then
          jump_to_comment(comment)
        end
      end,
    },
  })

  return true
end

--- List all comments using available picker
function M.list_comments()
  -- Try Telescope first
  if M.list_with_telescope() then
    return
  end

  -- Try fzf-lua
  if M.list_with_fzf_lua() then
    return
  end

  -- Fallback to quickfix
  M.list_with_quickfix()
end

--- List all threads using quickfix
function M.list_threads_with_quickfix()
  local comments = state.get_comments()

  if #comments == 0 then
    vim.notify("No threads to display", vim.log.levels.INFO)
    return
  end

  -- Build thread tree
  local thread = require("code-review.thread")
  local threads = thread.build_thread_tree(comments)

  -- Get thread statuses
  local all_threads = state.get_all_threads()

  -- Convert threads to quickfix items
  local qf_items = {}
  for thread_id, thread_data in pairs(threads) do
    local root_comment = thread_data.root_comment
    local thread_status = all_threads[thread_id] and all_threads[thread_id].status or "open"

    -- Get status icon (match virtual text)
    local status_icon = ""
    if root_comment.thread_status == "action-required" then
      status_icon = "[○] " -- Match virtual text
    elseif root_comment.thread_status == "waiting-review" then
      status_icon = "[󰇮] " -- Mail icon, match virtual text
    elseif thread_status == "resolved" then
      status_icon = "[✓] "
    end

    -- Create preview text with thread info
    local text = string.format(
      "%s%s%s (%d comments)",
      status_icon,
      anchor_label(root_comment),
      root_comment.comment:match("^[^\n]*") or root_comment.comment,
      #thread_data.replies + 1
    )

    if #text > 80 then
      text = text:sub(1, 77) .. "..."
    end

    local attached = anchor.is_attached(root_comment)
    table.insert(qf_items, {
      filename = attached and root_comment.file or "",
      lnum = attached and root_comment.line_start or 0,
      col = attached and 1 or 0,
      valid = attached and 1 or 0,
      text = text,
      user_data = root_comment,
    })
  end

  -- Sort by file and line
  table.sort(qf_items, function(a, b)
    if a.filename ~= b.filename then
      return a.filename < b.filename
    end
    return a.lnum < b.lnum
  end)

  -- Set quickfix list
  vim.fn.setqflist({}, "r", {
    title = "Code Review Threads",
    items = qf_items,
  })

  -- Open quickfix window
  vim.cmd("copen")
end

--- List all threads using fzf-lua
function M.list_threads_with_fzf_lua()
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    return false
  end

  local comments = state.get_comments()
  if #comments == 0 then
    vim.notify("No threads to display", vim.log.levels.INFO)
    return true
  end

  -- Build thread tree
  local thread = require("code-review.thread")
  local threads = thread.build_thread_tree(comments)
  local all_threads = state.get_all_threads()

  -- Convert to sorted list
  local thread_list = {}
  for thread_id, thread_data in pairs(threads) do
    table.insert(thread_list, {
      id = thread_id,
      data = thread_data,
      status = all_threads[thread_id] and all_threads[thread_id].status or "open",
    })
  end

  -- Sort by file and line
  table.sort(thread_list, function(a, b)
    local a_root = a.data.root_comment
    local b_root = b.data.root_comment
    if a_root.file ~= b_root.file then
      return a_root.file < b_root.file
    end
    return a_root.line_start < b_root.line_start
  end)

  -- Create entries
  local entries = {}
  for _, thread_info in ipairs(thread_list) do
    local root_comment = thread_info.data.root_comment

    -- Get status icon (match virtual text)
    local status_icon = ""
    if root_comment.thread_status == "action-required" then
      status_icon = "○ " -- Match virtual text
    elseif root_comment.thread_status == "waiting-review" then
      status_icon = "󰇮 " -- Mail icon, match virtual text
    elseif thread_info.status == "resolved" then
      status_icon = "✓ "
    end

    local line_info = root_comment.line_start == root_comment.line_end and tostring(root_comment.line_start)
      or string.format("%d-%d", root_comment.line_start, root_comment.line_end)

    local preview_text = root_comment.comment:match("^[^\n]*") or root_comment.comment
    if #preview_text > 50 then
      preview_text = preview_text:sub(1, 47) .. "..."
    end

    local entry = string.format(
      "%s:%s: %s%s%s (%d comments)",
      root_comment.file,
      line_info,
      status_icon,
      anchor_label(root_comment),
      preview_text,
      #thread_info.data.replies + 1
    )

    table.insert(entries, {
      display = entry,
      thread_id = thread_info.id,
      root_comment = root_comment,
    })
  end

  -- Create preview buffers for all threads
  local preview_buffers = {}
  local temp_buffers = {}

  for _, thread_info in ipairs(thread_list) do
    -- Create a scratch buffer
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
    vim.api.nvim_buf_set_option(bufnr, "bufhidden", "hide")
    vim.api.nvim_buf_set_option(bufnr, "swapfile", false)
    vim.api.nvim_buf_set_option(bufnr, "filetype", "markdown")

    local lines = preview.format_thread(thread_info)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    preview_buffers[thread_info.id] = bufnr
    table.insert(temp_buffers, bufnr)
  end

  -- Create custom previewer
  local builtin = require("fzf-lua.previewer.builtin")
  local ThreadPreviewer = builtin.buffer_or_file:extend()

  function ThreadPreviewer:new(o, opts, fzf_win)
    ThreadPreviewer.super.new(self, o, opts, fzf_win)
    self.title = "Thread Details"
    self.syntax = true
    self.syntax_limit_l = 0
    -- Store references to data needed in populate_preview_buf
    self.entries = entries
    self.preview_buffers = preview_buffers
    return self
  end

  function ThreadPreviewer:populate_preview_buf(entry_str)
    if not self.win or not self.win:validate_preview() then
      return
    end

    -- Find matching entry by display string
    local matched_buffer = nil
    local matched_thread = nil
    for _, entry in ipairs(self.entries) do
      if entry.display == entry_str then
        matched_buffer = self.preview_buffers[entry.thread_id]
        matched_thread = entry
        break
      end
    end

    if not matched_buffer then
      return
    end

    -- Get content from the prepared buffer
    local lines = vim.api.nvim_buf_get_lines(matched_buffer, 0, -1, false)

    -- Get or create temp buffer for preview
    local tmpbuf = self:get_tmp_buffer()

    -- Set the content
    vim.api.nvim_buf_set_lines(tmpbuf, 0, -1, false, lines)

    -- Set filetype for syntax highlighting
    vim.api.nvim_buf_set_option(tmpbuf, "filetype", "markdown")

    -- Set preview buffer
    self:set_preview_buf(tmpbuf)

    -- Store current thread info for title update
    self.current_thread = matched_thread

    -- Update title and other post processing
    self:preview_buf_post({ path = "thread.md", line = 1, col = 1 })
  end

  function ThreadPreviewer:parse_entry(entry_str)
    -- We handle everything in populate_preview_buf
    return { path = "dummy", line = 1, col = 1 }
  end

  function ThreadPreviewer:update_title(entry)
    -- Override the title update to show thread info instead of temp file name
    if self.current_thread then
      local root = self.current_thread.root_comment
      local line_info = root.line_start == root.line_end and tostring(root.line_start)
        or string.format("%d-%d", root.line_start, root.line_end)
      local title = string.format("%s:%s", root.file, line_info)
      -- Don't apply title_fnamemodify - we want full path
      self.win:update_preview_title(" " .. title .. " ")
    else
      -- Fallback to parent implementation
      ThreadPreviewer.super.update_title(self, entry)
    end
  end

  -- Setup cleanup function
  local function cleanup_temp_buffers()
    for _, bufnr in ipairs(temp_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end

  -- Create display strings
  local display_strings = {}
  for _, entry in ipairs(entries) do
    table.insert(display_strings, entry.display)
  end

  fzf.fzf_exec(display_strings, {
    prompt = "Code Review Threads> ",
    previewer = {
      _ctor = function()
        return ThreadPreviewer
      end,
    },
    preview_window = "right:50%:wrap",
    fn_post = function()
      vim.defer_fn(cleanup_temp_buffers, 100)
    end,
    actions = {
      ["default"] = function(selected)
        if not selected or #selected == 0 then
          return
        end

        -- Find matching entry
        local line = selected[1]
        for _, entry in ipairs(entries) do
          if entry.display == line then
            jump_to_comment(entry.root_comment)
            break
          end
        end
      end,
    },
  })

  return true
end

--- List all threads using telescope
function M.list_threads_with_telescope()
  local ok = pcall(require, "telescope")
  if not ok then
    return false
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  local comments = state.get_comments()
  if #comments == 0 then
    vim.notify("No threads to display", vim.log.levels.INFO)
    return true
  end

  -- Build thread tree
  local thread = require("code-review.thread")
  local threads = thread.build_thread_tree(comments)
  local all_threads = state.get_all_threads()

  -- Convert to sorted list
  local thread_list = {}
  for thread_id, thread_data in pairs(threads) do
    table.insert(thread_list, {
      id = thread_id,
      data = thread_data,
      status = all_threads[thread_id] and all_threads[thread_id].status or "open",
    })
  end

  -- Sort by file and line
  table.sort(thread_list, function(a, b)
    local a_root = a.data.root_comment
    local b_root = b.data.root_comment
    if a_root.file ~= b_root.file then
      return a_root.file < b_root.file
    end
    return a_root.line_start < b_root.line_start
  end)

  local make_display = make_telescope_thread_displayer(entry_display)

  pickers
    .new({}, {
      prompt_title = "Code Review Threads",
      finder = finders.new_table({
        results = thread_list,
        entry_maker = function(thread_info)
          local root_comment = thread_info.data.root_comment
          local ordinal = format_telescope_thread_entry(thread_info)
          return {
            value = thread_info,
            display = make_display,
            ordinal = ordinal,
            filename = root_comment.file,
            lnum = root_comment.line_start,
            col = 1,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = preview.telescope_thread_previewer(),
      layout_strategy = "horizontal",
      layout_config = {
        preview_width = 0.5,
      },
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            jump_to_comment(selection.value.data.root_comment)
          end
        end)
        return true
      end,
    })
    :find()

  return true
end

--- List all threads
function M.list_threads()
  -- Try Telescope first
  if M.list_threads_with_telescope() then
    return
  end

  -- Try fzf-lua
  if M.list_threads_with_fzf_lua() then
    return
  end

  -- Fallback to quickfix
  M.list_threads_with_quickfix()
end

M._comment_to_qf_item = comment_to_qf_item
M._jump_to_comment = jump_to_comment
M._format_telescope_thread_entry = format_telescope_thread_entry
M._make_telescope_thread_displayer = make_telescope_thread_displayer

return M
