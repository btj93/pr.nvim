local M = {}

local git = require("pr.provider").get_provider()

--- Checkout a PR by number. Asynchronous; refreshes pr.nvim state after the
--- branch switch lands (via the existing branch-change autorefresh in init.lua).
---@param pr_number integer
function M.checkout(pr_number)
	if type(git.checkout_pr) ~= "function" then
		vim.notify("checkout_pr not available for this provider")
		return
	end
	git.checkout_pr(
		pr_number,
		vim.schedule_wrap(function(success, err)
			if not success then
				-- checkout_pr already notified via vim.log.levels.ERROR on its
				-- own; nothing else to do here. err is captured for callers that
				-- pass a callback through.
				local _ = err
				return
			end
			-- Trigger branch-change refresh proactively so the user doesn't
			-- have to wait for FocusGained.
			pcall(function()
				local pr = require("pr")
				if type(pr._check_branch_and_refresh) == "function" then
					pr._check_branch_and_refresh()
				end
			end)
			vim.cmd("checktime")
		end)
	)
end

return M
