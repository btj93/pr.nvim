local M = {}

local git = require("pr.provider").get_provider()
local config = require("pr.config")
local ui = require("pr.ui")
local util = require("pr.util")

M.bufs = {}
M.wins = {}
M.enabled = false

---
---@param buf integer?
function M.draw(buf)
	-- vim.notify("draw")
	buf = buf or vim.api.nvim_get_current_buf()
	if M.bufs[buf] then
		return
	end

	M.bufs[buf] = true

	local buffer_path = vim.api.nvim_buf_get_name(buf)
	if buffer_path == "" then
		return
	end

	local comments_placed = 0
	git.get_git_root(vim.schedule_wrap(function(git_root)
		if git_root == nil or git_root == "" then
			vim.api.nvim_echo({ { "Not a git repository.", "WarningMsg" } }, true, {})
			return
		end

		local start_line = 0
		local end_line = 0
		local c = {}

		local relative_path = buffer_path:sub(#git_root + 2)
		local comments = git.comments[relative_path] or {}
		if next(comments) == nil then
			if config.opts.debug then
				vim.api.nvim_echo({ { "No inline PR comments found for this file.", "WarningMsg" } }, true, {})
			end
			return
		end
		for _, thread in ipairs(comments) do
			local _, first_comment = next(thread.comments)
			if first_comment then
				start_line = first_comment.start_line
				end_line = first_comment.end_line
				local text = "      "
					.. first_comment.author
					.. ": "
					.. first_comment.body:gsub("\r\n", " "):gsub("\n", " ")
				local hl = "DiagnosticVirtualLinesWarn"
				if thread.is_resolved then
					hl = "DiagnosticVirtualLinesOk"
				end
				table.insert(c, { text, hl })
			end
		end

		if start_line == end_line then
			vim.fn.sign_place(
				0,
				config.opts.highlights.sign_group,
				config.opts.highlights.sign_comment,
				buf,
				{ lnum = end_line }
			)
		else
			vim.fn.sign_place(
				0,
				config.opts.highlights.sign_group,
				config.opts.highlights.sign_comment_multi_line_start,
				buf,
				{ lnum = start_line }
			)
			for i = start_line + 1, end_line - 1 do
				vim.fn.sign_place(
					0,
					config.opts.highlights.sign_group,
					config.opts.highlights.sign_comment_multi_line_connector,
					buf,
					{ lnum = i }
				)
			end
			vim.fn.sign_place(
				0,
				config.opts.highlights.sign_group,
				config.opts.highlights.sign_comment_multi_line_end,
				buf,
				{ lnum = end_line }
			)
		end

		if config.opts.virtual_text then
			vim.api.nvim_buf_set_extmark(buf, config.opts.highlights.comments_ns_id, end_line - 1, -1, {
				virt_text = c,
				virt_text_pos = "eol",
			})
		end

		if config.opts.virtual_line then
			vim.api.nvim_buf_set_extmark(buf, config.opts.highlights.comments_ns_id, end_line - 1, -1, {
				virt_lines = { c },
			})
		end

		comments_placed = comments_placed + 1

		if config.opts.debug then
			if comments_placed > 0 then
				vim.api.nvim_echo({ { comments_placed .. " PR comment threads shown.", "InfoMsg" } }, true, {})
			else
				vim.api.nvim_echo({ { "No inline PR comments found for this file.", "WarningMsg" } }, true, {})
			end
		end
	end))
end

---
---@param direction "forward"|"backward"
---@param relative_path string?
---@param line integer?
function M.cycle_comments_in_buffer(direction, relative_path, line)
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

		git.get_comments(vim.schedule_wrap(function(comments)
			comments = comments[relative_path] or {}

			if #comments == 0 then
				vim.notify("No comments found in this file.")
				return
			end

			local before_line = nil
			local after_line = nil
			local before_index = nil
			local after_index = nil
			for i, thread in ipairs(comments) do
				local _, first_comment = next(thread.comments)
				if first_comment then
					if first_comment.start_line < line then
						before_line = first_comment.start_line
						before_index = i
					else
						after_line = first_comment.start_line
						after_index = i
					end
				end
			end

			if direction == "forward" then
				vim.api.nvim_win_set_cursor(0, { after_line or before_line, 0 })
				vim.notify("Comment " .. (after_index or before_index) .. " of " .. #comments)
			elseif direction == "backward" then
				vim.api.nvim_win_set_cursor(0, { before_line or after_line, 0 })
				vim.notify("Comment " .. (before_index or after_index) .. " of " .. #comments)
			end
		end))
	end))
end

---
---@param relative_path? string
---@param start_line? integer
---@param end_line? integer
function M.comment(relative_path, start_line, end_line)
	-- TODO: permission check
	git.get_git_root(vim.schedule_wrap(function(git_root)
		if git_root == nil or git_root == "" then
			vim.api.nvim_echo({ { "Not a git repository.", "WarningMsg" } }, true, {})
			return
		end

		local buf = vim.api.nvim_get_current_buf()
		local buffer_path = vim.api.nvim_buf_get_name(buf)
		local ft = vim.bo.filetype
		if buffer_path == "" then
			return
		end
		relative_path = relative_path or buffer_path:sub(#git_root + 2)

		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "x", true)
		start_line = vim.fn.line("'<")
		end_line = vim.fn.line("'>")

		local lines = vim.api.nvim_buf_get_text(buf, start_line - 1, 0, end_line + 1, -1, {})
		local layout = ui.make_new_comment_layout(lines, ft, relative_path, start_line, end_line)
		layout:mount()

		vim.cmd("startinsert")
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
        autocmd BufWinEnter,WinNew * lua require("pr").attach_comment()
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
	if config.opts.run_on_start.comments then
		M.start()
	end
end

return M
