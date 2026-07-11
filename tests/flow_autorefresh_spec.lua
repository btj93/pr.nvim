-- Tier 2 flow spec for pr.nvim's automatic-refresh triggers:
--   * branch-change detection (_check_branch_and_refresh over a REAL temp repo),
--   * git-root-change reset,
--   * the periodic libuv timer (set_refresh_interval), and
--   * BufWritePost HEAD-change detection (on_head_change).
--
-- These all lean on git subprocess reads (async plenary.job), so we use real
-- temp git repos (helpers.git_repo) and chdir Neovim into them. The provider is a
-- fake so M.refresh's internals don't shell out; for the branch/HEAD/root cases we
-- swap M.refresh for a spy and assert on the opts it was called with.
--
-- last_branch / last_git_root / last_head are file-locals seeded per process, so
-- we reload the pr module in before_each to reset them to nil. DANGER: every
-- timer must be stopped via set_refresh_interval(0) and every augroup deleted in
-- after_each so nothing leaks into the next test in this file.

local fake_provider = require("helpers.fake_provider")
local git_repo = require("helpers.git_repo")

-- The plugin is on the runtimepath as a relative "." entry, so `require("pr")`
-- resolves against the *current* working directory. Tests chdir into temp repos,
-- so capture the plugin root here and restore it before every (re)load.
local PLUGIN_ROOT = vim.fn.getcwd()

