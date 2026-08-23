local M = {}

local function comment_location(comment)
  local filename = vim.fn.fnamemodify(comment.file or "", ":~:.")
  local line = comment.line_start == comment.line_end and tostring(comment.line_start or 0)
    or string.format("%d-%d", comment.line_start or 0, comment.line_end or 0)
  return string.format("%s:%s", filename, line)
end

local function comment_preview(comment)
  local text = (comment.comment or ""):match("^[^\n]*") or ""
  local limit = require("code-review.config").get("notifications.max_preview_length") or 80
  if vim.fn.strchars(text) > limit then
    text = vim.fn.strcharpart(text, 0, math.max(0, limit - 1)) .. "…"
  end
  return text
end

function M.notify_added(comments)
  local config = require("code-review.config")
  if not config.get("notifications.enabled") or #comments == 0 then
    return
  end

  local message
  if #comments == 1 then
    local comment = comments[1]
    message = string.format(
      "New review comment from %s at %s: %s",
      comment.author or "unknown author",
      comment_location(comment),
      comment_preview(comment)
    )
  else
    message = string.format("%d new review comments loaded", #comments)
  end

  vim.notify(message, vim.log.levels.INFO, { title = "Code Review" })
end

function M.setup()
  local group = vim.api.nvim_create_augroup("CodeReviewNotifications", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "CodeReviewCommentsChanged",
    callback = function(args)
      local changes = args.data or {}
      if changes.source ~= "editor" then
        M.notify_added(changes.added or {})
      end
    end,
    desc = "Notify when new code review comments are loaded",
  })
end

return M
