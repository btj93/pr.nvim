local M = {}

M.opts = {
	provider = "github", -- github, gitlab, bitbucket
	picker = "snacks", -- telescope, fzf, snacks
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
	--- Show outdated comment threads inline (signcolumn glyphs + diagnostic
	--- entry below the line). `false` (default) skips them entirely because
	--- GitHub reports their line numbers against the commit when the comment
	--- was made, so they'd be decorated at locations that may have moved or
	--- no longer exist in the current buffer. Outdated threads are still
	--- surfaced via the popup (which marks them) and via picker filters.
	---
	--- This is the unified knob: if `diagnostics.include_outdated` is nil it
	--- falls back to this value; an explicit boolean there still wins.
	show_outdated_inline = false,
	--- Show resolved threads inline (signcolumn glyphs + diagnostic entry).
	--- Defaults to `false` to reduce visual clutter — resolved threads remain
	--- accessible through the popup and picker filters. Set to `true` to keep
	--- them visible in the buffer; when shown they're published at INFO
	--- severity (see `diagnostics.severity_resolved`) so your diagnostic
	--- config can style them distinctly from unresolved threads.
	---
	--- This is the unified knob: if `diagnostics.include_resolved` is nil it
	--- falls back to this value; an explicit boolean there still wins.
	show_resolved_inline = false,
	diagnostics = {
		enabled = true,
		severity = vim.diagnostic.severity.HINT,
		--- Severity for resolved threads (only published when `show_resolved_inline`
		--- is true). Lets diagnostic-UI tools (lsp_lines, Trouble, etc.) color
		--- resolved threads distinctly from unresolved ones via severity-based
		--- highlight groups.
		severity_resolved = vim.diagnostic.severity.INFO,
		--- nil = follow `show_resolved_inline` / `show_outdated_inline`. Explicit
		--- `true`/`false` still overrides for advanced setups.
		include_resolved = nil,
		include_outdated = nil,
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
	drafts = {
		enabled = true,
		-- nil = use the default path (stdpath('data') .. "/pr.nvim/drafts.json")
		path = nil,
	},
	conflict_detection = {
		-- Re-fetch the comment's freshest state before each in-place edit commit
		-- and prompt the user when it changed remotely. Set to false to skip the
		-- refetch entirely (faster commits; risk of silent overwrite).
		enabled = true,
	},
	winbar = {
		-- Set true to enable the built-in winbar showing the PR number and a
		-- per-file unresolved count on buffers under the git root. Off by default
		-- because most users drive winbar with their own plugin (heirline / lualine).
		enabled = false,
		-- Format string. First %d = pr_number; second %d = unresolved count on the buffer.
		format = "[PR #%d · %d unresolved]",
	},
	completion = {
		-- Omnifunc-backed completion for @user and #issue inside comment popups.
		-- Trigger with <C-x><C-o> in insert mode after typing `@` or `#`.
		enabled = true,
	},
}

function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

return M
