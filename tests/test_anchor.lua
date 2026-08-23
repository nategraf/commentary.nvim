local anchor = require("code-review.anchor")
local file_storage = require("code-review.storage.file")

vim.opt_global.swapfile = false
vim.opt_local.swapfile = false

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      anchor.clear()
    end,
    post_case = function()
      anchor.clear()
    end,
  },
})

T["content matching uses context and rejects ties"] = function()
  local stored = {
    selected = { "target" },
    before = { "before" },
    after = { "after" },
  }
  local candidates = anchor._content_candidates(stored, {
    "before",
    "target",
    "after",
    "other",
    "target",
    "other",
  }, false)

  MiniTest.expect.equality(candidates[1], { line_start = 2, line_end = 2, score = 2 })
  MiniTest.expect.equality(candidates[2].score, 0)

  local tied = anchor._content_candidates({ selected = { "target" } }, { "target", "target" }, false)
  MiniTest.expect.equality(tied[1].score, tied[2].score)
end

T["native diff projects insertions, modifications, and deletion"] = function()
  local stored = { base_line_start = 3, base_line_end = 3 }
  local base = "a\nb\nc\nd\n"

  MiniTest.expect.equality(anchor._diff_projection(stored, base, "x\na\nb\nc\nd\n"), {
    status = "attached",
    line_start = 4,
    line_end = 4,
  })
  MiniTest.expect.equality(anchor._diff_projection(stored, base, "a\nb\nC\nd\n"), {
    status = "modified",
    line_start = 3,
    line_end = 3,
  })
  MiniTest.expect.equality(anchor._diff_projection(stored, base, "a\nb\nd\n"), { status = "deleted" })
end

T["Git name-status parsing handles renames and deletion"] = function()
  MiniTest.expect.equality(anchor._parse_name_status("R100\0old.lua\0new.lua\0", "old.lua"), "new.lua")
  MiniTest.expect.equality(anchor._parse_name_status("D\0old.lua\0", "old.lua"), false)
  MiniTest.expect.equality(anchor._parse_name_status("M\0old.lua\0", "old.lua"), "old.lua")
end

