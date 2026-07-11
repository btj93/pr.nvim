-- Tier 2 flow spec for pr.setup(): the one-time bootstrap that registers user
-- commands, defines signcolumn signs, installs the plugin's autocmd groups
-- (conditioned on config), wires the built-in winbar, and — via run_on_start —
-- optionally kicks comment.start / hunk.start.
--
-- DANGER (from the task brief): setup() with defaults starts a live 300s timer
-- and run_on_start.comments = true shells out. Every setup() here passes
-- run_on_start = { comments = false, hunks = false } and
-- auto_refresh = { interval = 0, on_branch_change = false, on_head_change = false }
-- unless the case under test needs one enabled, and after_each stops the timer
-- (set_refresh_interval(0)) and deletes every augroup so nothing leaks.

local fake_provider = require("helpers.fake_provider")

-- pr.config is never reloaded (the provider proxy captured it at load, and
-- reloading would desync the two), but the pr module IS reloaded per test so
-- setup()'s internal state (last_branch/last_git_root, timer handle) starts fresh.
-- Reloading resolves `pr` against the cwd, so restore the plugin root first.
local PLUGIN_ROOT = vim.fn.getcwd()

local SAFE_AUTO = { interval = 0, on_branch_change = false, on_head_change = false }

local function augroup_exists(name)
	-- nvim_get_autocmds errors when the group is undefined.
	return (pcall(vim.api.nvim_get_autocmds, { group = name }))
end