describe("flow: auto-refresh", function()
	local pr, comment, hunk, fake, uninstall
	local notifications, saved_notify

	local function install_notify()
		notifications = {}
		saved_notify = vim.notify
		vim.notify = function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end
	end

	--- Replace pr.refresh with a spy on the (reloaded) module and return the
	--- captured opts list. check_branch_and_refresh / the HEAD-change handler call
	--- M.refresh via dynamic field access, so overwriting the field intercepts them.
	local function spy_refresh()
		local calls = {}
		pr.refresh = function(opts)
			table.insert(calls, opts or {})
		end
		return calls
	end

	local function notified(substr)
		for _, n in ipairs(notifications) do
			if type(n.msg) == "string" and n.msg:find(substr, 1, true) then
				return true
			end
		end
		return false
	end

	before_each(function()
		vim.cmd.cd(PLUGIN_ROOT)
		comment = require("pr.comment")
		hunk = require("pr.hunk")
		-- Fresh pr module → last_branch / last_git_root / last_head reset to nil.
		package.loaded["pr"] = nil
		pr = require("pr")
		install_notify()
		fake, uninstall = fake_provider.install("flow_autorefresh_fake", {})
		comment.enabled = false
		hunk.enabled = false
		comment.wins = {}
		comment.bufs = {}
		hunk.wins = {}
		hunk.bufs = {}
	end)

	after_each(function()
		vim.cmd.cd(PLUGIN_ROOT)
		pcall(function()
			pr.set_refresh_interval(0)
		end)
		-- Drain deferred provider callbacks (the timer test leaves a captured
		-- get_comments) so comment.lua's refresh_in_progress flag resets.
		if fake then
			while #fake._captured > 0 do
				pcall(fake.fire, fake._captured[1].name)
			end
		end
		vim.wait(100, function()
			return false
		end)
		pcall(comment.stop)
		pcall(hunk.stop)
		comment.enabled = false
		hunk.enabled = false
		for _, g in ipairs({
			"PRComment",
			"PRHunk",
			"PRCommentBufWrite",
			"PRHunkBufWrite",
			"PRAutoRefresh",
			"PRHeadChange",
			"PRColorScheme",
			"PRWinbar",
			"PRDraftsFlush",
		}) do
			pcall(vim.api.nvim_del_augroup_by_name, g)
		end
		vim.notify = saved_notify
		if uninstall then
			uninstall()
		end
	end)

	it("_check_branch_and_refresh: same branch -> no refresh; changed branch -> refresh with show_diff=false", function()
		local repo = git_repo.create({ files = { ["a.txt"] = { "hello" } } })
		fake.scenario.git_root = repo.root
		vim.cmd.cd(repo.root)
		comment.enabled = true
		local calls = spy_refresh()

		-- Seed last_branch/last_git_root and confirm same-branch is a no-op. The
		-- bounded predicate wait also drains the async git reads (predicate stays
		-- false → the wait doubles as "no spurious refresh").
		pr._check_branch_and_refresh()
		pr._check_branch_and_refresh()
		vim.wait(1000, function()
			return #calls > 0
		end)
		assert.equals(0, #calls, "seed + same branch do not refresh")

		-- Switch branches → refresh fires, and with show_diff=false (diffing across
		-- a different branch's PR is meaningless).
		repo.checkout("feature", true)
		pr._check_branch_and_refresh()
		assert.is_true(
			vim.wait(2000, function()
				return #calls > 0
			end),
			"branch change triggered a refresh"
		)
		assert.equals(1, #calls)
		assert.is_false(calls[1].show_diff)
		assert.is_true(notified("Switched to branch"))

		repo.cleanup()
	end)

	it("git root change resets provider state before refreshing", function()
		local repo_a = git_repo.create({ files = { ["a.txt"] = { "a" } } })
		local repo_b = git_repo.create({ files = { ["b.txt"] = { "b" } } })
		fake.scenario.git_root = repo_a.root
		comment.enabled = true

		-- Seed last_git_root = repo_a. No provider clear happens on the seed path;
		-- the bounded wait drains the async git read.
		vim.cmd.cd(repo_a.root)
		pr._check_branch_and_refresh()
		vim.wait(1000, function()
			return fake_provider.called(fake, "clear") ~= nil
		end)
		assert.is_nil(fake_provider.called(fake, "clear"), "no reset while inside the same root")

		-- Enter a different git root → provider state is cleared before restart.
		vim.cmd.cd(repo_b.root)
		pr._check_branch_and_refresh()
		assert.is_true(
			vim.wait(2000, function()
				return fake_provider.called(fake, "clear") ~= nil
			end),
			"provider state cleared on git-root change"
		)
		assert.is_true(notified("different git root"))

		repo_a.cleanup()
		repo_b.cleanup()
	end)

	it("set_refresh_interval(1) ticks a refresh when a feature is enabled, and never when both disabled", function()
		fake.deferred.get_comments = true

		-- Both features disabled → the timer callback gates out, no refresh.
		comment.enabled = false
		hunk.enabled = false
		pr.set_refresh_interval(1)
		vim.wait(1500, function()
			return fake_provider.called(fake, "get_comments") ~= nil
		end)
		assert.is_nil(fake_provider.called(fake, "get_comments"), "no tick while both features disabled")
		pr.set_refresh_interval(0)

		-- Enable a feature → the next tick drives a refresh (observed via the
		-- deferred get_comments the pipeline launches).
		comment.enabled = true
		pr.set_refresh_interval(1)
		assert.is_true(
			vim.wait(3000, function()
				return fake_provider.called(fake, "get_comments") ~= nil
			end),
			"timer ticked a refresh once a feature was enabled"
		)
		pr.set_refresh_interval(0)
	end)

	it("BufWritePost inside the repo triggers HEAD-change refresh when on_head_change=true", function()
		local repo = git_repo.create({ files = { ["file.txt"] = { "one" } } })
		fake.scenario.git_root = repo.root
		-- The handler reads the git.git_root *field* directly (not via get_git_root),
		-- so set the cache field too.
		fake.git_root = repo.root
		-- No chdir needed: the HEAD-change handler reads `git -C <root> rev-parse`,
		-- and chdir'ing away from the plugin root would break setup()'s lazy requires.

		pr.setup({
			run_on_start = { comments = false, hunks = false },
			auto_refresh = { interval = 0, on_branch_change = false, on_head_change = true },
		})
		-- The handler gates on comment.enabled or hunk.enabled; run_on_start is off.
		comment.enabled = true
		-- Spy AFTER setup so we replace the real refresh setup() installed.
		local calls = spy_refresh()

		vim.cmd.edit(repo.root .. "/file.txt")
		local buf = vim.api.nvim_get_current_buf()

		-- First write seeds last_head (handler: last_head nil → no refresh). The
		-- bounded wait drains the async git rev-parse that records last_head.
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two" })
		vim.cmd.write()
		vim.wait(1000, function()
			return #calls > 0
		end)
		assert.equals(0, #calls, "first write only seeds HEAD")

		-- Rotate HEAD then write again → HEAD differs → refresh with show_diff=false.
		repo.commit("bump")
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
		vim.cmd.write()
		assert.is_true(
			vim.wait(2000, function()
				return #calls > 0
			end),
			"HEAD change triggered a refresh"
		)
		assert.is_false(calls[1].show_diff)
		assert.is_true(notified("HEAD changed"))

		repo.cleanup()
	end)
end)
