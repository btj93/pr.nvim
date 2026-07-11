-- Tier 2 flow spec for the refresh pipeline. `require("pr").refresh()` fans out
-- to comment.refresh + hunk.refresh: it invalidates the provider's caches
-- (clear_* recorded on the fake), redraws signs from the freshly-fetched data,
-- fires `User PRCommentsRefreshed` / `PRHunksRefreshed`, notifies a change
-- summary (suppressible via `show_diff = false`), drops orphaned drafts through
-- `drafts.invalidate_orphans`, and guards against a second refresh landing while
-- one is still in flight (the `refresh_in_progress` flag).
--
-- Strategy mirrors tests/comment_attach_spec.lua: install a fake provider so the
-- access-time proxy in pr.provider routes through it, and replace pr.drift /
-- pr.diagnostics / pr.drafts in package.loaded BEFORE requiring pr so the comment
-- module captures the stubs. That keeps draw off real git shelling, keeps real
-- vim.diagnostic entries out of the shared process, and lets us spy on
-- drafts.invalidate_orphans. Signs are defined exactly as init.lua's setup()
-- does so sign_place / sign_getplaced round-trip cleanly.

local config = require("pr.config")
config.opts = config.opts or {}

-- Drift stub: identity. drift_map = nil short-circuits commit_to_buffer inside
-- comment.draw so start_line/end_line render verbatim, and nothing shells git.
package.loaded["pr.drift"] = {
	get_for_buffer = function(_bufnr, _root, _rel, cb)
		cb(nil)
	end,
	invalidate = function() end,
	invalidate_all = function() end,
	commit_to_buffer = function(_m, line)
		return line
	end,
	buffer_to_commit = function(_m, line)
		return line
	end,
}

-- Diagnostics stub: publish is a no-op so the draw path doesn't push real
-- vim.diagnostic entries that would leak into the process.
package.loaded["pr.diagnostics"] = {
	namespace = vim.api.nvim_create_namespace("pr_threads_flow_refresh"),
	publish = function() end,
	clear = function() end,
	clear_all = function() end,
}

-- Drafts stub: record every invalidate_orphans call so the drafts-wiring test can
-- assert the fresh cache snapshot was handed over.
local drafts_calls = {}
package.loaded["pr.drafts"] = {
	invalidate_orphans = function(known)
		table.insert(drafts_calls, known)
	end,
	flush = function() end,
}

local fake_provider = require("helpers.fake_provider")

-- Require pr AFTER the stubs so comment.lua / hunk.lua capture them at load.
local pr = require("pr")
local comment = require("pr.comment")
local hunk = require("pr.hunk")

local FAKE = "flow_refresh_fake"

local function define_signs()
	local h = config.opts.highlights
	pcall(vim.fn.sign_define, h.sign_comment, { text = "║" })
	pcall(vim.fn.sign_define, h.sign_comment_multi_line_start, { text = "┌" })
	pcall(vim.fn.sign_define, h.sign_comment_multi_line_connector, { text = "│" })
	pcall(vim.fn.sign_define, h.sign_comment_multi_line_end, { text = "└" })
end
define_signs()

local function signs_for_buf(buf)
	local out = {}
	local placed = vim.fn.sign_getplaced(buf, { group = config.opts.highlights.sign_group })
	for _, grp in ipairs(placed or {}) do
		for _, s in ipairs(grp.signs or {}) do
			table.insert(out, s.lnum)
		end
	end
	table.sort(out)
	return out
end

local function has_sign_at(buf, lnum)
	for _, l in ipairs(signs_for_buf(buf)) do
		if l == lnum then
			return true
		end
	end
	return false
end

local function count_calls(fake, method)
	local n = 0
	for _, c in ipairs(fake.calls) do
		if c.method == method then
			n = n + 1
		end
	end
	return n
end

local function has_pr_notify(notifications)
	for _, n in ipairs(notifications) do
		if type(n.msg) == "string" and n.msg:find("new thread", 1, true) then
			return true
		end
	end
	return false
end

local function mk_thread(id, line, db)
	return {
		id = id,
		is_resolved = false,
		is_outdated = false,
		viewer_can_reply = true,
		comments = {
			{
				database_id = db or 1001,
				author = "alice",
				body = "hi",
				updated_at = "2026-01-01T00:00:00Z",
				start_line = line,
				end_line = line,
			},
		},
	}
end

