describe("github._normalize_checks", function()
	local github
	before_each(function()
		package.loaded["pr.providers.github"] = nil
		github = require("pr.providers.github")
	end)

	it("treats SUCCESS as completed/success", function()
		local raw = { { name = "test", state = "SUCCESS", startedAt = "2026-05-13T23:59:22Z", completedAt = "2026-05-14T00:00:00Z", link = "https://gh.com/log" } }
		local checks = github._normalize_checks(raw)
		assert.equals(1, #checks)
		assert.equals("test", checks[1].name)
		assert.equals("completed", checks[1].status)
		assert.equals("success", checks[1].conclusion)
		assert.equals("https://gh.com/log", checks[1].url)
	end)

	it("treats IN_PROGRESS as status only", function()
		local raw = { { name = "lint", state = "IN_PROGRESS", startedAt = "t", completedAt = nil, link = "u" } }
		local checks = github._normalize_checks(raw)
		assert.equals("in_progress", checks[1].status)
		assert.is_nil(checks[1].conclusion)
	end)

	it("treats QUEUED as status only", function()
		local raw = { { name = "build", state = "QUEUED", link = "u" } }
		local checks = github._normalize_checks(raw)
		assert.equals("queued", checks[1].status)
		assert.is_nil(checks[1].conclusion)
	end)

	it("treats FAILURE / CANCELLED / SKIPPED / NEUTRAL as completed with conclusion", function()
		for _, state in ipairs({ "FAILURE", "CANCELLED", "SKIPPED", "NEUTRAL" }) do
			local checks = github._normalize_checks({ { name = "x", state = state, link = "u" } })
			assert.equals("completed", checks[1].status)
			assert.equals(string.lower(state), checks[1].conclusion)
		end
	end)

	it("returns empty array for empty/nil input", function()
		assert.equals(0, #github._normalize_checks(nil))
		assert.equals(0, #github._normalize_checks({}))
	end)
end)
