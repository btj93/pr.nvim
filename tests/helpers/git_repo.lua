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

	-- Escape hatch: run an arbitrary `git -C root ...` and return trimmed stdout.
	-- Used by specs that need one-off plumbing (branch -D, fetch, rev-parse).
	function repo.git(...)
		return git(root, ...)
	end

	-- Repoint `origin` at a new URL. Local integration specs flip origin between
	-- a fabricated remote-host URL (so provider `_parse_remote_url` can derive
	-- owner/repo) and the local bare path (so a REAL `git fetch origin` works).
	function repo.set_origin_url(url)
		git(root, "remote", "set-url", "origin", url)
	end

	-- Push a branch/refspec to the sibling bare origin created by bare_origin.
	function repo.push_bare(refspec)
		assert(repo.bare, "repo.push_bare requires create({ bare_origin = true })")
		git(root, "push", "-q", repo.bare, refspec)
	end

	function repo.cleanup()
		vim.fn.delete(root, "rf")
		if repo.bare then
			vim.fn.delete(repo.bare, "rf")
		end
	end

	for relpath, lines in pairs(opts.files or {}) do
		repo.write(relpath, lines)
	end
	repo.commit("initial")

	-- Optional sibling *bare* repo usable as a real fetchable origin. `origin`
	-- itself is left pointing at opts.origin (a host-shaped URL for parsing); the
	-- bare lives at repo.bare and receives the initial commit on `main`. Specs
	-- push feature branches with repo.push_bare and flip origin's URL to the bare
	-- path (repo.set_origin_url) right before exercising a real fetch/checkout.
	if opts.bare_origin then
		local bare = vim.fn.tempname() .. ".git"
		vim.fn.mkdir(bare, "p")
		git(bare, "init", "--bare", "-q", "-b", "main")
		git(root, "push", "-q", bare, "main")
		repo.bare = bare
	end

	return repo
end

return M
