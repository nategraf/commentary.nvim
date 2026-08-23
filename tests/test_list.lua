local file_storage = require("code-review.storage.file")
local list = require("code-review.list")
local thread = require("code-review.thread")
local preview = require("code-review.list-preview")

require("code-review.config").setup({})

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
    status = "open",
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
        file = "lua/code-review/list.lua",
        line_start = 12,
        line_end = 14,
        comment = "Keep the picker concise\nMore detail belongs in the preview.",
        anchor_status = "attached",
      },
      replies = { { comment = "Reply" } },
    },
    status = "open",
  }

  MiniTest.expect.equality(
    list._format_telescope_thread_entry(thread_info),
    "lua/code-review/list.lua:12-14: Keep the picker concise"
  )
end

return T
