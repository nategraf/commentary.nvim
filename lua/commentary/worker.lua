-- Private, read-only worker. Run with -u NONE --noplugin -n -i NONE -l.
local request = vim.json.decode(io.read("*a"))
vim.opt.rtp:append(request.runtime)
vim.fn.chdir(request.cwd)
require("commentary.config").setup(request.config)
for _, buffer in ipairs(request.buffers) do
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, buffer.name)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buffer.lines)
  vim.bo[bufnr].endofline = buffer.endofline
end
-- Do not initialize storage: initialization includes legacy migration writes.
local comments = request.comments or require("commentary.storage.file").get_all()
local recovered, evidence = require("commentary.history").recover(
  comments, require("commentary.utils").get_project_root(), request.evidence, request.recover
)
local resolved = require("commentary.anchor").resolve_all(recovered)
for index, comment in ipairs(resolved) do
  comment.anchor_bufnr = nil
  -- Derived provenance is a session cache, not an edit to stored metadata.
  comment.anchor = comments[index].anchor
end
io.stdout:write(vim.json.encode({ comments = comments, resolved = resolved, evidence = evidence }))