T["file storage preserves anchors in frontmatter"] = function()
  local stored = {
    id = "anchor-roundtrip",
    file = "lua/example.lua",
    line_start = 2,
    line_end = 2,
    timestamp = 1,
    author = "Reviewer",
    comment = "Keep this stable",
    context_lines = { "target: value" },
    anchor = {
      version = 1,
      path = "lua/example.lua",
      start = { line = 2, column = 0 },
      finish = { line = 2, column = 13 },
      selected = { "target: value" },
      before = { "function example()" },
      after = { "end" },
    },
  }

  local markdown = file_storage.format_comment_as_markdown(stored)
  local parsed = file_storage._parse_comment_from_file(markdown, "anchor-roundtrip.md")
  MiniTest.expect.equality(#parsed, 1)
  MiniTest.expect.equality(parsed[1].anchor, stored.anchor)
end

T["unresolved comments are visible but not navigable in quickfix"] = function()
  local unresolved = {
    file = "missing.lua",
    line_start = 42,
    line_end = 42,
    comment = "No stale jumps",
    anchor_status = "missing-file",
    anchor_resolved = false,
  }

  local list = require("code-review.list")
  local item = list._comment_to_qf_item(unresolved)
  MiniTest.expect.equality(item.valid, 0)
  MiniTest.expect.equality(item.lnum, 0)
  MiniTest.expect.equality(item.text:find("%[missing%-file%]") ~= nil, true)
end


local Git = nil
local original_cwd = nil
local repo = nil
local current_buf = nil

local function git(args)
  local command = { "git", "-C", repo }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  if result.code ~= 0 then
    error(string.format("git %s failed: %s", table.concat(args, " "), result.stderr))
  end
  return vim.trim(result.stdout)
end

local function write_file(path, lines)
  vim.fn.writefile(lines, repo .. "/" .. path)
end

local function open_file(path)
  vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/" .. path))
  current_buf = vim.api.nvim_get_current_buf()
  return current_buf
end

local function make_comment(line, line_end)
  line_end = line_end or line
  local lines = vim.api.nvim_buf_get_lines(current_buf, 0, -1, false)
  local context = {
    bufnr = current_buf,
    file = "source.lua",
    line_start = line,
    line_end = line_end,
    start_col = 0,
    end_col = #lines[line_end],
    lines = vim.list_slice(lines, line, line_end),
    before_lines = vim.list_slice(lines, math.max(1, line - 2), line - 1),
    after_lines = vim.list_slice(lines, line_end + 1, math.min(#lines, line_end + 2)),
  }
  return {
    id = "comment-1",
    thread_id = "thread-1",
    file = "source.lua",
    line_start = line,
    line_end = line_end,
    comment = "Review this",
    context_lines = context.lines,
    anchor = anchor.capture(context),
  }
end

Git = MiniTest.new_set({
  hooks = {
    pre_case = function()
      anchor.clear()
      original_cwd = vim.fn.getcwd()
      repo = vim.fn.tempname()
      vim.fn.mkdir(repo, "p")
      git({ "init", "-q", "-b", "main" })
      git({ "config", "user.name", "Anchor Test" })
      git({ "config", "user.email", "anchor@example.test" })
      write_file("source.lua", {
        "local one = 1",
        "local two = 2",
        "local three = 3",
        "local four = 4",
        "local target = one + two",
        "return target",
        "-- footer",
      })
      git({ "add", "source.lua" })
      git({ "commit", "-q", "-m", "base" })
      vim.fn.chdir(repo)
      open_file("source.lua")
    end,
    post_case = function()
      anchor.clear()
      if current_buf and vim.api.nvim_buf_is_valid(current_buf) then
        vim.api.nvim_buf_delete(current_buf, { force = true })
      end
      vim.fn.chdir(original_cwd)
      vim.fn.delete(repo, "rf")
      current_buf = nil
      repo = nil
    end,
  },
})

Git["extmarks follow live edits and undo"] = function()
  local comment = make_comment(5)
  local initial = anchor.resolve(comment)
  MiniTest.expect.equality({ initial.anchor_status, initial.line_start }, { "attached", 5 })

  vim.api.nvim_buf_set_lines(current_buf, 0, 0, false, { "-- inserted" })
  local inserted = anchor.resolve(comment)
  MiniTest.expect.equality({ inserted.anchor_status, inserted.line_start }, { "attached", 6 })

  vim.api.nvim_buf_set_lines(current_buf, 5, 6, false, { "local changed = one - two" })
  local changed = anchor.resolve(comment)
  MiniTest.expect.equality({ changed.anchor_status, changed.line_start }, { "modified", 6 })

  vim.cmd("undo")
  local undone = anchor.resolve(comment)
  MiniTest.expect.equality({ undone.anchor_status, undone.line_start }, { "attached", 5 })
end

Git["insertions within a multiline anchor expand its live range"] = function()
  local comment = make_comment(4, 5)
  local initial = anchor.resolve(comment)
  MiniTest.expect.equality({ initial.anchor_status, initial.line_start, initial.line_end }, { "attached", 4, 5 })

  vim.api.nvim_buf_set_lines(current_buf, 4, 4, false, { "-- inserted inside selection" })
  local expanded = anchor.resolve(comment)
  MiniTest.expect.equality({ expanded.anchor_status, expanded.line_start, expanded.line_end }, { "modified", 4, 6 })
end


Git["resolves moves, modifications, deletions, and duplicate ambiguity"] = function()
  local comment = make_comment(5)
  vim.api.nvim_buf_delete(current_buf, { force = true })
  current_buf = nil

  write_file("source.lua", {
    "local target = one + two",
    "local one = 1",
    "local two = 2",
    "local three = 3",
    "local four = 4",
    "return target",
    "-- footer",
  })
  anchor.clear()
  local moved = anchor.resolve(comment)
  MiniTest.expect.equality({ moved.anchor_status, moved.line_start }, { "attached", 1 })

  write_file("source.lua", {
    "local one = 1",
    "local two = 2",
    "local three = 3",
    "local four = 4",
    "local target = one - two",
    "return target",
    "-- footer",
  })
  anchor.clear()
  local modified = anchor.resolve(comment)
  MiniTest.expect.equality({ modified.anchor_status, modified.line_start }, { "modified", 5 })

  write_file("source.lua", {
    "local one = 1",
    "local two = 2",
    "local three = 3",
    "local four = 4",
    "return target",
    "-- footer",
  })
  anchor.clear()
  MiniTest.expect.equality(anchor.resolve(comment).anchor_status, "deleted")

  local original = {
    "local one = 1",
    "local two = 2",
    "local three = 3",
    "local four = 4",
    "local target = one + two",
    "return target",
    "-- footer",
  }
  local duplicate = vim.deepcopy(original)
  vim.list_extend(duplicate, original)
  write_file("source.lua", duplicate)
  anchor.clear()
  MiniTest.expect.equality(anchor.resolve(comment).anchor_status, "ambiguous")
end


Git["follows renames across checkouts"] = function()
  local comment = make_comment(5)
  MiniTest.expect.equality(anchor.resolve(comment).file, "source.lua")

  git({ "switch", "-q", "-c", "renamed" })
  git({ "mv", "source.lua", "renamed.lua" })
  local renamed_lines = vim.fn.readfile(repo .. "/renamed.lua")
  table.insert(renamed_lines, 1, "-- branch header")
  write_file("renamed.lua", renamed_lines)
  git({ "add", "renamed.lua" })
  git({ "commit", "-q", "-m", "rename source" })

  local renamed = anchor.resolve(comment)
  MiniTest.expect.equality({ renamed.anchor_status, renamed.file, renamed.line_start }, {
    "attached",
    "renamed.lua",
    6,
  })

  git({ "switch", "-q", "main" })
  local original = anchor.resolve(comment)
  MiniTest.expect.equality({ original.anchor_status, original.file, original.line_start }, {
    "attached",
    "source.lua",
    5,
  })
end


Git["uses content anchors for comments created from dirty buffers"] = function()
  vim.api.nvim_buf_set_lines(current_buf, 0, 0, false, { "-- unsaved header" })
  local comment = make_comment(6)
  MiniTest.expect.equality(comment.anchor.base_line_start, nil)

  anchor.clear()
  local initial = anchor.resolve(comment)
  MiniTest.expect.equality({ initial.anchor_status, initial.line_start }, { "attached", 6 })

  vim.api.nvim_buf_set_lines(current_buf, 0, 0, false, { "-- another edit" })
  anchor.clear()
  local shifted = anchor.resolve(comment)
  MiniTest.expect.equality({ shifted.anchor_status, shifted.line_start }, { "attached", 7 })
end

Git["anchors an unsaved new file"] = function()
  vim.api.nvim_buf_delete(current_buf, { force = true })
  current_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(current_buf, repo .. "/new.lua")
  vim.api.nvim_buf_set_lines(current_buf, 0, -1, false, { "local new_file = true" })
  vim.api.nvim_set_current_buf(current_buf)

  local context = {
    bufnr = current_buf,
    file = "new.lua",
    line_start = 1,
    line_end = 1,
    start_col = 0,
    end_col = 21,
    lines = { "local new_file = true" },
    before_lines = {},
    after_lines = {},
  }
  local comment = {
    id = "new-file-comment",
    file = "new.lua",
    line_start = 1,
    line_end = 1,
    comment = "Unsaved file",
    anchor = anchor.capture(context),
  }

  MiniTest.expect.equality(comment.anchor.base_blob, nil)
  local resolved = anchor.resolve(comment)
  MiniTest.expect.equality({ resolved.anchor_status, resolved.file, resolved.line_start }, {
    "attached",
    "new.lua",
    1,
  })
end


Git["reports missing files and keeps legacy comments usable"] = function()
  local comment = make_comment(5)
  vim.api.nvim_buf_delete(current_buf, { force = true })
  current_buf = nil
  vim.fn.delete(repo .. "/source.lua")
  anchor.clear()
  MiniTest.expect.equality(anchor.resolve(comment).anchor_status, "missing-file")

  write_file("source.lua", { "first", "legacy target", "last" })
  local legacy = {
    id = "legacy",
    file = "source.lua",
    line_start = 2,
    line_end = 2,
    comment = "Old comment",
    context_lines = { "legacy target" },
  }
  anchor.clear()
  local resolved = anchor.resolve(legacy)
  MiniTest.expect.equality({ resolved.anchor_status, resolved.line_start }, { "attached", 2 })
end

T["Git-backed resolution"] = Git

return T
