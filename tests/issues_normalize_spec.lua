describe("github._normalize_issues", function()
	local github
	before_each(function()
		package.loaded["pr.providers.github"] = nil
		github = require("pr.providers.github")
	end)

	it("returns issue records with number, title, state", function()
		local out = github._normalize_issues({
			{ number = 42, title = "bug", state = "OPEN" },
			{ number = 17, title = "feat", state = "CLOSED" },
		})
		assert.equals(2, #out)
		assert.equals(42, out[1].number)
		assert.equals("bug", out[1].title)
		assert.equals("open", out[1].state)
		assert.equals("closed", out[2].state)
	end)

	it("handles missing / nil input", function()
		assert.equals(0, #github._normalize_issues(nil))
		assert.equals(0, #github._normalize_issues({}))
	end)

	it("skips entries without a number", function()
		local out = github._normalize_issues({
			{ number = 1, title = "a", state = "OPEN" },
			{ title = "no-number", state = "OPEN" },
		})
		assert.equals(1, #out)
	end)
end)
