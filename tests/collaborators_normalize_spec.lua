describe("github._normalize_collaborators", function()
	local github
	before_each(function()
		package.loaded["pr.providers.github"] = nil
		github = require("pr.providers.github")
	end)

	it("returns user records with login + name", function()
		local out = github._normalize_collaborators({
			{ login = "alice", name = "Alice Smith" },
			{ login = "bob", name = vim.NIL },
		})
		assert.equals(2, #out)
		assert.equals("alice", out[1].login)
		assert.equals("Alice Smith", out[1].name)
		assert.equals("bob", out[2].login)
		assert.is_nil(out[2].name)
	end)

	it("handles empty / nil input", function()
		assert.equals(0, #github._normalize_collaborators(nil))
		assert.equals(0, #github._normalize_collaborators({}))
	end)

	it("skips entries without a login", function()
		local out = github._normalize_collaborators({
			{ login = "alice" },
			{ name = "no-login" },
			{ login = "carol" },
		})
		assert.equals(2, #out)
	end)
end)