describe("flow: pr.refresh() pipeline", function()
	local fake, uninstall, notifications, saved_notify

	before_each(function()
		comment.enabled = false
		hunk.enabled = false
		comment.wins = {}
		comment.bufs = {}
		comment.generations = {}
		hunk.wins = {}
		hunk.bufs = {}
		hunk.generations = {}
		pcall(vim.fn.sign_unplace, config.opts.highlights.sign_group)
		drafts_calls = {}

		notifications = {}
		saved_notify = vim.notify
		vim.notify = function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end

		fake, uninstall = fake_provider.install(FAKE, { comments = {}, hunks = {} })
	end)

	after_each(function()
		-- Drain any captured deferred calls so refresh_in_progress (a file-local in
		-- comment.lua) resets to false; otherwise the next test's refresh is skipped.
		if fake then
			while #fake._captured > 0 do
				pcall(fake.fire, fake._captured[1].name)
			end
		end
		vim.wait(100, function()
			return false
		end)
		comment.enabled = false
		hunk.enabled = false
		comment.wins = {}
		comment.bufs = {}
		hunk.wins = {}
		hunk.bufs = {}
		pcall(vim.fn.sign_unplace, config.opts.highlights.sign_group)
		vim.notify = saved_notify
		if uninstall then
			uninstall()
		end
	end)

	it("refresh() fires User PRCommentsRefreshed and PRHunksRefreshed", function()
		comment.enabled = true
		hunk.enabled = true

		local grp = vim.api.nvim_create_augroup("PRFlowRefreshEvents", { clear = true })
		local counts = { comments = 0, hunks = 0 }
		vim.api.nvim_create_autocmd("User", {
			group = grp,
			pattern = "PRCommentsRefreshed",
			callback = function()
				counts.comments = counts.comments + 1
			end,
		})
		vim.api.nvim_create_autocmd("User", {
			group = grp,
			pattern = "PRHunksRefreshed",
			callback = function()
				counts.hunks = counts.hunks + 1
			end,
		})

		pr.refresh()

		assert.is_true(
			vim.wait(1000, function()
				return counts.comments >= 1 and counts.hunks >= 1
			end),
			"both refresh events fired"
		)
		assert.equals(1, counts.comments)
		assert.equals(1, counts.hunks)

		pcall(vim.api.nvim_del_augroup_by_id, grp)
	end)

	it("refresh() invalidates provider caches (clear_* recorded on the fake) and redraws signs from fresh data", function()
		fake.scenario.comments = { ["foo.lua"] = { mk_thread("T1", 2) } }
		fake.comments = fake.scenario.comments

		local buf = vim.api.nvim_create_buf(false, false)
		vim.api.nvim_buf_set_name(buf, fake.scenario.git_root .. "/foo.lua")
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "l1", "l2", "l3", "l4", "l5", "l6", "l7", "l8" })
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)

		comment.enabled = true
		hunk.enabled = true
		comment.wins = { [win] = true }
		hunk.wins = {}

		pr.refresh()
		assert.is_true(
			vim.wait(1500, function()
				return has_sign_at(buf, 2)
			end),
			"sign drawn at line 2 from fresh data"
		)

		-- Every fine-grained cache invalidation the pipeline promises was recorded.
		for _, m in ipairs({
			"clear_pr_number",
			"clear_pr_list",
			"clear_pr_metadata",
			"clear_checks",
			"clear_pending_review",
			"clear_comments",
			"clear_hunks",
		}) do
			assert.truthy(fake_provider.called(fake, m), m .. " recorded")
		end

		-- Fresh data really drives the redraw: move the thread, refresh, sign moves.
		fake.scenario.comments["foo.lua"][1].comments[1].start_line = 5
		fake.scenario.comments["foo.lua"][1].comments[1].end_line = 5
		pr.refresh()
		assert.is_true(
			vim.wait(1500, function()
				return has_sign_at(buf, 5)
			end),
			"sign moved to line 5 after re-fetch"
		)
		assert.is_false(has_sign_at(buf, 2))

		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("refresh notifies a change summary; show_diff=false suppresses it", function()
		fake.deferred.get_comments = true
		fake.scenario.comments = { ["foo.lua"] = { mk_thread("T1", 1) } }
		fake.comments = fake.scenario.comments
		comment.enabled = true

		-- Summary case: refresh snapshots the 1-thread state, a new thread arrives
		-- before the deferred fetch fires, and _diff_comments notifies "1 new thread".
		pr.refresh()
		table.insert(fake.scenario.comments["foo.lua"], mk_thread("T2", 3, 1002))
		fake.fire("get_comments")
		assert.is_true(
			vim.wait(1000, function()
				return has_pr_notify(notifications)
			end),
			"change summary notified"
		)

		-- Suppress case: with show_diff=false no snapshot is taken and no notify fires.
		notifications = {}
		pr.refresh({ show_diff = false })
		table.insert(fake.scenario.comments["foo.lua"], mk_thread("T3", 5, 1003))
		fake.fire("get_comments")
		-- Let the deferred callback run; the assertion is that nothing was notified.
		vim.wait(300, function()
			return has_pr_notify(notifications)
		end)
		assert.is_false(has_pr_notify(notifications), "show_diff=false suppressed the summary")
	end)

	it("orphaned drafts are dropped after refresh (drafts.invalidate_orphans wiring)", function()
		fake.scenario.comments = { ["foo.lua"] = { mk_thread("T1", 1, 1001) } }
		fake.comments = fake.scenario.comments
		comment.enabled = true

		pr.refresh()
		assert.is_true(
			vim.wait(1000, function()
				return #drafts_calls > 0
			end),
			"invalidate_orphans called after refresh"
		)

		local known = drafts_calls[#drafts_calls]
		assert.is_true(known.paths["foo.lua"])
		assert.is_true(known.thread_ids["T1"])
		assert.is_true(known.comment_ids["1001"])
	end)

	it("a second refresh while one is in flight is skipped (refresh_in_progress guard, via deferred get_comments)", function()
		fake.deferred.get_comments = true
		fake.scenario.comments = { ["foo.lua"] = { mk_thread("T1", 1) } }
		fake.comments = fake.scenario.comments
		comment.enabled = true

		pr.refresh()
		assert.equals(1, count_calls(fake, "get_comments"), "first refresh launched the fetch")

		-- Second refresh must be a no-op while the first is still in flight.
		pr.refresh()
		assert.equals(1, count_calls(fake, "get_comments"), "second refresh skipped while in flight")

		-- Complete the in-flight fetch; the guard clears once its callback runs.
		fake.fire("get_comments")
		assert.is_true(
			vim.wait(1000, function()
				return #drafts_calls > 0
			end),
			"in-flight refresh completed"
		)

		-- A subsequent refresh now proceeds.
		pr.refresh()
		assert.equals(2, count_calls(fake, "get_comments"), "refresh resumes after in-flight completes")
	end)
end)
