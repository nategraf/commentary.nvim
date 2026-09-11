-- End-to-end file-storage benchmark; llvm-project is only read, never modified.
vim.opt.rtp:append(vim.fn.getcwd())
vim.o.swapfile = false
local root = assert(vim.env.REVIEW_ROOT, "Set REVIEW_ROOT")
vim.fn.chdir(root)
local files = vim.fn.glob(root .. "/llvm/lib/IR/*.cpp", false, true)
local storage = require("commentary.storage.file")
local state = require("commentary.state")
local base = vim.trim(vim.system({ "git", "-C", root, "rev-parse", "HEAD~100" }, {text=true}):wait().stdout)
local inputs = {}
for i = 1, math.min(24, #files) do
  local lines = vim.fn.readfile(files[i])
  inputs[i] = { path = files[i]:sub(#root + 2), lines = lines }
  if i <= 8 then
    local buf = vim.fn.bufadd(files[i])
    vim.fn.bufload(buf)
  end
end
-- Optional synthetic unsaved buffer stresses transfer costs without changing
-- the checkout. The text is copied from LLVM, but no source snapshot is saved.
local extra_mib = tonumber(vim.env.REVIEW_BUFFER_MIB) or 0
if extra_mib > 0 then
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, root .. "/commentary-benchmark-unsaved.cpp")
  local line = inputs[1].lines[1] or "// LLVM benchmark"
  local lines = {}
  for i = 1, math.ceil(extra_mib * 1024 * 1024 / (#line + 1)) do lines[i] = line end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end
local counts = vim.env.REVIEW_COUNTS and vim.split(vim.env.REVIEW_COUNTS, ",") or { 100, 1000 }
for _, requested in ipairs(counts) do
  local count = assert(tonumber(requested))
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  for i = 1, count do
    local input = inputs[(i - 1) % #inputs + 1]
    local line = math.min(25 + math.floor(i / #inputs), #input.lines - 1)
    local comment = { id = "bench-" .. i, thread_id = "bench-" .. i .. "_thread", file = input.path,
      line_start = line, line_end = line, comment = "Benchmark review", author = "Test", timestamp = i,
      anchor = { version = 1, path = input.path, base_commit = base, selected = {input.lines[line]},
        before = {input.lines[line-1]}, after = {input.lines[line+1]} } }
    vim.fn.writefile(vim.split(storage.format_comment_as_markdown(comment), "\n"), dir .. "/" .. comment.id .. ".md")
  end
  state._reset()
  require("commentary.config").setup({comment={storage={backend="file", file={dir=dir}}}})
  state.init(true)
  local done, gap, beats, last = false, 0, 0, vim.uv.hrtime()
  local timer = vim.uv.new_timer()
  timer:start(5, 5, vim.schedule_wrap(function()
    local now = vim.uv.hrtime()
    gap, last, beats = math.max(gap, (now-last)/1e6), now, beats+1
  end))
  local started = vim.uv.hrtime()
  state.request_sync(function() done = true end)
  assert(vim.wait(30000, function() return done end, 5))
  -- Give the heartbeat a turn after applying state/signs; otherwise the most
  -- expensive main-thread part is accidentally excluded from the measurement.
  vim.wait(20, function() return false end, 5)
  timer:stop()
  timer:close()
  print(vim.json.encode({threads=count, files=#inputs, loaded=8 + (extra_mib > 0 and 1 or 0),
    extra_buffer_mib=extra_mib, elapsed_ms=(vim.uv.hrtime()-started)/1e6,
    max_heartbeat_gap_ms=gap, heartbeat_ticks=beats, lua_heap_kib=collectgarbage("count"),
    process_maxrss_kib=vim.uv.getrusage().maxrss}))
  assert(#state.get_comments()==count)
  state._reset()
  vim.fn.delete(dir, "rf")
end
