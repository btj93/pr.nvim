local M = {}

local PROVIDER_CLIS = {
	github = "gh",
	gitlab = "glab",
	bitbucket = "curl",
}

local SURFACE = {
	"get_repo_info",
	"get_pr_number",
	"get_commit_hash",
	"get_base_sha",
	"get_git_root",
	"get_git_user",
	"get_comments",
	"get_hunks",
	"add_reaction",
	"remove_reaction",
	"reply",
	"comment",
	"edit_comment",
	"resolve_thread",
	"unresolve_thread",
	"delete_comment",
	"thread_url",
	-- S1a — PR explorer + checkout
	"list_prs",
	"checkout_pr",
	-- S1b — PR info popup
	"get_pr_metadata",
	"update_pr_metadata",
	"get_checks",
	-- S1c — submit review
	"start_pending_review",
	"add_review_comment",
	"list_review_comments",
	"submit_review",
	"discard_pending_review",
	-- S2b — conflict-aware edits
	"refetch_comment",
	-- S3b — completion
	"list_collaborators",
	"list_issues",
	-- clears
	"clear",
	"clear_comments",
	"clear_hunks",
	"clear_pr_number",
	"clear_pr_list",
	"clear_pr_metadata",
	"clear_checks",
	"clear_pending_review",
	"clear_collaborators",
	"clear_issues",
}

local function check_cli(name)
	if vim.fn.executable(name) == 1 then
		vim.health.ok(name .. " found on PATH")
	else
		vim.health.error(name .. " not found on PATH")
	end
end

function M.check()
	vim.health.start("pr.nvim")

	local config = require("pr.config")
	local provider_name = config.opts.provider
	vim.health.ok("provider: " .. tostring(provider_name))

	local cli = PROVIDER_CLIS[provider_name]
	if cli then
		check_cli(cli)
	else
		vim.health.error("unknown provider: " .. tostring(provider_name))
	end

	check_cli("git")

	if pcall(require, "nui.popup") then
		vim.health.ok("nui.nvim available")
	else
		vim.health.error("nui.nvim not available")
	end

	if pcall(require, "plenary.job") then
		vim.health.ok("plenary.nvim available")
	else
		vim.health.error("plenary.nvim not available")
	end

	local picker_name = config.opts.picker
	local picker_mods = { snacks = "snacks", telescope = "telescope.builtin", fzf = "fzf-lua" }
	local picker_mod = picker_mods[picker_name]
	if picker_mod and pcall(require, picker_mod) then
		vim.health.ok("picker: " .. picker_name)
	else
		vim.health.warn("picker '" .. tostring(picker_name) .. "' not loadable")
	end

	local ok, provider = pcall(require, "pr.providers." .. provider_name)
	if ok then
		local impl = 0
		local missing = {}
		for _, m in ipairs(SURFACE) do
			if type(provider[m]) == "function" then
				impl = impl + 1
			else
				table.insert(missing, m)
			end
		end
		if #missing == 0 then
			vim.health.ok(("provider surface complete (%d/%d)"):format(impl, #SURFACE))
		else
			vim.health.warn(("provider surface %d/%d; missing: %s"):format(impl, #SURFACE, table.concat(missing, ", ")))
		end
	else
		vim.health.error("could not load provider module pr.providers." .. provider_name)
	end

	-- Inline comment text now flows through vim.diagnostic. If the user doesn't
	-- have a virtual-lines / virtual-text renderer active, the buffer overlay
	-- won't show below commented lines (signs in the gutter still work). Warn
	-- non-fatally so users can act on it.
	local diag_ns = require("pr.diagnostics").namespace
	local diag_cfg = vim.diagnostic.config(nil, diag_ns) or {}
	local has_vlines = diag_cfg.virtual_lines and true or false
	local has_vtext = diag_cfg.virtual_text and true or false
	local has_lsp_lines = pcall(require, "lsp_lines")
	if has_vlines or has_vtext or has_lsp_lines then
		local parts = {}
		if has_vlines then
			table.insert(parts, "virtual_lines")
		end
		if has_vtext then
			table.insert(parts, "virtual_text")
		end
		if has_lsp_lines then
			table.insert(parts, "lsp_lines.nvim")
		end
		vim.health.ok("inline comment text will render via vim.diagnostic (" .. table.concat(parts, ", ") .. ")")
	else
		vim.health.warn("no virtual-lines/virtual-text renderer is active; inline comment text will not display below commented lines", {
			"Enable `vim.diagnostic.config({ virtual_lines = true })` (Neovim 0.11+), or install `lsp_lines.nvim`.",
			"See README → 'Inline comment display' for namespace-scoped control.",
		})
	end
end

return M
