describe("status", function()
	local status
	local github

	before_each(function()
		package.loaded["pr.status"] = nil
		package.loaded["pr.providers.github"] = nil
		package.loaded["pr.config"] = nil
		status = require("pr.status")
		github = require("pr.providers.github")
		require("pr.config").setup({ provider = "github" })
		-- Wipe any leftover named buffers from previous tests so nvim_buf_set_name
		-- doesn't collide on names like "/root/a.lua".
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			local n = vim.api.nvim_buf_get_name(b)
			if n:sub(1, #"/root/") == "/root/" then
				vim.api.nvim_buf_delete(b, { force = true })
			end
		end
		-- Seed provider state.
		github.pr_number = 1234
		github.git_root = "/root"
		github.comments = {
			["a.lua"] = {
				{ is_resolved = false, is_outdated = false, comments = { { start_line = 1, end_line = 1 } } },
				{ is_resolved = true, is_outdated = false, comments = { { start_line = 2, end_line = 2 } } },
				{ is_resolved = false, is_outdated = true, comments = { { start_line = 3, end_line = 3 } } },
			},
		}
	end)

	describe("compute", function()
		it("returns counters for the cached comments", function()
			local s = status.compute()
			assert.equals(1234, s.pr_number)
			assert.equals(3, s.total)
			assert.equals(2, s.unresolved)
			assert.equals(1, s.resolved)
			assert.equals(1, s.outdated)
			assert.equals(0, s.pending_review)
		end)

		it("returns nil pr_number when none set", function()
			github.pr_number = 0
			assert.is_nil(status.compute().pr_number)
		end)

		it("handles empty comments map", function()
			github.comments = {}
			local s = status.compute()
			assert.equals(0, s.total)
			assert.equals(0, s.unresolved)
			assert.equals(0, s.resolved)
			assert.equals(0, s.outdated)
		end)

		it("counts pending_review from review_local for the current PR", function()
			github.repo_info = { owner = "btj93", repo = "pr.nvim" }
			-- Point review_local at a temp file so we don't poison real data.
			local local_review = require("pr.review_local")
			local_review._set_path(vim.fn.tempname())
			local_review.save("github", "btj93", "pr.nvim", 1234, { id = 1, path = "a.lua", end_line = 1, body = "x" })
			local_review.save("github", "btj93", "pr.nvim", 1234, { id = 2, path = "b.lua", end_line = 2, body = "y" })
			assert.equals(2, status.compute().pending_review)
		end)
	end)

	describe("compute_for_buffer", function()
		it("returns 0 when buffer is outside git_root", function()
			-- Create a scratch buffer with no file path.
			local buf = vim.api.nvim_create_buf(false, true)
			assert.equals(0, status.compute_for_buffer(buf))
		end)

		it("returns 0 when no comments map to that path", function()
			-- Buffer name set to a file under git_root that has no comments.
			local buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_name(buf, "/root/no-comments.lua")
			assert.equals(0, status.compute_for_buffer(buf))
		end)

		it("counts only unresolved threads for the buffer's relative path", function()
			local buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_name(buf, "/root/a.lua")
			-- 2 unresolved, 1 resolved → 2.
			assert.equals(2, status.compute_for_buffer(buf))
		end)
	end)

	describe("winbar", function()
		it("returns empty string when winbar.enabled is false", function()
			assert.equals("", status.winbar())
		end)

		it("returns formatted string when enabled", function()
			require("pr.config").setup({ provider = "github", winbar = { enabled = true, format = "[PR #%d · %d unresolved]" } })
			local buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_name(buf, "/root/a.lua")
			local s = status.winbar(buf)
			assert.matches("#1234", s)
			assert.matches("2 unresolved", s)
		end)

		it("returns empty string when pr_number is missing", function()
			require("pr.config").setup({ provider = "github", winbar = { enabled = true } })
			github.pr_number = 0
			assert.equals("", status.winbar())
		end)
	end)
end)
