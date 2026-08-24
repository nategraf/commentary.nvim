local config = require("code-review.config")
local memory = require("code-review.storage.memory")
local state = require("code-review.state")
local review = require("code-review")
local utils = require("code-review.utils")

local bufnr
local original_bufnr
local test_path

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      config.setup({ comment = { storage = { backend = "memory" } } })
      state._reset()
      memory._reset()
      state.init()

      original_bufnr = vim.api.nvim_get_current_buf()
      bufnr = vim.api.nvim_create_buf(false, true)
      test_path = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, test_path)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "one",
        "two",
        "three",
        "four",
        "five",
        "six",
        "seven",
        "eight",
      })
      vim.api.nvim_set_current_buf(bufnr)
    end,
    post_case = function()
      require("code-review.anchor").clear()
      if vim.api.nvim_buf_is_valid(original_bufnr) then
        vim.api.nvim_set_current_buf(original_bufnr)
      end
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
      state._reset()
      memory._reset()
      config.setup({ comment = { storage = { backend = "memory" } } })
      state.init()
    end,
  },
})

local function add_comment(line)
  state.add_comment({
    file = utils.normalize_path(test_path),
    line_start = line,
    line_end = line,
    context_lines = { vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] },
    comment = "Comment at line " .. line,
  })
end

T["next and previous comments navigate with wraparound"] = function()
  add_comment(3)
  add_comment(7)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  MiniTest.expect.equality(review.next_comment(), true)
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 3)
  MiniTest.expect.equality(review.next_comment(), true)
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 7)
  MiniTest.expect.equality(review.next_comment(), true)
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 3)

  MiniTest.expect.equality(review.previous_comment(), true)
  MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0)[1], 7)
end

T["navigation defaults use the review bracket bindings"] = function()
  MiniTest.expect.equality(config.get("keymaps.previous_comment.key"), "[r")
  MiniTest.expect.equality(config.get("keymaps.next_comment.key"), "]r")
end

return T
