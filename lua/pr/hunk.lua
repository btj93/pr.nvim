local M = {}

local git = require("pr.provider").get_provider()
local config = require("pr.config")
local util = require("pr.util")

M.bufs = {}
M.wins = {}
M.enabled = false

-- Function to get the diff and place the highlights
function M.draw(buf)
	-- vim.notify("place_highlights")
	buf = buf or vim.api.nvim_get_current_buf()
	local buffer_path = vim.api.nvim_buf_get_name(buf)
	if buffer_path == "" then
		vim.api.nvim_echo({ { "Cannot get diff for an unnamed buffer.", "WarningMsg" } }, true, {})
		return
	end

	git.get_git_root(vim.schedule_wrap(function(git_root)
		if git_root == nil or git_root == "" then
			vim.api.nvim_echo({ { "Not a git repository.", "WarningMsg" } }, true, {})
			return
		end

		local relative_path = buffer_path:sub(#git_root + 2)
		git.get_hunks(vim.schedule_wrap(function(hunks)
			hunks = hunks[relative_path] or {}
			for _, hunk in ipairs(hunks) do
				-- vim.notify(vim.inspect(hunk))

				-- 0 indexed
				vim.api.nvim_buf_set_extmark(buf, config.opts.highlights.diff_ns_id, hunk.hunk_start - 1, 0, {
					line_hl_group = "PRDiff" .. hunk.type,
					end_row = hunk.hunk_end - 1,
					end_col = 0,
				})
			end
		end))
	end))
end

---
---@param direction "forward"|"backward"
---@param relative_path string?
---@param line integer?
function M.cycle_hunks_in_buffer(direction, relative_path, line)
	git.get_git_root(vim.schedule_wrap(function(git_root)
		if git_root == nil or git_root == "" then
			vim.api.nvim_echo({ { "Not a git repository.", "WarningMsg" } }, true, {})
			return
		end

		local buf = vim.api.nvim_get_current_buf()
		local buffer_path = vim.api.nvim_buf_get_name(buf)
		if buffer_path == "" then
			return
		end
		relative_path = relative_path or buffer_path:sub(#git_root + 2)
		local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
		line = line or row

		---@param hunks Hunks
		git.get_hunks(vim.schedule_wrap(function(hunks)
			hunks = hunks[relative_path] or {}

			if #hunks == 0 then
				vim.notify("No hunks found in this file.")
				return
			end

			local before_line = nil
			local after_line = nil
			local before_index = nil
			local after_index = nil
			for i, hunk in ipairs(hunks) do
				if hunk.hunk_start < line then
					before_line = hunk.hunk_start
					before_index = i
				else
					after_line = hunk.hunk_start
					after_index = i
				end
			end

			if direction == "forward" then
				vim.api.nvim_win_set_cursor(0, { after_line or before_line, 0 })
				vim.notify("PR Hunk " .. (after_index or before_index) .. " of " .. #hunks)
			elseif direction == "backward" then
				vim.api.nvim_win_set_cursor(0, { before_line or after_line, 0 })
				vim.notify("PR Hunk " .. (before_index or after_index) .. " of " .. #hunks)
			end
		end))
	end))
end

function M.stop()
	M.enabled = false
	M.wins = {}
	for buf, _ in pairs(M.bufs) do
		vim.api.nvim_buf_clear_namespace(buf, config.opts.highlights.diff_ns_id, 0, -1)
		vim.api.nvim_buf_clear_namespace(buf, config.opts.highlights.comments_ns_id, 0, -1)
	end
	M.bufs = {}
	git.clear()
	vim.fn.sign_unplace(config.opts.highlights.sign_group)
end

function M.toggle()
	if M.enabled then
		M.stop()
	else
		M.start()
	end
end

---
---@param win integer?
function M.attach(win)
	win = win or vim.api.nvim_get_current_win()
	if not util.is_valid_win(win) then
		return
	end

	local buf = vim.api.nvim_win_get_buf(win)

	if not M.bufs[buf] then
		-- vim.notify("attach")
		vim.api.nvim_buf_attach(buf, false, {
			on_lines = function()
				if not M.enabled then
					return true
				end
				-- detach from this buffer in case we no longer want it
				if not util.is_valid_buf(buf) then
					return true
				end

				M.draw(buf)
			end,
			on_detach = function()
				M.bufs[buf] = nil
			end,
		})

		M.draw(buf)

		M.wins[win] = true
	end
end

function M.start()
	M.enabled = true
	git.get_git_user(vim.schedule_wrap(function(_)
		git.get_hunks(vim.schedule_wrap(function(_)
			git.get_comments(vim.schedule_wrap(function(_)
				vim.api.nvim_exec2(
					[[augroup PRComment
        autocmd!
        autocmd BufWinEnter,WinNew * lua require("pr").attach_hunk()
      augroup end]],
					{ output = false }
				)

				-- attach to all bufs in visible windows
				for _, win in pairs(vim.api.nvim_list_wins()) do
					if not M.wins[win] then
						M.attach(win)
					end
				end
			end))
		end))
	end))
end

function M.setup()
	if config.opts.run_on_start.hunks then
		M.start()
	end
end

return M
