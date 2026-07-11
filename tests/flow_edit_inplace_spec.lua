-- Tier 2 flow spec: exercises ui._start_inline_edit end-to-end. The inline
-- editor operates on a raw scratch buffer + float window (ui.lua audit §4), so
-- unlike the mount-based flow specs this one needs NO nui — it never builds a
-- NuiLayout. Coverage: the commit path, the unchanged/no-op path, the
-- out-of-range revert backstop, dim-extmark lifecycle, and every
-- conflict-detection branch (proceed/overwrite/refresh/abort + disabled).
--
-- The commit trigger is InsertLeave, fired synthetically with
-- nvim_exec_autocmds after mutating the buffer. Commit / conflict callbacks are
-- schedule_wrapped, so every post-fire assertion is gated on an
-- env.wait_for(predicate) rather than a fixed sleep.
local ui_env = require("helpers.ui_env")
local fake_provider = require("helpers.fake_provider")
local called = fake_provider.called
local ui = require("pr.ui")
local config = require("pr.config")

-- The fixture buffer: header / body-1 / body-2 / footer. ctx.body_range spans
-- buffer lines 2-3 (the two body lines) which match the fixture comment body
-- "line one\nline two".
local BUF_LINES = { "── alice ──", "line one", "line two", "── footer" }

local function make_edit_buffer()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, BUF_LINES)
	vim.bo[buf].modifiable = false
	local win = vim.api.nvim_open_win(buf, false, {
		relative = "editor",
		width = 40,
		height = 6,
		row = 1,
		col = 1,
		style = "minimal",
	})
	return buf, win
end

local function has_notification(env, needle)
	for _, n in ipairs(env.notifications) do
		if type(n.msg) == "string" and n.msg:find(needle, 1, true) then
			return true
		end
	end
	return false
end

