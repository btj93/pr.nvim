-- Classic plugin entry for pr.nvim.
--
-- Sourced automatically by Neovim at startup (unless started with --noplugin).
-- It registers every :PR* user command as a lightweight BOOTSTRAP stub WITHOUT
-- requiring the "pr" module, so plugin managers that lazy-load on command — and a
-- bare Neovim startup — pay zero cost until a command is actually run.
--
-- Design (single source of truth for command definitions):
--   * The real command table (names, opts, behavior) lives ONLY in
--     lua/pr/init.lua's COMMANDS table, registered by M._register_commands().
--   * Each stub here is registered with permissive opts (nargs = "*", plus range
--     and bang accepted) so ANY invocation parses into `a` regardless of the real
--     command's arity. On first use the stub calls require("pr")._ensure_setup()
--     — which runs setup({}) once and re-registers the REAL commands over these
--     stubs — then dispatches the original invocation exactly once via
--     M._dispatch(name, a), handing the already-parsed args straight through (no
--     vim.cmd reconstruction, so bang/range/nargs parity is a non-issue).
--   * If the user calls require("pr").setup() themselves (lazy `opts` path), the
--     real registration simply overwrites these stubs — nvim_create_user_command
--     overwrites silently — so registration is idempotent either way.
--
-- Deferring the require keeps this file free of any dependency on pr's runtime and
-- lets specs reload the "pr" module without a stale reference held here.

if vim.g.loaded_pr then
	return
end
vim.g.loaded_pr = 1

local commands = {
	"PRRefresh",
	"PRComment",
	"PRList",
	"PRInfo",
	"PRReview",
	"PRReviewDiscard",
	"PRSuggest",
	"PRQuickfix",
	"PRRefreshUsers",
	"PRRefreshIssues",
}

for _, name in ipairs(commands) do
	vim.api.nvim_create_user_command(name, function(a)
		local pr = require("pr")
		pr._ensure_setup()
		pr._dispatch(name, a)
	end, {
		nargs = "*",
		range = true,
		bang = true,
		desc = "pr.nvim: " .. name .. " (loads pr.nvim on first use)",
	})
end
