local config = require("commentary.config")
local state = require("commentary.state")

local test_dir

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      test_dir = vim.fn.tempname()
      vim.fn.mkdir(test_dir, "p")
      config.setup({
        comment = {
          storage = {
            backend = "file",
            file = { dir = test_dir },
          },
        },
      })
      state._reset()
      package.loaded["commentary.storage.file"] = nil
    end,
    post_case = function()
      state._reset()
      config.setup({ comment = { storage = { backend = "memory" } } })
      require("commentary.storage.memory")._reset()
      state.init()
      pcall(vim.api.nvim_del_augroup_by_name, "CommentaryDeleteReplyTests")
      vim.fn.delete(test_dir, "rf")
    end,
  },
})

T["file storage deletes replies by rewriting their thread"] = function()
  local storage = require("commentary.storage.file")
  storage.init()

  local root = {
    id = "root",
    thread_id = "root_thread",
    file = "lua/example.lua",
    line_start = 12,
    line_end = 12,
    author = "Reviewer",
    timestamp = 1000,
    comment = "Root comment",
    context_lines = {},
  }
  local replies = {
    vim.tbl_extend("force", vim.deepcopy(root), {
      id = "reply-1",
      parent_id = root.id,
      author = "Author",
      timestamp = 1001,
      comment = "First reply",
    }),
    vim.tbl_extend("force", vim.deepcopy(root), {
      id = "reply-2",
      parent_id = root.id,
      author = "Reviewer",
      timestamp = 1002,
      comment = "Second reply",
    }),
  }

  local markdown = storage.format_thread_as_markdown({ root, replies[1], replies[2] })
  require("commentary.utils").save_to_file(test_dir .. "/root.md", markdown)
  storage.reload()

  local comments = storage.get_all()
  MiniTest.expect.equality(#comments, 3)

  state.init()
  local events = {}
  local group = vim.api.nvim_create_augroup("CommentaryDeleteReplyTests", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CommentaryCommentsChanged",
    callback = function(args)
      table.insert(events, vim.deepcopy(args.data))
    end,
  })

  MiniTest.expect.equality(state.delete_comment(comments[2].id), true)
  MiniTest.expect.equality(#events, 1)
  MiniTest.expect.equality(events[1].source, "editor")
  MiniTest.expect.equality(#events[1].added, 0)
  MiniTest.expect.equality(#events[1].removed, 1)
  MiniTest.expect.equality(events[1].removed[1].comment, "First reply")
  MiniTest.expect.equality(#events[1].updated, 0)

  storage.reload()
  comments = storage.get_all()
  MiniTest.expect.equality(#comments, 2)
  MiniTest.expect.equality(comments[1].comment, "Root comment")
  MiniTest.expect.equality(comments[2].comment, "Second reply")
  MiniTest.expect.equality(vim.fn.filereadable(test_dir .. "/root.md"), 1)

  MiniTest.expect.equality(storage.delete(comments[2].id), true)
  storage.reload()
  comments = storage.get_all()
  MiniTest.expect.equality(#comments, 1)
  MiniTest.expect.equality(comments[1].comment, "Root comment")

  MiniTest.expect.equality(storage.delete(comments[1].id), true)
  MiniTest.expect.equality(vim.fn.filereadable(test_dir .. "/root.md"), 0)
end

T["file storage keeps a thread in one stable file"] = function()
  local storage = require("commentary.storage.file")
  storage.init()

  local root = {
    id = "root",
    thread_id = "root_thread",
    file = "lua/example.lua",
    line_start = 12,
    line_end = 12,
    author = "Reviewer",
    timestamp = 1000,
    comment = "Root comment",
    context_lines = {},
  }
  MiniTest.expect.equality(storage.add(root), "root")

  local reply = vim.tbl_extend("force", vim.deepcopy(root), {
    id = "reply",
    parent_id = root.id,
    author = "Author",
    timestamp = 1001,
    comment = "Reply",
  })
  MiniTest.expect.equality(storage.add(reply), "reply")

  MiniTest.expect.equality(vim.fn.glob(test_dir .. "/*.md", false, true), { test_dir .. "/root.md" })
  storage.reload()
  MiniTest.expect.equality(#storage.get_all(), 2)
end

return T
