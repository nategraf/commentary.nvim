local M = {}
local generation, running, pending = 0, false, nil
local runtime = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")

--- Coalesce requests and apply only a complete, current snapshot. Heavy file,
--- Git and diff work lives in a clean Neovim process, not the UI event loop.
function M.request(comments, callback, options)
  generation = generation + 1
  pending = { generation = generation, comments = comments, callback = callback, options = options or {} }
  if running then return end
  running = true
  vim.defer_fn(function()
    local current = pending
    pending = nil
    if not current then running = false; return end
    local cwd, buffers, ticks = vim.fn.getcwd(), {}, {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name ~= "" then
          ticks[bufnr] = { tick = vim.api.nvim_buf_get_changedtick(bufnr), name = name, endofline = vim.bo[bufnr].endofline }
          table.insert(buffers, { name = name, lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
            endofline = vim.bo[bufnr].endofline })
        end
      end
    end
    local request = { runtime = runtime, cwd = cwd, buffers = buffers,
      comments = current.comments, config = require("commentary.config").get_all(),
      evidence = current.options.evidence, recover = current.options.recover }
    -- Config can contain functions (sorters etc.). Only storage configuration
    -- is relevant to the worker and must cross the JSON boundary.
    request.config = { comment = { storage = request.config.comment.storage } }
    local function failed(message)
      vim.notify("Commentary refresh failed: " .. message, vim.log.levels.ERROR)
      if current.options.on_error then current.options.on_error() end
    end
    local on_exit = vim.schedule_wrap(function(result)
        running = false
        if current.generation == generation and cwd == vim.fn.getcwd() then
          local valid = true
          for bufnr, snapshot in pairs(ticks) do
            valid = valid and vim.api.nvim_buf_is_loaded(bufnr)
              and vim.api.nvim_buf_get_changedtick(bufnr) == snapshot.tick
              and vim.api.nvim_buf_get_name(bufnr) == snapshot.name
              and vim.bo[bufnr].endofline == snapshot.endofline
          end
          if not valid then
            M.request(current.comments, current.callback, current.options)
          elseif result.code == 0 then
            local ok, decoded = pcall(vim.json.decode, result.stdout)
            if ok and type(decoded) == "table" and type(decoded.comments) == "table" and type(decoded.resolved) == "table" then
              local applied, err = pcall(current.callback, decoded)
              if not applied then failed(tostring(err)) end
            else failed("invalid worker response") end
          else
            failed(result.stderr or "")
          end
        end
        if pending then M.request(pending.comments, pending.callback, pending.options) end
      end)
    local ok, err = pcall(vim.system, { vim.v.progpath, "--headless", "--noplugin", "-u", "NONE", "-n", "-i", "NONE",
      "-l", runtime .. "/lua/commentary/worker.lua" },
      { stdin = vim.json.encode(request), text = true, timeout = 30000 }, on_exit)
    if not ok then on_exit({ code = -1, stderr = tostring(err) }) end
  end, 30)
end

function M.cancel()
  generation = generation + 1
  pending = nil
end

function M.is_running() return running or pending ~= nil end
return M
