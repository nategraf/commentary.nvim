local M = {}

-- Default configuration
local defaults = {
  -- UI settings
  ui = {
    -- Floating window settings for comment input
    input_window = {
      width = 80,
      height = 1,
      max_height = 20, -- Maximum height when content requires scrolling
      border = "rounded",
      title = " Add Comment (C-CR to submit) ",
      title_pos = "center",
    },
    -- Preview window settings
    preview = {
      split = "vertical", -- 'vertical' or 'horizontal' or 'float'
      vertical_width = 100,
      horizontal_height = 20,
      float = {
        width = 0.85,
        height = 0.8,
        border = "rounded",
        title = " Review Preview ",
        title_pos = "center",
      },
    },
    -- Sign column indicators
    signs = {
      enabled = true,
      text = "┃",
      texthl = "CommentarySign",
      linehl = "",
      numhl = "",
    },
    -- Virtual text indicators
    virtual_text = {
      enabled = true,
      prefix = " 󰆉 ",
      hl = "CommentaryVirtualText",
    },
  },
  -- Output settings
  output = {
    date_format = "%Y-%m-%d %H:%M:%S",
    -- Default save directory (nil means current directory)
    save_dir = nil,
    -- Output format: "detailed" (full markdown) or "minimal" (flat, for AI)
    format = "detailed",
  },
  -- Comment settings
  comment = {
    anchor = {
      -- Surrounding lines used to validate and recover persisted anchors.
      context_lines = 3,
    },
    -- Storage configuration
    storage = {
      -- Backend type: "memory" or "file"
      backend = "memory",
      -- Memory storage settings
      memory = {
        -- No settings for memory storage yet
      },
      -- File storage settings
      file = {
        -- Directory for file storage
        -- Relative paths: resolved from project root (git root or cwd)
        -- Absolute paths: used as-is
        dir = ".commentary",
      },
    },
    -- Automatically copy each new comment to clipboard when added
    auto_copy_on_add = false,
  },
  -- Notifications emitted when synchronization loads external comments.
  notifications = {
    enabled = true,
    max_preview_length = 80,
  },
  -- Keymaps (set to false to disable all keymaps)
  keymaps = {
    -- Clear all comments
    clear = {
      mode = "n",
      key = "<leader>rx",
    },
    -- Add comment at cursor/selection
    add_comment = {
      mode = { "n", "v" },
      key = "<leader>rc",
    },
    -- Preview review
    preview = {
      mode = "n",
      key = "<leader>rp",
    },
    -- Save review to file
    save = {
      mode = "n",
      key = "<leader>rw",
    },
    -- Copy review to clipboard
    copy = {
      mode = "n",
      key = "<leader>ry",
    },
    -- Show comment at cursor
    show_comment = {
      mode = "n",
      key = "<leader>rs",
    },
    -- List all comments
    list_comments = {
      mode = "n",
      key = "<leader>rl",
    },
    -- Delete comment at cursor
    delete_comment = {
      mode = "n",
      key = "<leader>rd",
    },
    -- Edit comment at cursor
    edit_comment = {
      mode = "n",
      key = "<leader>re",
    },
    -- Reply to comment at cursor
    reply_comment = {
      mode = "n",
      key = "<leader>rr",
    },
    -- Navigate attached comments in the current buffer
    previous_comment = {
      mode = "n",
      key = "[r",
    },
    next_comment = {
      mode = "n",
      key = "]r",
    },
  },
  -- Integration settings
  integrations = {
    -- Automatically detect and use available pickers
    picker = "auto", -- 'auto', 'telescope', 'fzf-lua', 'snacks', false
  },
}

local config = {}

--- Merge user config with defaults
---@param opts table User configuration
---@return table
local function merge_config(opts)
  return vim.tbl_deep_extend("force", defaults, opts)
end

--- Setup configuration
---@param opts table User configuration
function M.setup(opts)
  config = merge_config(opts)

  -- Validate output.format
  local valid_formats = { detailed = true, minimal = true }
  local format = config.output and config.output.format
  if format and not valid_formats[format] then
    error(string.format("Invalid output.format: '%s'. Must be 'detailed' or 'minimal'", format))
  end

  -- Create highlight groups
  vim.api.nvim_set_hl(0, "CommentarySign", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "CommentaryVirtualText", { link = "Comment", default = true })
end

--- Get configuration value
---@param path string Dot-separated path to config value
---@return any
function M.get(path)
  local value = config
  for key in path:gmatch("[^.]+") do
    if type(value) ~= "table" then
      return nil
    end
    value = value[key]
  end
  return value
end

--- Get entire configuration
---@return table
function M.get_all()
  return config
end

return M