describe("flow: inline edit via _start_inline_edit", function()
	local env, fake, uninstall, buf, win, thread, comment, re_render_calls, ctx
	local prev_conflict

	before_each(function()
		env = ui_env.setup()
		fake, uninstall = fake_provider.install("flow_edit_fake", {
			comments = {
				["lua/a.lua"] = {
					{
						id = "T1",
						is_resolved = false,
						is_outdated = false,
						viewer_can_reply = true,
						comments = {
							{
								database_id = 1,
								author = "alice",
								body = "line one\nline two",
								updated_at = "2026-01-01T00:00:00Z",
								viewer_can_update = true,
								viewer_can_delete = true,
								viewer_can_react = true,
								start_line = 1,
								end_line = 1,
							},
						},
					},
				},
			},
		})
		-- `comment` is the SAME table the fake's refetch_comment reads out of
		-- scenario, so bumping comment.updated_at / comment.body below simulates a
		-- remote edit that refetch will observe.
		thread = fake.scenario.comments["lua/a.lua"][1]
		comment = thread.comments[1]

		buf, win = make_edit_buffer()
		re_render_calls = 0
		ctx = {
			bufnr = buf,
			winid = win,
			body_range = { body_start = 2, body_end = 3 },
			re_render = function()
				re_render_calls = re_render_calls + 1
			end,
		}

		config.opts.conflict_detection = config.opts.conflict_detection or {}
		prev_conflict = config.opts.conflict_detection.enabled
	end)

	after_each(function()
		config.opts.conflict_detection.enabled = prev_conflict
		uninstall()
		env.teardown()
	end)

	it("commit path: edited body reaches git.edit_comment and teardown restores the buffer", function()
		config.opts.conflict_detection.enabled = true

		ui._start_inline_edit(thread, comment, ctx)
		-- Entering edit mode: buffer becomes editable, the edit id is stamped.
		assert.is_true(vim.bo[buf].modifiable)
		assert.equals(1, vim.b[buf].pr_edit_comment_id)

		-- Edit inside the body (line 2) and leave insert mode.
		vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "line one edited" })
		vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })

		-- updated_at is unchanged, so the conflict check resolves to "proceed" and
		-- the commit lands. Teardown flips modifiable back off.
		env.wait_for(function()
			return called(fake, "edit_comment") ~= nil and not vim.bo[buf].modifiable
		end, 2000, "edit_comment committed + teardown")

		local call = called(fake, "edit_comment")
		assert.equals(1, call.args[1])
		assert.equals("line one edited\nline two", call.args[2])
		-- Teardown: modifiable off, edit id cleared, save notified, re_render run.
		assert.is_nil(vim.b[buf].pr_edit_comment_id)
		assert.is_true(has_notification(env, "Comment saved"))
		assert.equals(1, re_render_calls)
	end)

	it("unchanged body commits nothing", function()
		config.opts.conflict_detection.enabled = true

		ui._start_inline_edit(thread, comment, ctx)
		-- No buffer edit at all; InsertLeave should tear down without an API call.
		vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })

		env.wait_for(function()
			return not vim.bo[buf].modifiable
		end, 2000, "teardown without commit")

		assert.is_nil(called(fake, "edit_comment"))
		-- No commit was attempted, so the conflict refetch never ran either.
		assert.is_nil(called(fake, "refetch_comment"))
		assert.is_nil(vim.b[buf].pr_edit_comment_id)
		assert.equals(1, re_render_calls)
	end)

	it("out-of-range edit is reverted and notifies", function()
		ui._start_inline_edit(thread, comment, ctx)

		-- Edit the header (line 1) — outside the body range. The on_lines backstop
		-- schedules a splice that restores the buffer to its pre-edit state.
		vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "── HACKED ──" })

		env.wait_for(function()
			return has_notification(env, "Edit reverted")
		end, 2000, "out-of-range revert scheduled")

		-- The header is back and the body is untouched.
		assert.same(BUF_LINES, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		-- A reverted edit is not a commit.
		assert.is_nil(called(fake, "edit_comment"))
	end)

	it("dim extmarks cover exactly the non-body lines and clear on teardown", function()
		ui._start_inline_edit(thread, comment, ctx)

		local ns = vim.api.nvim_create_namespace("PRCommentEditDim")
		local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
		local rows = {}
		for _, m in ipairs(marks) do
			table.insert(rows, m[2])
		end
		table.sort(rows)
		-- Body occupies buffer lines 2-3 (0-indexed rows 1-2); the dim overlay
		-- covers only the header (row 0) and footer (row 3).
		assert.same({ 0, 3 }, rows)

		-- An unchanged-body InsertLeave tears down and clears the namespace.
		vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })
		env.wait_for(function()
			return not vim.bo[buf].modifiable
		end, 2000, "teardown clears dim overlay")

		assert.same({}, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
	end)

	it("conflict: updated_at mismatch + confirm=Abort -> no edit_comment call", function()
		config.opts.conflict_detection.enabled = true

		ui._start_inline_edit(thread, comment, ctx)

		-- Local edit so InsertLeave triggers a commit attempt.
		vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "local change" })
		-- Simulate a remote edit landing after edit-start: refetch will now return
		-- a newer updated_at than the snapshot, forcing the conflict prompt.
		comment.updated_at = "2026-09-09T00:00:00Z"
		comment.body = "remote change\nline two"

		-- Abort is a pure no-op, so there is no state change to wait on. Detect the
		-- confirm prompt itself; once it returns, _conflict_decision runs
		-- synchronously in the same scheduled tick.
		local confirm_seen = false
		vim.fn.confirm = function()
			confirm_seen = true
			return env.confirm_choice
		end
		env.confirm_choice = 3 -- &Abort (vim.fn.confirm's 3rd choice / dialog default)

		vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })
		env.wait_for(function()
			return confirm_seen
		end, 2000, "conflict prompt shown")

		-- Refetch happened, the prompt fired, but the abort suppressed the write.
		assert.is_not_nil(called(fake, "refetch_comment"))
		assert.is_nil(called(fake, "edit_comment"))
		-- Abort leaves the user in edit mode with their in-flight body intact.
		assert.is_true(vim.bo[buf].modifiable)
		assert.equals(1, vim.b[buf].pr_edit_comment_id)
		assert.equals("local change", vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1])
	end)

	it("conflict: Overwrite -> edit_comment called with local body", function()
		config.opts.conflict_detection.enabled = true

		ui._start_inline_edit(thread, comment, ctx)

		vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "local overwrite" })
		comment.updated_at = "2026-09-09T00:00:00Z"
		comment.body = "remote body\nline two"
		env.confirm_choice = 1 -- &Overwrite

		vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })
		env.wait_for(function()
			return called(fake, "edit_comment") ~= nil
		end, 2000, "overwrite commits")

		local call = called(fake, "edit_comment")
		assert.equals(1, call.args[1])
		-- The LOCAL in-buffer body is sent, not the fresh remote body.
		assert.equals("local overwrite\nline two", call.args[2])
		-- Overwrite is a real commit: it tears the editor down.
		env.wait_for(function()
			return not vim.bo[buf].modifiable
		end, 2000, "teardown after overwrite")
		assert.is_nil(vim.b[buf].pr_edit_comment_id)
	end)

	it("conflict: Refresh -> body range rewritten with fresh body, still in edit mode, no edit_comment call", function()
		config.opts.conflict_detection.enabled = true

		ui._start_inline_edit(thread, comment, ctx)

		vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "my local edit" })
		comment.updated_at = "2026-09-09T00:00:00Z"
		comment.body = "remote line one\nremote line two"
		env.confirm_choice = 2 -- &Refresh and re-edit

		vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })
		env.wait_for(function()
			return vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "remote line one"
		end, 2000, "body refreshed from remote")

		-- The body range now holds the fresh remote text (the local edit is gone),
		-- while the header/footer are untouched.
		assert.same({ "remote line one", "remote line two" }, vim.api.nvim_buf_get_lines(buf, 1, 3, false))
		assert.equals("── alice ──", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
		assert.equals("── footer", vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1])
		-- Refresh keeps the user in edit mode and commits nothing.
		assert.is_true(vim.bo[buf].modifiable)
		assert.equals(1, vim.b[buf].pr_edit_comment_id)
		assert.is_nil(called(fake, "edit_comment"))
		assert.is_true(has_notification(env, "Comment refreshed"))
	end)

	it("conflict_detection.enabled=false skips refetch entirely", function()
		config.opts.conflict_detection.enabled = false

		ui._start_inline_edit(thread, comment, ctx)

		vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "line one edited" })
		vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })

		env.wait_for(function()
			return called(fake, "edit_comment") ~= nil
		end, 2000, "commit without refetch")

		-- The whole conflict path is bypassed: refetch_comment is never called.
		assert.is_nil(called(fake, "refetch_comment"))
		assert.equals("line one edited\nline two", called(fake, "edit_comment").args[2])
	end)

	-- ---- edit-draft persistence (wired into the live inline-edit path) ----

	it("typing during inline edit persists an edit draft keyed by database_id", function()
		local drafts = require("pr.drafts")

		ui._start_inline_edit(thread, comment, ctx)
		-- In-range body edit -> the on_lines watcher persists the draft.
		vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "line one edited" })

		-- save_edit updates the in-memory cache synchronously; get_edit reads that
		-- cache, so the debounced disk write is irrelevant here.
		env.wait_for(function()
			return drafts.get_edit(1) ~= nil
		end, 2000, "edit draft persisted on type")

		local d = drafts.get_edit(1)
		local body = type(d.body) == "table" and table.concat(d.body, "\n") or d.body
		-- The full body range is stored, not just the edited line.
		assert.equals("line one edited\nline two", body)
		-- Keyed to the comment's updated_at snapshot at edit-start.
		assert.equals("2026-01-01T00:00:00Z", d.updated_at)
	end)

	it("re-entering inline edit pre-fills the body from a matching draft", function()
		local drafts = require("pr.drafts")
		-- A draft whose updated_at matches the live comment must be restored into
		-- the body range on entry; the header/footer stay put.
		drafts.save_edit(1, { body = { "drafted one", "drafted two" }, updated_at = comment.updated_at })

		ui._start_inline_edit(thread, comment, ctx)

		assert.same({ "drafted one", "drafted two" }, vim.api.nvim_buf_get_lines(buf, 1, 3, false))
		assert.equals("── alice ──", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
		assert.equals("── footer", vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1])
	end)

	it("pre-fill adjusts the body range when the draft line count differs", function()
		local drafts = require("pr.drafts")
		-- Single-line draft over a two-line body: the range shrinks and the footer
		-- rides up. An unchanged InsertLeave is then a no-op (the draft is what's on
		-- screen), so nothing is committed and the draft is retained.
		drafts.save_edit(1, { body = { "just one line" }, updated_at = comment.updated_at })

		ui._start_inline_edit(thread, comment, ctx)
		assert.same({ "── alice ──", "just one line", "── footer" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

		vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })
		env.wait_for(function()
			return not vim.bo[buf].modifiable
		end, 2000, "teardown without commit")
		assert.is_nil(called(fake, "edit_comment"), "unchanged prefilled body commits nothing")
		assert.is_not_nil(drafts.get_edit(1), "unchanged exit retains the draft")
	end)

	it("stale edit draft (updated_at mismatch) is dropped and not applied", function()
		local drafts = require("pr.drafts")
		drafts.save_edit(1, { body = { "STALE draft body" }, updated_at = "2000-01-01T00:00:00Z" })

		ui._start_inline_edit(thread, comment, ctx)

		-- The body still shows the live comment text; the stale draft is discarded.
		assert.same({ "line one", "line two" }, vim.api.nvim_buf_get_lines(buf, 1, 3, false))
		assert.is_nil(drafts.get_edit(1), "stale draft dropped from the store")
	end)

	it("successful commit deletes the pending edit draft", function()
		config.opts.conflict_detection.enabled = false
		local drafts = require("pr.drafts")

		ui._start_inline_edit(thread, comment, ctx)
		vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "committed edit" })
		env.wait_for(function()
			return drafts.get_edit(1) ~= nil
		end, 2000, "draft saved before commit")

		vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })
		env.wait_for(function()
			return called(fake, "edit_comment") ~= nil and drafts.get_edit(1) == nil
		end, 2000, "commit clears the draft")
	end)

	it("cancel (skip-commit) retains the pending edit draft", function()
		local drafts = require("pr.drafts")

		ui._start_inline_edit(thread, comment, ctx)
		vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "in-flight cancelled edit" })
		env.wait_for(function()
			return drafts.get_edit(1) ~= nil
		end, 2000, "draft saved before cancel")

		-- Fire the <C-c> cancel mapping (sets skip_commit_on_leave), then the
		-- synthetic InsertLeave the mapping's <Esc> would produce.
		for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, "i")) do
			if km.desc == "PR: cancel comment edit" and km.callback then
				km.callback()
			end
		end
		vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })

		env.wait_for(function()
			return not vim.bo[buf].modifiable
		end, 2000, "teardown after cancel")
		assert.is_nil(called(fake, "edit_comment"), "cancel commits nothing")
		assert.is_not_nil(drafts.get_edit(1), "cancel retains the draft (crash-safety)")
	end)
end)
