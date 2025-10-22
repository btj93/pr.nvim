local provider = require("pr.provider")
local config = require("pr.config")
local gh = provider.get_provider(config.opts)
local ui = require("pr.ui")

local M = {}

M.enabled = false
M.bufs = {}
M.wins = {}

-- Namespaces and Groups
local diff_ns_id = config.opts.diff_ns_id

-- Function to clear all the diff highlights for the current buffer
local function clear_highlights()
	vim.api.nvim_buf_clear_namespace(0, diff_ns_id, 0, -1)
	vim.api.nvim_echo({ { "PR diff highlights removed.", "InfoMsg" } }, true, {})
end

-- Function to get the diff and place the highlights
local function place_highlights()
	local buffer_path = vim.api.nvim_buf_get_name(0)
	if buffer_path == "" then
		vim.api.nvim_echo({ { "Cannot get diff for an unnamed buffer.", "WarningMsg" } }, true, {})
		return
	end

	gh.get_git_root(vim.schedule_wrap(function(git_root)
		if git_root == nil or git_root == "" then
			vim.api.nvim_echo({ { "Not a git repository.", "WarningMsg" } }, true, {})
			return
		end

		local relative_path = buffer_path:sub(#git_root + 2)
		gh.get_hunks(vim.schedule_wrap(function(hunks)
			hunks = hunks[relative_path] or {}
			for _, hunk in ipairs(hunks) do
				vim.notify(vim.inspect(hunk))

				-- 0 indexed
				vim.api.nvim_buf_set_extmark(0, diff_ns_id, hunk.hunk_start - 1, 0, {
					line_hl_group = "PRDiff" .. hunk.type,
					end_row = hunk.hunk_end - 1,
					end_col = 0,
				})
			end
		end))
	end))
end

-- The main toggle function called by the user command
function M.toggle_diff()
	if highlights_active then
		clear_highlights()
		highlights_active = false
	else
		place_highlights()
		highlights_active = true
	end
end

local function clear_comments()
	vim.api.nvim_buf_clear_namespace(0, config.opts.comments_ns_id, 0, -1)
	vim.api.nvim_echo({ { "PR comments hidden.", "InfoMsg" } }, true, {})
end

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
	gh.get_git_root(vim.schedule_wrap(function(git_root)
		if git_root == nil or git_root == "" then
			vim.api.nvim_echo({ { "Not a git repository.", "WarningMsg" } }, true, {})
			return
		end

		local start_line = 0
		local end_line = 0
		local c = {}

		local relative_path = buffer_path:sub(#git_root + 2)
		local comments = gh.comments[relative_path] or {}
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
			vim.fn.sign_place(0, config.opts.sign_group, config.opts.sign_comment, buf, { lnum = end_line })
		else
			vim.fn.sign_place(
				0,
				config.opts.sign_group,
				config.opts.sign_comment_multi_line_start,
				buf,
				{ lnum = start_line }
			)
			for i = start_line + 1, end_line - 1 do
				vim.fn.sign_place(
					0,
					config.opts.sign_group,
					config.opts.sign_comment_multi_line_connector,
					buf,
					{ lnum = i }
				)
			end
			vim.fn.sign_place(
				0,
				config.opts.sign_group,
				config.opts.sign_comment_multi_line_end,
				buf,
				{ lnum = end_line }
			)
		end

		if config.opts.virtual_text then
			vim.api.nvim_buf_set_extmark(buf, config.opts.comments_ns_id, end_line - 1, -1, {
				virt_text = c,
				virt_text_pos = "eol",
			})
		end

		if config.opts.virtual_line then
			vim.api.nvim_buf_set_extmark(buf, config.opts.comments_ns_id, end_line - 1, -1, {
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

-- yoinked from https://github.com/folke/todo-comments.nvim/blob/304a8d204ee787d2544d8bc23cd38d2f929e7cc5/lua/todo-comments/highlight.lua#L279
-- ===========================================================================
---
---@param win integer
---@return boolean?
function M.is_float(win)
	local opts = vim.api.nvim_win_get_config(win)
	return opts and opts.relative and opts.relative ~= ""
end

---
---@param win integer
---@return boolean
function M.is_valid_win(win)
	if not vim.api.nvim_win_is_valid(win) then
		return false
	end
	-- avoid E5108 after pressing q:
	if vim.fn.getcmdwintype() ~= "" then
		return false
	end
	-- dont do anything for floating windows
	if M.is_float(win) then
		return false
	end
	local buf = vim.api.nvim_win_get_buf(win)
	return M.is_valid_buf(buf)
end

---
---@param buf integer
---@return boolean
function M.is_quickfix(buf)
	return vim.api.nvim_get_option_value("buftype", { buf = buf }) == "quickfix"
end

---
---@param buf integer
---@return boolean
function M.is_valid_buf(buf)
	-- Skip special buffers
	local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
	if buftype ~= "" and buftype ~= "quickfix" then
		return false
	end
	-- local filetype = vim.api.nvim_buf_get_option(buf, "filetype")
	-- TODO: config
	-- if vim.tbl_contains({}, filetype) then
	--   return false
	-- end
	return true
end

---
---@param win integer?
function M.attach(win)
	win = win or vim.api.nvim_get_current_win()
	if not M.is_valid_win(win) then
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
				if not M.is_valid_buf(buf) then
					return true
				end

				M.draw(buf)
			end,
			on_detach = function()
				M.bufs[buf] = nil
			end,
		})

		M.draw(buf)

		-- local highlighter = require("vim.treesitter.highlighter")
		-- local hl = highlighter.active[buf]
		-- if hl then
		--   -- also listen to TS changes so we can properly update the buffer based on is_comment
		--   hl.tree:register_cbs({
		--     on_bytes = function(_, _, row)
		--       M.redraw(buf, row, row + 1)
		--     end,
		--     on_changedtree = function(changes)
		--       for _, ch in ipairs(changes or {}) do
		--         M.redraw(buf, ch[1], ch[3] + 1)
		--       end
		--     end,
		--   })
		-- end

		-- M.bufs[buf] = true
		-- M.highlight_win(win)
		M.wins[win] = true
		-- elseif not M.wins[win] then
		-- M.highlight_win(win)
		-- M.wins[win] = true
	end
end
-- ===========================================================================

---
---@param relative_path string?
---@param line integer?
function M.popup(relative_path, line)
	-- TODO: check gh.get_comments is done
	gh.get_git_root(vim.schedule_wrap(function(git_root)
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

		gh.get_comments(vim.schedule_wrap(function(comments)
			comments = comments[relative_path] or {}

			for _, thread in ipairs(comments) do
				local _, first_comment = next(thread.comments)
				if first_comment and first_comment.start_line <= line and first_comment.end_line >= line then
					local layout = ui.make_comments_layout(thread)
					layout:mount()
					break
				end
			end
		end))
	end))
end

---
---@param direction "forward"|"backward"
---@param relative_path string?
---@param line integer?
function M.cycle_comments_in_buffer(direction, relative_path, line)
	gh.get_git_root(vim.schedule_wrap(function(git_root)
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

		gh.get_comments(vim.schedule_wrap(function(comments)
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
---@param direction "forward"|"backward"
---@param relative_path string?
---@param line integer?
function M.cycle_hunks_in_buffer(direction, relative_path, line)
	gh.get_git_root(vim.schedule_wrap(function(git_root)
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
		gh.get_hunks(vim.schedule_wrap(function(hunks)
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

---
---@param relative_path? string
---@param start_line? integer
---@param end_line? integer
function M.comment(relative_path, start_line, end_line)
	-- TODO: permission check
	gh.get_git_root(vim.schedule_wrap(function(git_root)
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
		vim.api.nvim_buf_clear_namespace(buf, diff_ns_id, 0, -1)
		vim.api.nvim_buf_clear_namespace(buf, config.opts.comments_ns_id, 0, -1)
	end
	M.bufs = {}
	gh.clear()
	vim.fn.sign_unplace(config.opts.sign_group)
end

function M.toggle()
	if M.enabled then
		M.stop()
	else
		M.start()
	end
end

function M.start()
	M.enabled = true
	gh.get_git_user(vim.schedule_wrap(function(_)
		gh.get_comments(vim.schedule_wrap(function(_)
			vim.api.nvim_exec2(
				[[augroup PRComment
        autocmd!
        autocmd BufWinEnter,WinNew * lua require("pr").attach()
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
end

-- A single setup function for signs and highlights
function M.setup(opts)
	config.setup(opts)

	-- vim.fn.sign_define(sign_add, { text = "+", texthl = "DiffAdd" })
	-- vim.fn.sign_define(sign_del, { text = "-", texthl = "DiffDelete" })
	vim.fn.sign_define(config.opts.sign_comment, { text = config.opts.sign, texthl = config.opts.sign_hl })
	vim.fn.sign_define(
		config.opts.sign_comment_multi_line_start,
		{ text = config.opts.multi_line_sign.start_line, texthl = config.opts.sign_hl }
	)
	vim.fn.sign_define(
		config.opts.sign_comment_multi_line_connector,
		{ text = config.opts.multi_line_sign.connector, texthl = config.opts.sign_hl }
	)
	vim.fn.sign_define(
		config.opts.sign_comment_multi_line_end,
		{ text = config.opts.multi_line_sign.end_line, texthl = config.opts.sign_hl }
	)
	-- vim.api.nvim_set_hl(0, "DiffAdd", { fg = "Green" })
	-- vim.api.nvim_set_hl(0, "DiffDelete", { fg = "Red" })
	vim.api.nvim_set_hl(0, config.opts.sign_hl, { fg = "LightBlue" })
	vim.api.nvim_set_hl(0, "PRDiffAdd", { bg = "#40531b" })
	vim.api.nvim_set_hl(0, "PRDiffChange", { bg = "#2a3a57" })
	vim.api.nvim_set_hl(0, "PRDiffDelete", { bg = "#893f45" })
	vim.api.nvim_set_hl(0, config.opts.sign_comment, { fg = "Grey", italic = true })
	vim.api.nvim_set_hl(0, config.opts.hl_comment, { bg = "LightBlue" })
	-- reddish grey
	vim.api.nvim_set_hl(0, config.opts.unresolved_text, { bg = "#997570", italic = true })
	-- greenish grey
	vim.api.nvim_set_hl(0, config.opts.resolved_text, { bg = "#82A67D", italic = true })

	M.start()
	ui.setup()
end

-- Run setup when the module is loaded
-- M.setup()

return M
