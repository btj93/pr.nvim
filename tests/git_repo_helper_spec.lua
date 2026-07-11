local git_repo = require("helpers.git_repo")

describe("helpers.git_repo", function()
	local repo

	after_each(function()
		if repo then
			repo.cleanup()
			repo = nil
		end
	end)

	it("creates a repo with files, origin, and an initial commit", function()
		repo = git_repo.create({
			origin = "git@github.com:acme/widget.git",
			files = { ["lua/a.lua"] = { "line 1", "line 2" } },
		})
		assert.equals(1, vim.fn.isdirectory(repo.root .. "/.git"))
		local url = vim.fn.system({ "git", "-C", repo.root, "remote", "get-url", "origin" })
		assert.equals("git@github.com:acme/widget.git", vim.trim(url))
		assert.equals("line 2", vim.fn.readfile(repo.root .. "/lua/a.lua")[2])
		assert.equals(40, #repo.head())
	end)

	it("write + commit + checkout round-trip", function()
		repo = git_repo.create({ files = { ["f.txt"] = { "x" } } })
		local first = repo.head()
		repo.checkout("feature/x", true)
		repo.write("f.txt", { "x", "y" })
		local second = repo.commit("change f")
		assert.is_not.equals(first, second)
		assert.equals(second, repo.head())
	end)

	it("bare_origin: push a branch and fetch it back through origin", function()
		-- origin stays host-shaped for parsing; repo.bare is a real fetchable path.
		repo = git_repo.create({
			origin = "git@bitbucket.org:acme/widget.git",
			bare_origin = true,
			files = { ["f.txt"] = { "x" } },
		})
		assert.equals(1, vim.fn.isdirectory(repo.bare))
		-- The host-shaped URL is what a provider parses.
		assert.equals("git@bitbucket.org:acme/widget.git", repo.git("remote", "get-url", "origin"))

		-- Publish a branch to the bare origin, then drop it locally so a fetch is
		-- genuinely required to get it back.
		repo.checkout("feature/y", true)
		repo.write("f.txt", { "x", "y" })
		local sha = repo.commit("change f")
		repo.push_bare("feature/y")
		repo.checkout("main")
		repo.git("branch", "-D", "feature/y")

		-- Flip origin to the local bare path; a real fetch + checkout restores it.
		repo.set_origin_url(repo.bare)
		repo.git("fetch", "origin", "feature/y")
		repo.git("checkout", "feature/y")

		assert.equals("feature/y", repo.git("rev-parse", "--abbrev-ref", "HEAD"))
		assert.equals(sha, repo.head())
		assert.equals("x", vim.fn.readfile(repo.root .. "/f.txt")[1])
		assert.equals("y", vim.fn.readfile(repo.root .. "/f.txt")[2])
	end)
end)
