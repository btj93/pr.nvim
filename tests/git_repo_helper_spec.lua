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
end)
