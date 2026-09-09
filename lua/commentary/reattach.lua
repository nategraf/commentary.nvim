local M = {}
local state = require("commentary.state")
local utils = require("commentary.utils")
local runtime = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")

-- Revalidate the destination and stored attachment, not just the picker snapshot.
function M.apply(id, expected, candidate, root)
  local stat = vim.uv.fs_lstat(candidate.file)
  if utils.get_project_root() ~= root or utils.find_git_root(candidate.file) ~= root or (stat and stat.type ~= "file") then
    return false, "Project changed; run CommentaryReattach! again"
  end
  local buf = vim.fn.bufadd(candidate.file)
  local ok = pcall(vim.fn.bufload, buf)
  if not ok or not vim.api.nvim_buf_is_loaded(buf) then return false, "Could not load destination" end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if vim.fn.sha256(table.concat(lines, "\n")) ~= candidate.hash then
    return false, "Source changed; run CommentaryReattach! again"
  end
  local first, last = candidate.line_start, candidate.line_end
  if not state.reattach_thread(id, {
    bufnr = buf, file = candidate.file, line_start = first, line_end = last,
    lines = vim.list_slice(lines, first, last),
    before_lines = vim.list_slice(lines, math.max(1, first - 3), first - 1),
    after_lines = vim.list_slice(lines, last + 1, math.min(#lines, last + 3)),
  }, expected) then return false, "Thread removed or attachment changed; search again" end
  return true
end

function M.search(id, expected)
  local available, pickers = pcall(require, "telescope.pickers")
  if not available then
    vim.notify("Candidate previews require Telescope; use :CommentaryReattach at the destination instead", vim.log.levels.WARN)
    return
  end
  local root = utils.get_project_root()
  local buffers, bytes, skipped = {}, 0, false
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and vim.startswith(name, root .. "/") then
      local size = vim.api.nvim_buf_get_offset(buf, vim.api.nvim_buf_line_count(buf))
      if size <= 2 * 1024 * 1024 and bytes + size <= 16 * 1024 * 1024 then
        table.insert(buffers, { name = name, lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
          endofline = vim.bo[buf].endofline })
        bytes = bytes + size
      else
        skipped = true
      end
    end
  end
  expected = vim.deepcopy(expected)
  local actions = require("telescope.actions")
  local finders = require("telescope.finders")
  local function finder(candidates)
    return finders.new_table({ results = candidates, entry_maker = function(item)
      local label = string.format("%s:%d [%s] %s", item.file:sub(#root + 2), item.line_start, item.evidence, item.text)
      return { value = item, display = label, ordinal = label, filename = item.file, lnum = item.line_start }
    end })
  end
  local closed, job = false, nil
  local picker = pickers.new({}, {
    prompt_title = "Reattach: searching repository… (Esc cancels)",
    finder = finder({}),
    sorter = require("telescope.config").values.generic_sorter({}),
    previewer = require("telescope.previewers").new_buffer_previewer({
      define_preview = function(self, entry)
        local item = entry.value
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, item.preview)
        local ft = vim.filetype.match({ filename = item.file })
        if ft then vim.bo[self.state.bufnr].filetype = ft end
        vim.api.nvim_buf_clear_namespace(self.state.bufnr, -1, 0, -1)
        for line = item.line_start, math.min(item.line_end, item.preview_start + #item.preview - 1) do
          vim.api.nvim_buf_add_highlight(self.state.bufnr, -1, "Visual", line - item.preview_start, 0, -1)
        end
      end,
    }),
    attach_mappings = function(prompt, map)
      vim.api.nvim_create_autocmd("BufWipeout", { buffer = prompt, once = true, callback = function()
        closed = true
        if job then job:kill(15) end
      end })
      map("i", "<Esc>", function() actions.close(prompt) end)
      actions.select_default:replace(function()
        local entry = require("telescope.actions.state").get_selected_entry()
        if not entry then return end
        actions.close(prompt)
        local ok, reason = M.apply(id, expected, entry.value, root)
        vim.notify(ok and "Review thread reattached" or reason, ok and vim.log.levels.INFO or vim.log.levels.WARN)
      end)
      return true
    end,
  })
  picker:find()
  job = vim.system({ vim.v.progpath, "--headless", "--noplugin", "-u", "NONE", "-n", "-i", "NONE",
    "-l", runtime .. "/lua/commentary/worker.lua" }, {
    text = true, timeout = 15000, stdin = vim.json.encode({ operation = "candidates", runtime = runtime,
      cwd = root, comment = expected, buffers = buffers,
      config = { comment = { storage = require("commentary.config").get("comment.storage") } } }),
  }, vim.schedule_wrap(function(result)
    job = nil
    if closed then return end
    local ok, data = pcall(vim.json.decode, result.stdout or "")
    if result.code ~= 0 or not ok or type(data.candidates) ~= "table" then
      actions.close(picker.prompt_bufnr)
      vim.notify("Candidate search failed or timed out; use :CommentaryReattach at the destination", vim.log.levels.WARN)
      return
    end
    data.truncated = data.truncated or skipped
    picker:refresh(finder(data.candidates), { reset_prompt = false })
    picker.prompt_border:change_title("Reattach: choose a location" .. (data.truncated and " (partial search)" or ""))
    if data.truncated or #data.candidates == 0 then
      vim.notify(string.format("Found %d candidates%s. Manual fallback: :CommentaryReattach at the destination",
        #data.candidates, data.truncated and " (search limits reached)" or ""))
    end
  end))
end

function M.start()
  local comment = require("commentary.ui").comment_under_cursor()
  local prompt = vim.api.nvim_get_current_buf()
  if not comment and vim.bo[prompt].filetype == "TelescopePrompt" then
    local ok, entry = pcall(function() return require("telescope.actions.state").get_selected_entry() end)
    if ok and entry and type(entry.value) == "table" and entry.value.data then
      comment = entry.value.data.root_comment
      if comment then require("telescope.actions").close(prompt) end
    end
  end
  local storage = state.get_storage()
  if storage.reload then storage.reload() end
  local threads = require("commentary.thread").build_thread_tree(storage.get_all())
  if comment then
    for id, data in pairs(threads) do
      if data.root_comment.id == comment.id or id == comment.thread_id then
        return M.search(id, data.root_comment)
      end
    end
    vim.notify("Thread no longer exists", vim.log.levels.WARN)
    return
  end
  vim.ui.select(require("commentary.list")._sort_thread_list(threads, "file"), {
    prompt = "Choose a thread to locate",
    format_item = require("commentary.list")._format_telescope_thread_entry,
  }, function(choice) if choice then M.search(choice.id, choice.data.root_comment) end end)
end

return M
