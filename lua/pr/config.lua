local M = {}

M.opts = {
	provider = "github",
	picker = "snacks",
	virtual_text = true,
	virtual_line = true,
	sign = "󰅺",
	multi_line_sign = {
		start_line = "┌",
		connector = "│",
		end_line = "└",
	},
	debug = false,
	sign_hl = "DiffComment",
	hl_comment = "PRCommentHL",
	unresolved_text = "PRUnresolved",
	resolved_text = "PRResolved",
	sign_group = "PRDiffSigns",
	sign_comment = "PRComment",
	sign_comment_multi_line_start = "PRCommentMultiLineStart",
	sign_comment_multi_line_connector = "PRCommentMultiLineConnector",
	sign_comment_multi_line_end = "PRCommentMultiLineEnd",
	diff_ns_id = vim.api.nvim_create_namespace("PRDiffHighlights"),
	comments_ns_id = vim.api.nvim_create_namespace("PRComments"),
	hl_group = "PRDiffHighlights",
	popup_hl = "PRCommentPopup",
	hl_emoji = "PREmojiLine",
	comment_sep = "PRCommentSeparator",
}

function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

return M
