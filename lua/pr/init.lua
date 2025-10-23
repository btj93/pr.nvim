local provider = require("pr.provider")
local config = require("pr.config")
local git = provider.get_provider()
local ui = require("pr.ui")
local comment = require("pr.comment")
local hunk = require("pr.hunk")

local M = {}

---
---@param relative_path string?
---@param line integer?
function M.popup(relative_path, line)
	-- TODO: check gh.get_comments is done
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

-- A single setup function for signs and highlights
function M.setup(opts)
	config.setup(opts)

	-- vim.fn.sign_define(sign_add, { text = "+", texthl = "DiffAdd" })
	-- vim.fn.sign_define(sign_del, { text = "-", texthl = "DiffDelete" })
	vim.fn.sign_define(
		config.opts.highlights.sign_comment,
		{ text = config.opts.sign, texthl = config.opts.highlights.sign_hl }
	)
	vim.fn.sign_define(
		config.opts.highlights.sign_comment_multi_line_start,
		{ text = config.opts.multi_line_sign.start_line, texthl = config.opts.highlights.sign_hl }
	)
	vim.fn.sign_define(
		config.opts.highlights.sign_comment_multi_line_connector,
		{ text = config.opts.multi_line_sign.connector, texthl = config.opts.highlights.sign_hl }
	)
	vim.fn.sign_define(
		config.opts.highlights.sign_comment_multi_line_end,
		{ text = config.opts.multi_line_sign.end_line, texthl = config.opts.highlights.sign_hl }
	)
	-- vim.api.nvim_set_hl(0, "DiffAdd", { fg = "Green" })
	-- vim.api.nvim_set_hl(0, "DiffDelete", { fg = "Red" })
	vim.api.nvim_set_hl(0, config.opts.highlights.sign_hl, { fg = "LightBlue" })
	vim.api.nvim_set_hl(0, "PRDiffAdd", { bg = "#40531b" })
	vim.api.nvim_set_hl(0, "PRDiffChange", { bg = "#2a3a57" })
	vim.api.nvim_set_hl(0, "PRDiffDelete", { bg = "#893f45" })
	vim.api.nvim_set_hl(0, config.opts.highlights.sign_comment, { fg = "Grey", italic = true })
	vim.api.nvim_set_hl(0, config.opts.highlights.hl_comment, { bg = "LightBlue" })
	-- reddish grey
	vim.api.nvim_set_hl(0, config.opts.highlights.unresolved_text, { bg = "#997570", italic = true })
	-- greenish grey
	vim.api.nvim_set_hl(0, config.opts.highlights.resolved_text, { bg = "#82A67D", italic = true })

	ui.setup()
	comment.setup()
	hunk.setup()
end

-- Run setup when the module is loaded
-- M.setup()

M.cycle_comments_in_buffer = comment.cycle_comments_in_buffer
M.cycle_hunks_in_buffer = hunk.cycle_hunks_in_buffer
M.comment = comment.comment
M.attach_comment = comment.attach
M.attach_hunk = hunk.attach
M.toggle_hunks = hunk.toggle
M.toggle_comments = comment.toggle

return M
