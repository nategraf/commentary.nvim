local M = {}

local config = require("commentary.config")

--- Format comments to markdown
---@param comments table[]
---@return string
local function format_markdown(comments)
  local lines = {}
  local date_format = config.get("output.date_format")

  -- Header
  table.insert(lines, "# Code Review")
  table.insert(lines, "")
  table.insert(lines, string.format("**Date**: %s", os.date(date_format)))
  table.insert(lines, string.format("**Total Comments**: %d", #comments))
  table.insert(lines, "")

  -- Group comments by file
  local by_file = {}
  for _, comment in ipairs(comments) do
    by_file[comment.file] = by_file[comment.file] or {}
    table.insert(by_file[comment.file], comment)
  end

  -- Sort files
  local files = vim.tbl_keys(by_file)
  table.sort(files)

  -- Format each file's comments
  for _, file in ipairs(files) do
    table.insert(lines, string.format("## %s", file))
    table.insert(lines, "")

    local file_comments = by_file[file]
    -- Sort by line number
    table.sort(file_comments, function(a, b)
      return a.line_start < b.line_start
    end)

    for _, comment in ipairs(file_comments) do
      -- Location header
      if comment.line_start == comment.line_end then
        table.insert(lines, string.format("### Line %d", comment.line_start))
      else
        table.insert(lines, string.format("### Lines %d-%d", comment.line_start, comment.line_end))
      end

      -- Add timestamp
      table.insert(lines, string.format("**Time**: %s", os.date(date_format, comment.timestamp)))
      table.insert(lines, "")

      -- Context code if available
      if comment.context_lines and #comment.context_lines > 0 then
        table.insert(lines, "```")
        for i, line in ipairs(comment.context_lines) do
          local line_num = comment.line_start + i - 1
          table.insert(lines, string.format("%d: %s", line_num, line))
        end
        table.insert(lines, "```")
        table.insert(lines, "")
      end

      -- Comment text
      table.insert(lines, comment.comment)
      table.insert(lines, "")
    end
  end

  return table.concat(lines, "\n")
end

--- Format comments to minimal format (flat, for AI)
---@param comments table[]
---@return string
local function format_minimal(comments)
  local lines = {}
  for _, comment in ipairs(comments) do
    local location
    if comment.line_start == comment.line_end then
      location = string.format("%s:L%d", comment.file, comment.line_start)
    else
      location = string.format("%s:L%d-%d", comment.file, comment.line_start, comment.line_end)
    end
    -- Join multi-line comments into single line
    local text = comment.comment:gsub("\n", " ")
    table.insert(lines, location .. ": " .. text)
  end
  return table.concat(lines, "\n")
end

--- Format comments based on configured format
---@param comments table[]
---@return string
function M.format(comments)
  local format_type = config.get("output.format") or "detailed"
  if format_type == "minimal" then
    return format_minimal(comments)
  else
    return format_markdown(comments)
  end
end

--- Format a single comment for preview display (always detailed)
--- This is used for Telescope, fzf-lua, and buffer previews
---@param comment table The comment object
---@param opts? { include_header?: boolean, use_ansi?: boolean }
---@return string[] Lines of formatted markdown
function M.format_single(comment, opts)
  opts = opts or {}
  local include_header = opts.include_header ~= false -- default true
  local use_ansi = opts.use_ansi or false

  local lines = {}

  -- ANSI color codes for fzf
  local colors = {
    header = use_ansi and "\x1b[1;34m" or "", -- Bold blue
    section = use_ansi and "\x1b[1;33m" or "", -- Bold yellow
    code = use_ansi and "\x1b[36m" or "", -- Cyan
    reset = use_ansi and "\x1b[0m" or "", -- Reset
  }

  if include_header then
    -- Header with file and line info
    table.insert(
      lines,
      string.format("%s## %s:%d-%d%s", colors.header, comment.file, comment.line_start, comment.line_end, colors.reset)
    )
    table.insert(lines, "")
  end

  -- Code context if available
  if comment.context_lines and #comment.context_lines > 0 then
    table.insert(lines, colors.section .. "### Context" .. colors.reset)
    table.insert(lines, "")
    table.insert(lines, colors.code .. "```" .. vim.fn.fnamemodify(comment.file, ":e"))
    for _, line in ipairs(comment.context_lines) do
      table.insert(lines, line)
    end
    table.insert(lines, "```" .. colors.reset)
    table.insert(lines, "")
  end

  -- Comment content
  table.insert(lines, colors.section .. "### Comment" .. colors.reset)
  table.insert(lines, "")
  -- Split comment by lines and add each line
  for line in comment.comment:gmatch("[^\n]+") do
    table.insert(lines, line)
  end

  return lines
end

--- Parse formatted content back to comments
---@param content string
---@return table[] comments
function M.parse(content)
  return M.parse_markdown(content)
end

--- Parse markdown content
---@param content string
---@return table[]
function M.parse_markdown(content)
  local lines = vim.split(content, "\n")
  local comments = {}
  local current_comment = nil
  local in_code_block = false
  local i = 1

  while i <= #lines do
    local line = lines[i]

    -- Skip empty lines and header
    if line:match("^#%s+Code Review") or line:match("^%*%*Date%*%*:") or line:match("^%*%*Total Comments%*%*:") then
      i = i + 1
      goto continue
    end

    -- File header
    if line:match("^##%s+(.+)") then
      -- Save any pending comment before starting new file
      if current_comment and current_comment.comment and current_comment.comment ~= "" then
        table.insert(comments, current_comment)
      end

      local file = line:match("^##%s+(.+)")
      current_comment = { file = file }
      i = i + 1
      goto continue
    end

    -- Line/Lines header
    if line:match("^###%s+Line[s]?%s+") then
      if current_comment and current_comment.comment then
        -- Save previous comment
        table.insert(comments, current_comment)
      end

      local single = line:match("^###%s+Line%s+(%d+)")
      if single then
        current_comment = {
          file = current_comment and current_comment.file,
          line_start = tonumber(single),
          line_end = tonumber(single),
          context_lines = {},
          comment = "",
        }
      else
        local start, end_ = line:match("^###%s+Lines%s+(%d+)%-(%d+)")
        if start and end_ then
          current_comment = {
            file = current_comment and current_comment.file,
            line_start = tonumber(start),
            line_end = tonumber(end_),
            context_lines = {},
            comment = "",
          }
        end
      end
      i = i + 1
      goto continue
    end

    -- Code block markers
    if line == "```" then
      in_code_block = not in_code_block
      i = i + 1
      goto continue
    end

    -- Inside code block
    if in_code_block and current_comment then
      -- Parse context line (format: "123: code here")
      local num, code = line:match("^(%d+):%s(.*)$")
      if num and code then
        table.insert(current_comment.context_lines, code)
      end
      i = i + 1
      goto continue
    end

    -- Skip Time line
    if line:match("^%*%*Time%*%*:") then
      i = i + 1
      goto continue
    end

    -- Comment text
    if current_comment and not in_code_block and line ~= "" then
      if current_comment.comment == "" then
        current_comment.comment = line
      else
        current_comment.comment = current_comment.comment .. "\n" .. line
      end
    end

    ::continue::
    i = i + 1
  end

  -- Save last comment
  if current_comment and current_comment.comment and current_comment.comment ~= "" then
    table.insert(comments, current_comment)
  end

  -- Restore IDs and timestamps
  for i, comment in ipairs(comments) do
    comment.id = comment.id or (vim.fn.localtime() .. "_" .. i)
    comment.timestamp = comment.timestamp or os.time()
  end

  return comments
end

--- Save formatted content to file
---@param content string
---@param path string?
function M.save_to_file(content, path)
  local utils = require("commentary.utils")

  if not path then
    local save_dir = config.get("output.save_dir") or vim.fn.getcwd()
    local filename = utils.generate_filename("markdown")
    path = vim.fn.fnamemodify(save_dir .. "/" .. filename, ":p")
  else
    path = vim.fn.fnamemodify(path, ":p")
  end

  -- Ensure directory exists
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")

  -- Write file
  local file = io.open(path, "w")
  if not file then
    error("Failed to open file: " .. path)
  end

  file:write(content)
  file:close()

  vim.notify("Reviews saved to: " .. path)
end

return M
