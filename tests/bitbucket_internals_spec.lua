local bb = require("pr.providers.bitbucket")

describe("bitbucket._build_threads", function()
	it("returns empty table for empty input", function()
		assert.are.same({}, bb._build_threads({}))
	end)

	it("single root with no replies → one thread keyed by its id", function()
		local groups = bb._build_threads({ { id = 1, parent = vim.NIL, created_on = "t0" } })
		assert.equals(1, #groups[1])
		assert.equals(1, groups[1][1].id)
	end)

	it("groups direct replies under the root", function()
		local groups = bb._build_threads({
			{ id = 1, parent = vim.NIL, created_on = "t0" },
			{ id = 2, parent = { id = 1 }, created_on = "t1" },
			{ id = 3, parent = { id = 1 }, created_on = "t2" },
		})
		assert.equals(3, #groups[1])
	end)

	it("follows nested replies (reply of reply) up to the root", function()
		local groups = bb._build_threads({
			{ id = 1, parent = vim.NIL, created_on = "t0" },
			{ id = 2, parent = { id = 1 }, created_on = "t1" },
			{ id = 3, parent = { id = 2 }, created_on = "t2" },
		})
		assert.equals(3, #groups[1])
		assert.is_nil(groups[2])
		assert.is_nil(groups[3])
	end)

	it("orphan reply (parent not in batch) becomes its own root", function()
		local groups = bb._build_threads({
			{ id = 5, parent = { id = 9999 }, created_on = "t0" },
		})
		assert.equals(1, #groups[5])
	end)

	it("sorts each group by created_on", function()
		local groups = bb._build_threads({
			{ id = 1, parent = vim.NIL, created_on = "t2" },
			{ id = 2, parent = { id = 1 }, created_on = "t1" },
			{ id = 3, parent = { id = 1 }, created_on = "t3" },
		})
		assert.equals("t1", groups[1][1].created_on)
		assert.equals("t2", groups[1][2].created_on)
		assert.equals("t3", groups[1][3].created_on)
	end)

	it("treats parent = vim.NIL the same as nil", function()
		local groups = bb._build_threads({
			{ id = 1, parent = vim.NIL, created_on = "t0" },
			{ id = 2, parent = nil, created_on = "t1" },
		})
		assert.is_not_nil(groups[1])
		assert.is_not_nil(groups[2])
	end)
end)

describe("bitbucket._url_encode", function()
	it("encodes special chars", function()
		assert.equals("a%20b", bb._url_encode("a b"))
		assert.equals("a%22b", bb._url_encode('a"b'))
		assert.equals("a%2Fb", bb._url_encode("a/b"))
	end)

	it("preserves unreserved chars", function()
		assert.equals("Foo-Bar_baz.123~", bb._url_encode("Foo-Bar_baz.123~"))
	end)
end)

describe("bitbucket._parse_remote_url", function()
	it("parses SSH form with .git", function()
		local ws, repo = bb._parse_remote_url("git@bitbucket.org:workspace/repo.git")
		assert.equals("workspace", ws)
		assert.equals("repo", repo)
	end)

	it("parses HTTPS form with username", function()
		local ws, repo = bb._parse_remote_url("https://user@bitbucket.org/workspace/repo.git")
		assert.equals("workspace", ws)
		assert.equals("repo", repo)
	end)

	it("parses HTTPS form without username or .git", function()
		local ws, repo = bb._parse_remote_url("https://bitbucket.org/workspace/repo")
		assert.equals("workspace", ws)
		assert.equals("repo", repo)
	end)

	it("returns nils on unrecognised URLs", function()
		local ws, repo = bb._parse_remote_url("not-a-url")
		assert.is_nil(ws)
		assert.is_nil(repo)
	end)
end)
