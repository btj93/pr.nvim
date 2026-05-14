local M = {}

local git = require("pr.provider").get_provider()

local function open_edit(metadata)
	local ui = require("pr.ui")
	local snapshot = metadata.updated_at
	local layout = ui.make_pr_edit_layout(metadata, {
		on_submit = function(fields)
			-- Conflict-aware: re-fetch latest metadata and compare updated_at.
			if type(git.clear_pr_metadata) == "function" then
				git.clear_pr_metadata()
			end
			git.get_pr_metadata(vim.schedule_wrap(function(fresh)
				if fresh and fresh.updated_at and fresh.updated_at ~= snapshot then
					local choice = vim.fn.confirm("PR title/body changed remotely since edit started.", "&Overwrite\n&Refresh\n&Abort", 3)
					if choice == 2 then
						-- Refresh: re-open the read popup so the user sees the current state.
						M.show()
						return
					elseif choice ~= 1 then
						return
					end
				end
				if type(git.update_pr_metadata) ~= "function" then
					vim.notify("update_pr_metadata not available for this provider")
					return
				end
				git.update_pr_metadata(
					fields,
					vim.schedule_wrap(function(ok, err)
						if ok then
							vim.notify("PR updated")
						else
							vim.notify("Update failed: " .. (err or "unknown"), vim.log.levels.ERROR)
						end
					end)
				)
			end))
		end,
	})
	layout:mount()
end

---Open the PR info popup. `mode = "edit"` jumps directly into edit mode.
---@param mode "view"|"edit"|nil
function M.show(mode)
	if type(git.get_pr_metadata) ~= "function" then
		vim.notify("get_pr_metadata not available for this provider")
		return
	end
	git.get_pr_metadata(vim.schedule_wrap(function(metadata)
		if not metadata then
			vim.notify("No PR for the current branch")
			return
		end
		if mode == "edit" then
			open_edit(metadata)
			return
		end
		local fetch_checks
		if type(git.get_checks) == "function" then
			fetch_checks = git.get_checks
		else
			fetch_checks = function(cb)
				cb({})
			end
		end
		fetch_checks(vim.schedule_wrap(function(checks)
			local ui = require("pr.ui")
			local layout
			layout = ui.make_pr_info_layout(metadata, checks, {
				on_edit = function()
					layout:unmount()
					open_edit(metadata)
				end,
				on_refresh = function()
					if type(git.clear_pr_metadata) == "function" then
						git.clear_pr_metadata()
					end
					if type(git.clear_checks) == "function" then
						git.clear_checks()
					end
					layout:unmount()
					M.show()
				end,
				on_check_menu = function()
					local menu = ui.make_checks_menu(checks, function(url)
						vim.fn.setreg("+", url)
						vim.fn.setreg('"', url)
						vim.notify("Yanked " .. url)
					end)
					menu:mount()
				end,
			})
			layout:mount()
		end))
	end))
end

return M
