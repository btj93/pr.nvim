describe("ui._render_pr_info", function()
	local ui
	before_each(function()
		package.loaded["pr.ui"] = nil
		ui = require("pr.ui")
	end)

	it("includes title, author, refs, body, labels, reviewers, assignees, checks footer", function()
		local metadata = {
			number = 1234,
			title = "feat: drift",
			state = "open",
			author = "alice",
			head_ref = "drift",
			base_ref = "main",
			body = "## Summary\nAdds drift",
			labels = { "enhancement" },
			reviewers = { { user = "bob", state = "approved" } },
			assignees = {},
			url = "u",
			updated_at = "t",
		}
		local checks = {
			{ name = "test", status = "completed", conclusion = "success", url = "u1" },
			{ name = "lint", status = "in_progress", conclusion = nil, url = "u2" },
		}
		local lines = ui._render_pr_info(metadata, checks)
		assert.is_true(#lines > 5)
		local body = table.concat(lines, "\n")
		assert.matches("PR #1234", body)
		assert.matches("feat: drift", body)
		assert.matches("@alice", body)
		assert.matches("main ← drift", body)
		assert.matches("Adds drift", body)
		assert.matches("enhancement", body)
		assert.matches("@bob", body)
		assert.matches("test", body)
		assert.matches("lint", body)
	end)

	it("renders dashes when labels / reviewers / assignees are empty", function()
		local metadata = {
			number = 1,
			title = "x",
			state = "open",
			author = "a",
			head_ref = "h",
			base_ref = "b",
			body = "",
			labels = {},
			reviewers = {},
			assignees = {},
			url = "u",
			updated_at = "t",
		}
		local lines = ui._render_pr_info(metadata, nil)
		local body = table.concat(lines, "\n")
		assert.matches("labels:%s+—", body)
		assert.matches("reviewers:%s+—", body)
		assert.matches("assignees:%s+—", body)
	end)

	it("omits the checks line when checks is nil or empty", function()
		local metadata = {
			number = 1,
			title = "x",
			state = "open",
			author = "a",
			head_ref = "h",
			base_ref = "b",
			body = "",
			labels = {},
			reviewers = {},
			assignees = {},
			url = "u",
			updated_at = "t",
		}
		local lines_no = ui._render_pr_info(metadata, nil)
		local lines_empty = ui._render_pr_info(metadata, {})
		assert.is_nil(table.concat(lines_no, "\n"):match("checks:"))
		assert.is_nil(table.concat(lines_empty, "\n"):match("checks:"))
	end)
end)
