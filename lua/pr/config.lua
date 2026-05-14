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
	colors = {
		diff_add_bg = "#40531b",
		diff_change_bg = "#2a3a57",
		diff_delete_bg = "#893f45",
		sign_fg = "LightBlue",
		hl_comment_bg = "LightBlue",
		unresolved_bg = "#997570",
		resolved_bg = "#82A67D",
		emoji_bg = "#4493f8",
		emoji_fg = "white",
		popup_fg = "Yellow",
		separator_fg = "Grey",
		edit_dim_fg = "#5c6370",
		outdated_fg = "#5c6370",
		sign_comment_fg = "Grey",
	},
	run_on_start = {
		comments = true,
		hunks = false,
	},
	--- Show outdated comment threads inline (signs + virtual text/lines).
	--- `false` (default) skips them entirely because GitHub reports their line
	--- numbers against the commit when the comment was made, so they'd be
	--- decorated at locations that may have moved or no longer exist in the
	--- current buffer. Outdated threads are still surfaced via the popup
	--- (which marks them) and via picker filters.
	show_outdated_inline = false,
	--- Show resolved threads inline (signs + virtual text/lines).
	--- Defaults to true because users typically want the visual distinction
	--- (background colored differently) for resolved threads. Set to false to
	--- suppress all inline rendering of resolved threads; they remain accessible
	--- through the popup and the picker filters.
	show_resolved_inline = true,
	diagnostics = {
		enabled = true,
		severity = vim.diagnostic.severity.HINT,
		include_resolved = false,
		include_outdated = false,
		source = "PR",
	},
	auto_refresh = {
		on_branch_change = true,
		on_head_change = true,
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
