describe("github._normalize_pr_metadata", function()
	local github
	before_each(function()
		package.loaded["pr.providers.github"] = nil
		github = require("pr.providers.github")
	end)

	it("normalizes title, body, state, refs", function()
		local raw = {
			number = 1234,
			title = "feat: drift",
			body = "## Summary\n…",
			state = "OPEN",
			isDraft = false,
			author = { login = "alice" },
			headRefName = "drift",
			baseRefName = "main",
			labels = { { name = "enhancement" } },
			reviewRequests = { { login = "bob" } },
			latestReviews = { { author = { login = "carol" }, state = "APPROVED" } },
			assignees = {},
			url = "https://github.com/x/y/pull/1234",
			updatedAt = "2026-05-14T00:00:00Z",
		}
		local m = github._normalize_pr_metadata(raw)
		assert.equals(1234, m.number)
		assert.equals("open", m.state)
		assert.equals("drift", m.head_ref)
		assert.equals("main", m.base_ref)
		assert.equals(1, #m.labels)
		assert.equals("enhancement", m.labels[1])
		assert.equals(2, #m.reviewers)
		local found_approved = false
		for _, r in ipairs(m.reviewers) do
			if r.user == "carol" and r.state == "approved" then
				found_approved = true
			end
		end
		assert.is_true(found_approved)
	end)

	it("treats isDraft = true as state = draft", function()
		local raw = {
			number = 1,
			title = "x",
			body = "",
			state = "OPEN",
			isDraft = true,
			author = { login = "bob" },
			headRefName = "x",
			baseRefName = "main",
			labels = {},
			reviewRequests = {},
			latestReviews = {},
			assignees = {},
			url = "u",
			updatedAt = "t",
		}
		local m = github._normalize_pr_metadata(raw)
		assert.equals("draft", m.state)
	end)

	it("treats closed/merged states correctly", function()
		for _, pair in ipairs({ { "CLOSED", "closed" }, { "MERGED", "merged" } }) do
			local raw = {
				number = 1,
				title = "x",
				body = "",
				state = pair[1],
				isDraft = false,
				author = { login = "a" },
				headRefName = "x",
				baseRefName = "main",
				labels = {},
				reviewRequests = {},
				latestReviews = {},
				assignees = {},
				url = "u",
				updatedAt = "t",
			}
			assert.equals(pair[2], github._normalize_pr_metadata(raw).state)
		end
	end)

	it("handles empty optional fields", function()
		local raw = {
			number = 1,
			title = "x",
			body = "",
			state = "OPEN",
			isDraft = false,
			author = { login = "a" },
			headRefName = "x",
			baseRefName = "main",
			labels = {},
			reviewRequests = {},
			latestReviews = {},
			assignees = {},
			url = "u",
			updatedAt = "t",
		}
		local m = github._normalize_pr_metadata(raw)
		assert.equals(0, #m.labels)
		assert.equals(0, #m.reviewers)
		assert.equals(0, #m.assignees)
	end)
end)
