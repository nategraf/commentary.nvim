-- Read-only benchmark: REVIEW_ROOT=/path/to/repo nvim --headless -u NONE -i NONE -l tests/benchmark_anchors.lua
vim.opt.rtp:append(vim.fn.getcwd())
local root = assert(vim.env.REVIEW_ROOT, "Set REVIEW_ROOT")
vim.fn.chdir(root)
local anchor = require("commentary.anchor")
local function git(args)
  return vim.trim(vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }):wait().stdout)
end
local base = git({ "rev-parse", "HEAD~100" })
local file = "llvm/lib/IR/Module.cpp"
local lines = vim.fn.readfile(root .. "/" .. file)
for _, count in ipairs({ 0, 1, 50, 200 }) do
  local comments = {}
  for i = 1, count do
    local line = math.min(30 + i, #lines)
    comments[i] = {
      id = tostring(i), file = file, line_start = line, line_end = line,
      comment = "Benchmark", anchor = {
        version = 1, path = file, base_commit = base,
        selected = { lines[line] }, before = { lines[line - 1] }, after = { lines[line + 1] },
      },
    }
  end
  anchor.clear()
  local started = vim.uv.hrtime()
  local result = anchor.resolve_all(comments)
  print(vim.json.encode({ threads = #result, elapsed_ms = (vim.uv.hrtime() - started) / 1e6 }))
  local completed, beats, max_gap, last = false, 0, 0, vim.uv.hrtime()
  local timer = vim.uv.new_timer()
  timer:start(5, 5, vim.schedule_wrap(function()
    local now = vim.uv.hrtime()
    max_gap = math.max(max_gap, (now - last) / 1e6)
    last, beats = now, beats + 1
  end))
  started = vim.uv.hrtime()
  require("commentary.config").setup({})
  require("commentary.refresh").request(comments, function() completed = true end)
  assert(vim.wait(30000, function() return completed end, 5), "Worker timed out")
  timer:stop()
  timer:close()
  print(vim.json.encode({ mode = "worker", threads = count, elapsed_ms = (vim.uv.hrtime() - started) / 1e6,
    heartbeat_ticks = beats, max_heartbeat_gap_ms = max_gap }))
end
