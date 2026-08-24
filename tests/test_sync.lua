local config = require("commentary.config")
local memory = require("commentary.storage.memory")
local notification = require("commentary.notification")
local state = require("commentary.state")

local events
local notifications
local test_dir
local original_notify = vim.notify

local function make_comment(id, text)
  return {
    id = id,
    file = "lua/example.lua",
    line_start = 12,
    line_end = 12,
    author = "Codex",
    timestamp = 1234,
    comment = text or "Please handle this case",
    thread_id = id and (id .. "_thread") or nil,
  }
end

local function reset_state()
  state._reset()
  memory._reset()
  state.init()
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      config.setup({
        comment = { storage = { backend = "memory" } },
        notifications = { enabled = true, max_preview_length = 80 },
      })
      reset_state()

      events = {}
      notifications = {}
      vim.notify = function(message, level, opts)
        table.insert(notifications, { message = message, level = level, opts = opts })
      end

      notification.setup()
      local group = vim.api.nvim_create_augroup("CommentarySyncTests", { clear = true })
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "CommentaryCommentsChanged",
        callback = function(args)
          table.insert(events, vim.deepcopy(args.data))
        end,
      })
    end,

    post_case = function()
      vim.notify = original_notify
      pcall(vim.api.nvim_del_augroup_by_name, "CommentarySyncTests")
      if test_dir then
        vim.fn.delete(test_dir, "rf")
        test_dir = nil
      end
    end,
  },
})

T["initial comments establish the baseline without notification"] = function()
  state._reset()
  memory._reset()
  memory.init()
  memory.add(make_comment("existing", "Already present"))
  state.init()

  local changes = state.sync_from_storage()

  MiniTest.expect.equality(changes, { added = {}, removed = {}, updated = {} })
  MiniTest.expect.equality(#events, 0)
  MiniTest.expect.equality(#notifications, 0)
end

T["external additions emit a change event and notification"] = function()
  memory.add(make_comment("external"))

  local changes = state.sync_from_storage()

  MiniTest.expect.equality(#changes.added, 1)
  MiniTest.expect.equality(changes.added[1].id, "external")
  MiniTest.expect.equality(#events, 1)
  MiniTest.expect.equality(events[1].source, "storage")
  MiniTest.expect.equality(#events[1].added, 1)
  MiniTest.expect.equality(#notifications, 1)
  MiniTest.expect.equality(
    notifications[1].message,
    "New review comment from Codex at lua/example.lua:12: Please handle this case"
  )
  MiniTest.expect.equality(notifications[1].level, vim.log.levels.INFO)
  MiniTest.expect.equality(notifications[1].opts.title, "Code Review")
end

T["file storage loads comments written by an external process"] = function()
  test_dir = vim.fn.tempname()
  config.setup({
    comment = {
      storage = {
        backend = "file",
        file = { dir = test_dir },
      },
    },
    notifications = { enabled = true },
  })
  state._reset()
  package.loaded["commentary.storage.file"] = nil
  state.init()

  vim.fn.mkdir(test_dir, "p")
  local file_storage = require("commentary.storage.file")
  local markdown = file_storage.format_comment_as_markdown(make_comment("external-file", "Written outside Neovim"))
  require("commentary.utils").save_to_file(test_dir .. "/external-file.md", markdown)

  local changes = state.sync_from_storage()

  MiniTest.expect.equality(#changes.added, 1)
  MiniTest.expect.equality(changes.added[1].id, "external-file")
  MiniTest.expect.equality(#events, 1)
  MiniTest.expect.equality(events[1].source, "storage")
  MiniTest.expect.equality(#notifications, 1)
  MiniTest.expect.match(notifications[1].message, "Written outside Neovim")
end

T["multiple external additions use one batched notification"] = function()
  memory.add(make_comment("external-1"))
  memory.add(make_comment("external-2"))

  state.sync_from_storage("github")

  MiniTest.expect.equality(#notifications, 1)
  MiniTest.expect.equality(notifications[1].message, "2 new review comments loaded")
  MiniTest.expect.equality(events[1].source, "github")
end

T["notifications can be disabled without suppressing change events"] = function()
  config.setup({
    comment = { storage = { backend = "memory" } },
    notifications = { enabled = false },
  })
  memory.add(make_comment("external"))

  state.sync_from_storage()

  MiniTest.expect.equality(#events, 1)
  MiniTest.expect.equality(#notifications, 0)
end

T["local additions and replies emit editor events without notifications"] = function()
  local root_id = state.add_comment(make_comment(nil, "Local root"))
  state.add_reply(root_id, "Local reply")

  local changes = state.sync_from_storage()

  MiniTest.expect.equality(changes, { added = {}, removed = {}, updated = {} })
  MiniTest.expect.equality(#events, 2)
  MiniTest.expect.equality(events[1].source, "editor")
  MiniTest.expect.equality(#events[1].added, 1)
  MiniTest.expect.equality(events[2].source, "editor")
  MiniTest.expect.equality(#events[2].added, 1)
  MiniTest.expect.equality(#notifications, 0)
end

T["local edits and deletions emit editor events"] = function()
  local id = state.add_comment(make_comment(nil, "Before"))
  events = {}

  state.update_comment(id, { comment = "After" })

  MiniTest.expect.equality(#events, 1)
  MiniTest.expect.equality(events[1].source, "editor")
  MiniTest.expect.equality(#events[1].updated, 1)
  MiniTest.expect.equality(events[1].updated[1].before.comment, "Before")
  MiniTest.expect.equality(events[1].updated[1].after.comment, "After")

  events = {}
  state.delete_comment(id)

  MiniTest.expect.equality(#events, 1)
  MiniTest.expect.equality(events[1].source, "editor")
  MiniTest.expect.equality(#events[1].removed, 1)
  MiniTest.expect.equality(#notifications, 0)
end

T["external replies are reported as new comments"] = function()
  local root = make_comment("root", "Root comment")
  state.add_comment(root)
  events = {}
  memory.add({
    id = "reply",
    file = root.file,
    line_start = root.line_start,
    line_end = root.line_end,
    author = "Codex",
    timestamp = 1235,
    comment = "External reply",
    thread_id = root.thread_id,
    parent_id = root.id,
  })

  local changes = state.sync_from_storage()

  MiniTest.expect.equality(#changes.added, 1)
  MiniTest.expect.equality(changes.added[1].id, "reply")
  MiniTest.expect.equality(#notifications, 1)
end

T["external edits emit changes without new-comment notifications"] = function()
  local comment = make_comment("edited", "Before")
  state.add_comment(comment)
  events = {}
  memory.update(comment.id, { comment = "After" })

  local changes = state.sync_from_storage()

  MiniTest.expect.equality(#changes.added, 0)
  MiniTest.expect.equality(#changes.updated, 1)
  MiniTest.expect.equality(changes.updated[1].before.comment, "Before")
  MiniTest.expect.equality(changes.updated[1].after.comment, "After")
  MiniTest.expect.equality(#events, 1)
  MiniTest.expect.equality(#notifications, 0)
end

return T