describe("flow: pr.setup()", function()
	local pr, comment, hunk, fake, uninstall

	before_each(function()
		vim.cmd.cd(PLUGIN_ROOT)
		comment = require("pr.comment")
		hunk = require("pr.hunk")
		package.loaded["pr"] = nil
		pr = require("pr")
		fake, uninstall = fake_provider.install("flow_setup_fake", {})
		pcall(function()
			require("pr.review_local")._set_path(vim.fn.tempname())
		end)
		pcall(function()
			require("pr.drafts")._set_path(vim.fn.tempname())
		end)
	end)

	after_each(function()
		pcall(function()
			pr.set_refresh_interval(0)
		end)
		pcall(comment.stop)
		pcall(hunk.stop)
		comment.enabled = false
		hunk.enabled = false
		for _, g in ipairs({
			"PRColorScheme",
			"PRAutoRefresh",
			"PRHeadChange",
			"PRWinbar",
			"PRDraftsFlush",
			"PRComment",
			"PRHunk",
			"PRCommentBufWrite",
			"PRHunkBufWrite",
		}) do
			pcall(vim.api.nvim_del_augroup_by_name, g)
		end
		if uninstall then
			uninstall()
		end
		vim.cmd("silent! %bwipeout!")
	end)

	it("setup registers all 10 user commands", function()
		pr.setup({ run_on_start = { comments = false, hunks = false }, auto_refresh = SAFE_AUTO })

		local cmds = vim.api.nvim_get_commands({})
		local expected = {
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
		assert.equals(10, #expected)
		for _, name in ipairs(expected) do
			assert.is_not_nil(cmds[name], "missing user command " .. name)
		end
	end)

	it("setup defines the 4 signs", function()
		pr.setup({ run_on_start = { comments = false, hunks = false }, auto_refresh = SAFE_AUTO })

		local h = require("pr.config").opts.highlights
		for _, name in ipairs({
			h.sign_comment,
			h.sign_comment_multi_line_start,
			h.sign_comment_multi_line_connector,
			h.sign_comment_multi_line_end,
		}) do
			local def = vim.fn.sign_getdefined(name)
			assert.is_true(#def > 0, "sign not defined: " .. name)
		end
	end)

	it("setup installs the PRColorScheme/PRAutoRefresh/PRHeadChange/PRWinbar/PRDraftsFlush augroups per config", function()
		-- Everything enabled → all five groups exist.
		pr.setup({
			winbar = { enabled = true },
			run_on_start = { comments = false, hunks = false },
			auto_refresh = { interval = 0, on_branch_change = true, on_head_change = true },
		})
		for _, g in ipairs({ "PRColorScheme", "PRDraftsFlush", "PRWinbar", "PRAutoRefresh", "PRHeadChange" }) do
			assert.is_true(augroup_exists(g), "expected augroup " .. g)
		end

		-- Drop the config-gated groups, then setup with them disabled: only the two
		-- unconditional groups come back.
		for _, g in ipairs({ "PRWinbar", "PRAutoRefresh", "PRHeadChange" }) do
			pcall(vim.api.nvim_del_augroup_by_name, g)
		end
		pr.setup({
			winbar = { enabled = false },
			run_on_start = { comments = false, hunks = false },
			auto_refresh = SAFE_AUTO,
		})
		assert.is_true(augroup_exists("PRColorScheme"))
		assert.is_true(augroup_exists("PRDraftsFlush"))
		assert.is_false(augroup_exists("PRWinbar"), "PRWinbar should be gated off")
		assert.is_false(augroup_exists("PRAutoRefresh"), "PRAutoRefresh should be gated off")
		assert.is_false(augroup_exists("PRHeadChange"), "PRHeadChange should be gated off")
	end)

	it("winbar.enabled=true sets vim.wo.winbar on BufWinEnter under the git root; disabled leaves it alone", function()
		fake.pr_number = 7
		fake.scenario.pr_number = 7
		fake.comments = {}
		fake.scenario.comments = {}
		fake.repo_info = { owner = "o", repo = "r" }

		-- Anchor git_root to the buffer's actual (normalized) name so the prefix
		-- check in apply_winbar can't be defeated by /var → /private/var resolution.
		local buf = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/foo.lua")
		local root = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":h")
		fake.git_root = root
		fake.scenario.git_root = root

		pr.setup({
			winbar = { enabled = true, format = "[PR #%d · %d unresolved]" },
			run_on_start = { comments = false, hunks = false },
			auto_refresh = SAFE_AUTO,
		})

		vim.api.nvim_win_set_buf(0, buf)
		vim.cmd("doautocmd BufWinEnter")
		assert.matches("#7", vim.wo.winbar)

		-- Disabled: drop the augroup, setup with winbar off, and confirm a fresh
		-- BufWinEnter leaves winbar untouched.
		pcall(vim.api.nvim_del_augroup_by_name, "PRWinbar")
		vim.wo.winbar = ""
		pr.setup({
			winbar = { enabled = false },
			run_on_start = { comments = false, hunks = false },
			auto_refresh = SAFE_AUTO,
		})
		assert.is_false(augroup_exists("PRWinbar"))

		local buf2 = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(buf2, root .. "/bar.lua")
		vim.api.nvim_win_set_buf(0, buf2)
		vim.cmd("doautocmd BufWinEnter")
		assert.equals("", vim.wo.winbar)
	end)

	it("run_on_start gates comment.start/hunk.start", function()
		-- comments only
		pr.setup({ run_on_start = { comments = true, hunks = false }, auto_refresh = SAFE_AUTO })
		assert.is_true(comment.enabled, "comments should start")
		assert.is_false(hunk.enabled, "hunks should stay off")
		comment.stop()
		hunk.stop()

		-- hunks only
		pr.setup({ run_on_start = { comments = false, hunks = true }, auto_refresh = SAFE_AUTO })
		assert.is_false(comment.enabled, "comments should stay off")
		assert.is_true(hunk.enabled, "hunks should start")
		comment.stop()
		hunk.stop()

		-- neither
		pr.setup({ run_on_start = { comments = false, hunks = false }, auto_refresh = SAFE_AUTO })
		assert.is_false(comment.enabled)
		assert.is_false(hunk.enabled)
	end)
end)

-- The classic plugin entry (plugin/pr.lua) registers every :PR* command as a
-- lightweight BOOTSTRAP stub WITHOUT requiring "pr" at source time. The first
-- time any command runs, the stub calls require("pr")._ensure_setup() (which
-- runs setup({}) once) and then dispatches the invocation.
--
-- DANGER (same as the setup() describe above): the auto-setup uses DEFAULTS —
-- run_on_start.comments = true (shells out; the fake provider absorbs it) and
-- auto_refresh.interval = 300 (a live timer) — so every case installs the fake
-- provider BEFORE invoking a command and after_each stops the timer, deletes
-- the augroups, and drops the 10 commands so nothing leaks into the next spec.
describe("flow: plugin/pr.lua entry (auto-setup)", function()
	local ALL_COMMANDS = {
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

	local comment, hunk, uninstall

	local function del_all_commands()
		for _, name in ipairs(ALL_COMMANDS) do
			pcall(vim.api.nvim_del_user_command, name)
		end
	end

	before_each(function()
		vim.cmd.cd(PLUGIN_ROOT)
		comment = require("pr.comment")
		hunk = require("pr.hunk")
		-- Clean slate: no leftover commands, no cached pr module, and the load
		-- guard reset so dofile actually re-runs the plugin body.
		del_all_commands()
		package.loaded["pr"] = nil
		vim.g.loaded_pr = nil
		-- The returned fake is unused here (installed only so auto-setup's default
		-- run_on_start/refresh shell-outs resolve through it, not real gh).
		uninstall = select(2, fake_provider.install("flow_plugin_fake", {}))
		pcall(function()
			require("pr.review_local")._set_path(vim.fn.tempname())
		end)
		pcall(function()
			require("pr.drafts")._set_path(vim.fn.tempname())
		end)
		-- Source the classic entry point WITHOUT calling setup().
		dofile(PLUGIN_ROOT .. "/plugin/pr.lua")
	end)

	after_each(function()
		local pr = package.loaded["pr"]
		if pr then
			pcall(function()
				pr.set_refresh_interval(0)
			end)
		end
		pcall(comment.stop)
		pcall(hunk.stop)
		comment.enabled = false
		hunk.enabled = false
		for _, g in ipairs({
			"PRColorScheme",
			"PRAutoRefresh",
			"PRHeadChange",
			"PRWinbar",
			"PRDraftsFlush",
			"PRComment",
			"PRHunk",
			"PRCommentBufWrite",
			"PRHunkBufWrite",
		}) do
			pcall(vim.api.nvim_del_augroup_by_name, g)
		end
		del_all_commands()
		vim.g.loaded_pr = nil
		if uninstall then
			uninstall()
		end
		vim.cmd("silent! %bwipeout!")
	end)

	it("sourcing plugin/pr.lua registers all 10 commands without loading the pr module", function()
		-- Laziness: sourcing the plugin must NOT require("pr").
		assert.is_nil(package.loaded["pr"], "plugin/pr.lua must not require('pr') at source time")

		local cmds = vim.api.nvim_get_commands({})
		assert.equals(10, #ALL_COMMANDS)
		for _, name in ipairs(ALL_COMMANDS) do
			assert.is_not_nil(cmds[name], "missing user command " .. name)
		end
	end)

	it("first command invocation auto-runs setup() exactly once (defines signs)", function()
		local pr = require("pr")
		local setup_calls = 0
		local orig_setup = pr.setup
		pr.setup = function(o)
			setup_calls = setup_calls + 1
			return orig_setup(o)
		end

		local sign = require("pr.config").opts.highlights.sign_comment
		vim.fn.sign_undefine(sign)
		assert.equals(0, #vim.fn.sign_getdefined(sign), "sign should be undefined before any command runs")

		-- Invoke through the bootstrap stub: ensures setup, then dispatches.
		vim.cmd("PRRefresh")
		assert.equals(1, setup_calls, "setup should run exactly once")
		assert.is_true(#vim.fn.sign_getdefined(sign) > 0, "setup should have defined the comment sign")

		-- A second invocation hits the real command (which overwrote the stub) and
		-- must NOT re-run setup.
		vim.cmd("PRRefresh")
		assert.equals(1, setup_calls, "setup should not run again on subsequent invocations")

		pr.setup = orig_setup
	end)

	it("sourcing plugin/pr.lua AFTER setup() does not clobber the real commands", function()
		-- Native pack / manual rtp ordering: the user's init.lua calls setup()
		-- FIRST, then Neovim sources plugin/pr.lua. The stubs must not overwrite
		-- the real commands (which carry completion + strict arg specs).
		del_all_commands()
		vim.g.loaded_pr = nil

		local pr = require("pr")
		pr.setup({ run_on_start = { comments = false, hunks = false }, auto_refresh = SAFE_AUTO })

		-- Belt 1: setup() itself claims the load guard so a later plugin source
		-- no-ops outright.
		assert.is_not_nil(vim.g.loaded_pr, "setup() should set vim.g.loaded_pr")

		local function assert_real_commands(label)
			local cmds = vim.api.nvim_get_commands({})
			assert.equals("?", cmds.PRList.nargs, label .. ": PRList nargs should stay '?' (stub uses '*')")
			assert.is_not_nil(cmds.PRList.complete, label .. ": PRList completion should survive (stubs have none)")
			assert.equals("?", cmds.PRQuickfix.nargs, label .. ": PRQuickfix nargs should stay '?'")
		end
		assert_real_commands("after setup")

		dofile(PLUGIN_ROOT .. "/plugin/pr.lua")
		assert_real_commands("after post-setup plugin source")

		-- Belt 2: even with the flag lost (exotic ordering — setup ran but
		-- vim.g.loaded_pr is unset), the plugin file must detect the existing real
		-- commands and skip stub registration.
		vim.g.loaded_pr = nil
		dofile(PLUGIN_ROOT .. "/plugin/pr.lua")
		assert_real_commands("after flag-less plugin source")

		-- Invoking a command goes through the real implementation, not a stub:
		-- stubs (and only stubs) route through _ensure_setup.
		local ensure_calls = 0
		local orig_ensure = pr._ensure_setup
		pr._ensure_setup = function(...)
			ensure_calls = ensure_calls + 1
			return orig_ensure(...)
		end
		vim.cmd("PRRefresh")
		pr._ensure_setup = orig_ensure
		assert.equals(0, ensure_calls, "invocation must not route through a bootstrap stub")
	end)

	it("explicit setup() after auto-setup re-merges config without erroring or double-registering", function()
		-- Trigger auto-setup via a command (defaults; fake provider absorbs it).
		vim.cmd("PRRefresh")

		local pr = require("pr")
		assert.has_no.errors(function()
			pr.setup({
				winbar = { enabled = true, format = "[PR #%d · %d unresolved]" },
				run_on_start = { comments = false, hunks = false },
				auto_refresh = SAFE_AUTO,
			})
		end)

		-- The later explicit setup re-ran the config merge: winbar (off by default,
		-- so absent after auto-setup) is now enabled.
		assert.is_true(augroup_exists("PRWinbar"), "explicit setup should re-apply config (winbar)")

		-- Still exactly the 10 commands, none dropped or duplicated.
		local cmds = vim.api.nvim_get_commands({})
		for _, name in ipairs(ALL_COMMANDS) do
			assert.is_not_nil(cmds[name], "command missing after explicit setup: " .. name)
		end
	end)
end)
