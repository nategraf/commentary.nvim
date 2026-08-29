local utils = require("commentary.utils")
local test_dir
local original_cwd

local function mkdir(relative_path)
  local path = vim.fs.joinpath(test_dir, relative_path)
  vim.fn.mkdir(path, "p")
  return path
end

local function run(command)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      original_cwd = vim.fn.getcwd()
      test_dir = vim.fn.tempname()
      vim.fn.mkdir(test_dir, "p")
    end,
    post_case = function()
      vim.fn.chdir(original_cwd)
      vim.fn.delete(test_dir, "rf")
    end,
  },
})

T["find_git_root finds a normal repository"] = function()
  local root = mkdir("repository")
  mkdir("repository/.git")
  local nested = mkdir("repository/src/nested")

  MiniTest.expect.equality(utils.find_git_root(nested), root)
end

T["find_git_root finds a worktree with a .git file"] = function()
  local root = mkdir("worktree")
  local nested = mkdir("worktree/src/nested")
  vim.fn.writefile({ "gitdir: /some/git/worktrees/example" }, vim.fs.joinpath(root, ".git"))

  MiniTest.expect.equality(utils.find_git_root(nested), root)
  MiniTest.expect.equality(utils.normalize_path(vim.fs.joinpath(nested, "example.lua")), "src/nested/example.lua")

  vim.fn.chdir(nested)
  MiniTest.expect.equality(utils.get_project_root(), root)
end

T["relative comment storage stays in the worktree"] = function()
  local repository = vim.fs.joinpath(test_dir, "repository")
  local worktree = vim.fs.joinpath(test_dir, "worktree")
  run({ "git", "init", "--quiet", repository })
  run({
    "git",
    "-C",
    repository,
    "-c",
    "user.name=Commentary Tests",
    "-c",
    "user.email=commentary@example.invalid",
    "commit",
    "--quiet",
    "--allow-empty",
    "-m",
    "initial",
  })
  run({ "git", "-C", repository, "worktree", "add", "--quiet", "-b", "review", worktree })

  vim.fn.chdir(worktree)
  MiniTest.expect.equality(utils.get_storage_dir(".commentary"), vim.fs.joinpath(worktree, ".commentary"))
end

T["find_git_root ignores a symlinked .git marker"] = function()
  local root = mkdir("repository")
  local nested = mkdir("repository/src")
  local git_dir = mkdir("actual-git-dir")
  vim.uv.fs_symlink(git_dir, vim.fs.joinpath(root, ".git"), { dir = true })

  MiniTest.expect.equality(utils.find_git_root(nested) == root, false)
end

T["find_git_root does not search through a symlinked directory"] = function()
  local root = mkdir("repository")
  mkdir("repository/.git")
  mkdir("repository/src")
  local link = vim.fs.joinpath(test_dir, "repository-link")
  vim.uv.fs_symlink(root, link, { dir = true })

  MiniTest.expect.equality(utils.find_git_root(vim.fs.joinpath(link, "src")), nil)
end

return T
