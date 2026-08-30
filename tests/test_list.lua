local file_storage = require("commentary.storage.file")
local list = require("commentary.list")
local thread = require("commentary.thread")
local preview = require("commentary.list-preview")

require("commentary.config").setup({})

local T = MiniTest.new_set()

T["file-backed replies contribute to thread count and preview"] = function()
  local root = {
    id = "review-1",
    thread_id = "review-1_thread",
    file = "example.lua",
    line_start = 3,
    line_end = 3,
    comment = "Root comment",
    author = "Reviewer",
    timestamp = 1,
    context_lines = { "local value = 1" },
  }
  local replies = {
    vim.tbl_extend("force", vim.deepcopy(root), {
      id = "reply-1",
      parent_id = root.id,
      comment = "First reply",
      author = "Author",
      timestamp = 2,
    }),
    vim.tbl_extend("force", vim.deepcopy(root), {
      id = "reply-2",
      parent_id = root.id,
      comment = "Second reply",
      author = "Reviewer",
      timestamp = 3,
    }),
  }

  local markdown = file_storage.format_thread_as_markdown({ root, replies[1], replies[2] })
  local parsed = file_storage._parse_comment_from_file(markdown, "review-1.md")

  MiniTest.expect.equality(parsed[1].parent_id, nil)
  MiniTest.expect.equality(parsed[2].parent_id, root.id)
  MiniTest.expect.equality(parsed[3].parent_id, root.id)

  local threads = thread.build_thread_tree(parsed)
  local parsed_thread = threads[root.thread_id]
  MiniTest.expect.equality(#parsed_thread.replies, 2)

  local lines = preview.format_thread({
    id = root.thread_id,
    data = parsed_thread,
  })
  local content = table.concat(lines, "\n")
  MiniTest.expect.match(content, "%*%*Comments%*%*: 3")
  MiniTest.expect.match(content, "Root comment")
  MiniTest.expect.match(content, "First reply")
  MiniTest.expect.match(content, "Second reply")
end

T["Telescope renders thread rows as file, line, and text"] = function()
  local thread_info = {
    data = {
      root_comment = {
        file = "lua/commentary/list.lua",
        line_start = 12,
        line_end = 14,
        comment = "Keep the picker concise\nMore detail belongs in the preview.",
        anchor_status = "attached",
      },
      replies = { { comment = "Reply" } },
    },
  }

  MiniTest.expect.equality(
    list._format_telescope_thread_entry(thread_info),
    "lua/commentary/list.lua:12-14: Keep the picker concise"
  )

  local display_items
  local make_display = list._make_telescope_thread_displayer({
    create = function(config)
      MiniTest.expect.equality(config.separator, "")
      return function(items)
        display_items = items
        return items[1][1] .. items[2][1] .. items[3][1]
      end
    end,
  })

  MiniTest.expect.equality(
    make_display({ value = thread_info }),
    "lua/commentary/list.lua:12-14: Keep the picker concise"
  )
  MiniTest.expect.equality(display_items, {
    { "lua/commentary/list.lua:", "TelescopeResultsIdentifier" },
    { "12-14: ", "TelescopeResultsNumber" },
    { "Keep the picker concise", "TelescopeResultsComment" },
  })
end

T["Telescope previews wrap long comment lines"] = function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local winid = vim.api.nvim_open_win(bufnr, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 20,
    height = 5,
    style = "minimal",
  })

  vim.wo[winid].wrap = false
  vim.wo[winid].linebreak = false
  vim.wo[winid].breakindent = false
  preview._enable_wrapping({ state = { winid = winid } })

  MiniTest.expect.equality(vim.wo[winid].wrap, true)
  MiniTest.expect.equality(vim.wo[winid].linebreak, true)
  MiniTest.expect.equality(vim.wo[winid].breakindent, true)

  vim.api.nvim_win_close(winid, true)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["thread sort modes order entries from top to bottom"] = function()
  local function root(id, file, line, timestamp)
    return {
      id = id,
      thread_id = id .. "_thread",
      file = file,
      line_start = line,
      line_end = line,
      comment = id,
      author = "Reviewer",
      timestamp = timestamp,
    }
  end

  local old = root("old", "z.lua", 30, 10)
  local middle = root("middle", "m.lua", 20, 20)
  local recent = root("recent", "a.lua", 10, 5)
  local threads = {
    [old.thread_id] = { root_comment = old, replies = {} },
    [middle.thread_id] = { root_comment = middle, replies = {} },
    [recent.thread_id] = {
      root_comment = recent,
      replies = {
        vim.tbl_extend("force", vim.deepcopy(recent), {
          id = "recent-reply",
          parent_id = recent.id,
          timestamp = 30,
        }),
      },
    },
  }

  local activity = list._sort_thread_list(threads, "activity")
  MiniTest.expect.equality(vim.tbl_map(function(item)
    return item.id
  end, activity), { "old_thread", "middle_thread", "recent_thread" })
  MiniTest.expect.equality(vim.tbl_map(function(item)
    return item.activity
  end, activity), { 10, 20, 30 })

  local file = list._sort_thread_list(threads, "file")
  MiniTest.expect.equality(vim.tbl_map(function(item)
    return item.id
  end, file), { "recent_thread", "middle_thread", "old_thread" })

  local custom = list._sort_thread_list(threads, function(a, b)
    return a.id > b.id
  end)
  MiniTest.expect.equality(vim.tbl_map(function(item)
    return item.id
  end, custom), { "recent_thread", "old_thread", "middle_thread" })

  -- Telescope and fzf use bottom-up layouts, so their finder input reverses
  -- the visual top-to-bottom order and selects the newest thread first.
  local picker = list._reverse_copy(activity)
  MiniTest.expect.equality(vim.tbl_map(function(item)
    return item.id
  end, picker), { "recent_thread", "middle_thread", "old_thread" })
end

T["thread replies are chronological regardless of storage order"] = function()
  local root = {
    id = "root",
    thread_id = "root_thread",
    file = "example.lua",
    line_start = 1,
    line_end = 1,
    comment = "Root",
    timestamp = 1,
  }
  local latest = vim.tbl_extend("force", vim.deepcopy(root), {
    id = "latest",
    parent_id = root.id,
    timestamp = 3,
  })
  local earlier = vim.tbl_extend("force", vim.deepcopy(root), {
    id = "earlier",
    parent_id = root.id,
    timestamp = 2,
  })

  local built = thread.build_thread_tree({ root, latest, earlier })
  MiniTest.expect.equality(vim.tbl_map(function(item)
    return item.id
  end, built[root.thread_id].replies), { "earlier", "latest" })
end

T["comment jump reports edit failures"] = function()
  local original_cmd = vim.cmd
  local original_notify = vim.notify
  local command_seen
  local notification

  vim.cmd = function(command)
    command_seen = command
    error("Vim(edit):E325: ATTENTION")
  end
  vim.notify = function(message, level)
    notification = { message = message, level = level }
  end

  local call_ok, jumped = pcall(list._jump_to_comment, {
    file = "file with spaces.lua",
    line_start = 10,
    line_end = 10,
    anchor_status = "attached",
  })

  vim.cmd = original_cmd
  vim.notify = original_notify

  MiniTest.expect.equality(call_ok, true)
  MiniTest.expect.equality(jumped, false)
  MiniTest.expect.equality(command_seen, "edit file\\ with\\ spaces.lua")
  MiniTest.expect.equality(notification.level, vim.log.levels.ERROR)
  MiniTest.expect.match(notification.message, "Failed to open review comment target file with spaces.lua")
  MiniTest.expect.match(notification.message, "E325: ATTENTION")
end

return T
