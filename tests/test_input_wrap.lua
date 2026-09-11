local child = MiniTest.new_child_neovim()
local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    -- Use embedded stdio RPC instead of MiniTest's Unix-domain socket so
    -- renderer tests also run in socket-restricted sandboxes.
    local job = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "-u", "NONE", "-n", "-i", "NONE",
      "--cmd", "set lines=24 columns=80" }, { rpc = true })
    assert(job > 0, "Could not start embedded Neovim")
    child.job = { id = job, channel = job }
    child.lua([[vim.opt.rtp:append(vim.fn.getcwd())
      require('commentary.config').setup({ui={input_window={width=20,height=1,max_height=10}}})
      require('commentary.ui').show_comment_input(function() return true end)
    ]])
  end,
  post_case = function() child.stop() end,
} })

T["typing at a full-width line keeps the text visible"] = function()
  child.type_keys(string.rep("x", 19))
  child.type_keys("x")
  local screenshot = child.get_screenshot()
  local rows = {}
  for _, row in ipairs(screenshot.text) do table.insert(rows, table.concat(row)) end
  local screen = table.concat(rows, "\n")
  assert(screen:find(string.rep("x", 20), 1, true), "Full-width text vanished:\n" .. screen)
  MiniTest.expect.equality(child.api.nvim_win_get_height(0), 2)
end

local function visible_text()
  local screenshot = child.get_screenshot()
  local window = child.fn.getwininfo(child.api.nvim_get_current_win())[1]
  local rows = {}
  for row = window.winrow + 1, window.winrow + window.height do
    table.insert(rows, table.concat(vim.list_slice(screenshot.text[row], window.wincol + 1, window.wincol + window.width)))
  end
  return table.concat(rows):gsub("%s", "")
end

for name, text in pairs({
  unbroken = string.rep("x", 45),
  words = "alpha beta gamma delta epsilon zeta theta",
  wide = string.rep("界", 23),
  indented = "    alpha beta gamma delta epsilon zeta theta",
}) do
  T[name .. " stays visible at every typed character"] = function()
    local typed = ""
    for _, char in ipairs(vim.fn.split(text, "\\zs")) do
      child.type_keys(char)
      typed = typed .. char
      MiniTest.expect.equality(visible_text(), (typed:gsub("%s", "")))
    end
  end
end

T["leaving insert mode shrinks without changing text or cursor"] = function()
  child.type_keys(string.rep("x", 20))
  MiniTest.expect.equality(child.api.nvim_win_get_height(0), 2)
  child.type_keys("<Esc>")
  MiniTest.expect.equality(child.api.nvim_win_get_height(0), 1)
  MiniTest.expect.equality(child.api.nvim_win_get_cursor(0), { 1, 19 })
  MiniTest.expect.equality(visible_text(), string.rep("x", 20))
end

T["moving the insertion cursor to a full-width EOL grows the window"] = function()
  child.type_keys(string.rep("x", 20), "<Esc>", "0", "i")
  MiniTest.expect.equality(child.api.nvim_win_get_height(0), 1)
  child.type_keys("<End>")
  MiniTest.expect.equality(child.api.nvim_win_get_height(0), 2)
  MiniTest.expect.equality(visible_text(), string.rep("x", 20))
end

T["multiline input remains visible across resize and respects the height cap"] = function()
  child.type_keys("first", "<CR>", string.rep("x", 40))
  MiniTest.expect.equality(child.api.nvim_win_get_height(0), 4)
  MiniTest.expect.equality(visible_text(), "first" .. string.rep("x", 40))
  child.type_keys(string.rep("x", 200))
  MiniTest.expect.equality(child.api.nvim_win_get_height(0), 10)
end

return T
