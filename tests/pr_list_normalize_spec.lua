describe("github._normalize_prs", function()
	local github
	before_each(function()
		package.loaded["pr.providers.github"] = nil
		github = require("pr.providers.github")
		github.git_user = "alice"
	end)

	it("normalizes a single PR", function()
		local raw = {
			{
				number = 1234,
				title = "feat: drift",
				author = { login = "alice" },
				state = "OPEN",
				headRefName = "drift",
				url = "https://github.com/x/y/pull/1234",
				updatedAt = "2026-05-14T00:00:00Z",
				isDraft = false,
				reviewRequests = { { login = "bob" } },
				assignees = {},
			},
		}
		local prs = github._normalize_prs(raw)
		assert.equals(1, #prs)
		assert.equals(1234, prs[1].number)
		assert.equals("open", prs[1].state)
		assert.equals("alice", prs[1].author)
		assert.is_true(prs[1].is_mine)
		assert.equals(1, #prs[1].reviewers)
		assert.equals("bob", prs[1].reviewers[1])
	end)

	it("treats isDraft = true as state = draft", function()
		local raw = {
			{
				number = 1,
				title = "x",
				author = { login = "bob" },
				state = "OPEN",
				headRefName = "x",
				url = "u",
				updatedAt = "t",
				isDraft = true,
				reviewRequests = {},
				assignees = {},
			},
		}
		local prs = github._normalize_prs(raw)
		assert.equals("draft", prs[1].state)
	end)

	it("flags is_review_requested when the current user is in reviewRequests", function()
		local raw = {
			{
				number = 1,
				title = "x",
				author = { login = "bob" },
				state = "OPEN",
				headRefName = "x",
				url = "u",
				updatedAt = "t",
				isDraft = false,
				reviewRequests = { { login = "alice" } },
				assignees = {},
			},
		}
		local prs = github._normalize_prs(raw)
		assert.is_true(prs[1].is_review_requested)
		assert.is_false(prs[1].is_mine)
	end)

	it("flags is_assignee when the current user is in assignees", function()
		local raw = {
			{
				number = 1,
				title = "x",
				author = { login = "bob" },
				state = "OPEN",
				headRefName = "x",
				url = "u",
				updatedAt = "t",
				isDraft = false,
				reviewRequests = {},
				assignees = { { login = "alice" } },
			},
		}
		local prs = github._normalize_prs(raw)
		assert.is_true(prs[1].is_assignee)
	end)

	it("handles empty input", function()
		assert.equals(0, #github._normalize_prs({}))
		assert.equals(0, #github._normalize_prs(nil))
	end)
end)
