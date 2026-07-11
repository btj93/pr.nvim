local M = {}

local git = require("pr.provider").get_provider()

--- Pure conflict-resolution decision for the PR-info edit path. Mirrors
--- `ui._conflict_decision`'s contract exactly so both edit flows agree on how a
--- remote change interacts with the user's confirm choice.
---@param fresh { updated_at: string }?
---@param snapshot_updated_at string?
---@param confirm_choice integer  -- as returned by vim.fn.confirm
---@return "proceed"|"overwrite"|"refresh"|"abort"
function M._conflict_decision(fresh, snapshot_updated_at, confirm_choice)
	if not fresh then
		return "proceed"
	end
	if fresh.updated_at == snapshot_updated_at then
		return "proceed"
	end
	if confirm_choice == 1 then
		return "overwrite"
	end
	if confirm_choice == 2 then
		return "refresh"
	end
	return "abort"
end

local function open_edit(metadata)
	local ui = require("pr.ui")
	local snapshot = metadata.updated_at
	local layout = ui.make_pr_edit_layout(metadata, {
		on_submit = function(fields)
			-- Defense-in-depth: the ui layer already rejects empty title/body,
			-- but guard here too so a misbehaving caller can't push an empty
			-- payload through `gh pr edit` (which silently no-ops on `--body ""`).
			if not fields or vim.trim(fields.title or "") == "" or vim.trim(fields.body or "") == "" then
				vim.notify("PR title and body must not be empty", vim.log.levels.ERROR)
				return
			end
			-- Conflict-aware: re-fetch latest metadata and compare updated_at.
			if type(git.clear_pr_metadata) == "function" then
				git.clear_pr_metadata()
			end
			git.get_pr_metadata(vim.schedule_wrap(function(fresh)
				-- Prompt only on an actual mismatch; `_conflict_decision` is the
				-- single source of truth for what that choice (or its absence) means.
				local choice = 0
				if fresh and fresh.updated_at ~= snapshot then
					choice = vim.fn.confirm("PR title/body changed remotely since edit started.", "&Overwrite\n&Refresh\n&Abort", 3)
				end
				local decision = M._conflict_decision(fresh, snapshot, choice)
				if decision == "refresh" then
					-- Refresh: re-open the read popup so the user sees the current state.
					M.show()
					return
				elseif decision == "abort" then
					return
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
