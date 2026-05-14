describe("provider thread_url", function()
	before_each(function()
		package.loaded["pr.providers.github"] = nil
		package.loaded["pr.providers.gitlab"] = nil
		package.loaded["pr.providers.bitbucket"] = nil
	end)

	it("github builds the discussion permalink", function()
		local github = require("pr.providers.github")
		github.repo_info = { owner = "btj93", repo = "pr.nvim" }
		github.pr_number = 1234
		local url = github.thread_url({ id = "T_abc" }, { database_id = 9876 })
		assert.equals("https://github.com/btj93/pr.nvim/pull/1234#discussion_r9876", url)
	end)

	it("github returns nil when repo info is missing", function()
		local github = require("pr.providers.github")
		github.repo_info = {}
		github.pr_number = 0
		assert.is_nil(github.thread_url({}, { database_id = 1 }))
	end)

	it("gitlab builds the note permalink", function()
		local gitlab = require("pr.providers.gitlab")
		gitlab.repo_info = { owner = "group", repo = "proj" }
		gitlab.pr_number = 42
		local url = gitlab.thread_url({}, { database_id = 99 })
		assert.equals("https://gitlab.com/group/proj/-/merge_requests/42#note_99", url)
	end)

	it("bitbucket builds the comment permalink", function()
		local bitbucket = require("pr.providers.bitbucket")
		bitbucket.repo_info = { owner = "ws", repo = "repo" }
		bitbucket.pr_number = 7
		local url = bitbucket.thread_url({}, { database_id = 33 })
		assert.equals("https://bitbucket.org/ws/repo/pull-requests/7#comment-33", url)
	end)
end)
