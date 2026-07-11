-- Real temp git repositories for integration specs. Every command goes
-- through `git -C root` so the helper never depends on Neovim's cwd.
local M = {}

local function git(root, ...)
	local out = vim.fn.system(vim.list_extend({ "git", "-C", root }, { ... }))
	assert(vim.v.shell_error == 0, ("git %s failed in %s:\n%s"):format(table.concat({ ... }, " "), root, out))
	return vim.trim(out)
end

function M.create(opts)
	opts = opts or {}
	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")
	git(root, "init", "-q", "-b", "main")
	git(root, "config", "user.name", "PR Test")
	git(root, "config", "user.email", "pr-test@example.invalid")
	git(root, "config", "commit.gpgsign", "false")
	git(root, "remote", "add", "origin", opts.origin or "git@github.com:owner/repo.git")

	local repo = { root = root }

	function repo.write(relpath, lines)
		local abs = root .. "/" .. relpath
		vim.fn.mkdir(vim.fn.fnamemodify(abs, ":h"), "p")
		vim.fn.writefile(lines, abs)
	end

	function repo.commit(msg)
		git(root, "add", "-A")
		git(root, "commit", "-q", "-m", msg or "commit", "--allow-empty")
		return repo.head()
	end

	function repo.checkout(branch, create)
		if create then
			git(root, "checkout", "-q", "-b", branch)
		else
			git(root, "checkout", "-q", branch)
		end
	end

	function repo.head()
		return git(root, "rev-parse", "HEAD")
	end

	function repo.cleanup()
		vim.fn.delete(root, "rf")
	end

	for relpath, lines in pairs(opts.files or {}) do
		repo.write(relpath, lines)
	end
	repo.commit("initial")
	return repo
end

return M
