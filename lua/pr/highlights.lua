local M = {}

--- Apply every PR-owned highlight definition. Idempotent.
--- Called once at setup and again from a ColorScheme autocmd.
function M.apply()
	local hl = vim.api.nvim_set_hl
	local config = require("pr.config")
	local opts = config.opts
	local colors = opts.colors
	local highlights = opts.highlights

	hl(0, highlights.sign_hl, { fg = colors.sign_fg, default = true })
	hl(0, "PRDiffAdd", { bg = colors.diff_add_bg, default = true })
	hl(0, "PRDiffChange", { bg = colors.diff_change_bg, default = true })
	hl(0, "PRDiffDelete", { bg = colors.diff_delete_bg, default = true })
	hl(0, highlights.sign_comment, { fg = colors.sign_comment_fg, italic = true, default = true })
	hl(0, highlights.hl_comment, { bg = colors.hl_comment_bg, default = true })
	hl(0, highlights.unresolved_text, { bg = colors.unresolved_bg, italic = true, default = true })
	hl(0, highlights.resolved_text, { bg = colors.resolved_bg, italic = true, default = true })
	hl(0, highlights.hl_emoji, { bg = colors.emoji_bg, fg = colors.emoji_fg, default = true })
	hl(0, highlights.popup_hl, { fg = colors.popup_fg, default = true })
	hl(0, highlights.comment_sep, { underline = true, fg = colors.separator_fg, default = true })
	hl(0, "PRCommentEditDim", { fg = colors.edit_dim_fg, default = true })
	hl(0, "PRCommentOutdated", { fg = colors.outdated_fg, default = true })
end

return M
