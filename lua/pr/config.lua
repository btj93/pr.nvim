local M = {}

M.opts = {
	provider = "github", -- github, gitlab, bitbucket
	picker = "snacks", -- telescope, fzf, snacks
	virtual_text = false,
	virtual_line = true,
	sign = "󰅺",
	multi_line_sign = {
		start_line = "┌",
		connector = "│",
		end_line = "└",
	},
	debug = false,
	highlights = {
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
	},
	run_on_start = {
		comments = true,
		hunks = false,
	},
	auto_refresh = {
		on_branch_change = true,
		--- Seconds between automatic refreshes. 0 or nil disables the periodic timer.
		--- Refresh only fires when at least one feature (comments or hunks) is enabled.
		--- Defaults to 5 minutes — a balance between fresh data and not hammering the
		--- gh API. Set to 0 to disable, or pick something tighter while actively reviewing.
		interval = 300,
	},
}

function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

return M
