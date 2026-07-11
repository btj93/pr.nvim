-- Tier 2 flow spec: drives the `a` (apply_suggestion) and `ya` (yank_suggestion)
-- actions on a thread rendered by make_comments_layout, over the fake provider
-- inside the headless ui_env harness.
--
--   a  on a comment carrying a ```suggestion``` block rewrites the anchored
--      lines in the SOURCE buffer (resolved via ctx.source_bufnr / relative_path
--      and mapped through drift).
--   a  on a comment WITHOUT a suggestion falls through to inline-edit (Task 5's
--      dispatcher fallback) and never calls suggestion.apply.
--   ya yanks the suggestion content into the + and " registers.
--
-- apply resolves the file against a REAL git repo (helpers.git_repo) so
-- drift.get_for_buffer shells real git; the committed buffer == HEAD, giving an
-- identity drift map. Post-key assertions gate on env.wait_for because the
-- get_git_root / drift callbacks are schedule_wrapped.
if not pcall(require, "nui.popup") then
	return
end
local ui_env = require("helpers.ui_env")
local fake_provider = require("helpers.fake_provider")
local git_repo = require("helpers.git_repo")
local called = fake_provider.called

--- Find the 1-indexed line in `buf` whose text contains `needle`, or nil.
local function line_with(buf, needle)
	for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line:find(needle, 1, true) then
			return i
		end
	end
	return nil
end

describe("flow: apply / yank suggestion", function()
	local env, fake, uninstall, repo, root, src_buf

	before_each(function()
		env = ui_env.setup()
		repo = git_repo.create({
			files = { ["foo.lua"] = { "aaa", "bbb", "ccc" } },
		})
		-- macOS resolves /var -> /private/var; keep git_root and the buffer path
		-- aligned so apply_suggestion resolves ctx.source_bufnr to the edited file.
		root = vim.fn.resolve(repo.root)
	end)

	after_each(function()
		vim.wait(100, function()
			return false
		end)
		require("pr.drift").invalidate_all()
		if uninstall then
			uninstall()
			uninstall = nil
		end
		env.teardown()
		if repo then
			repo.cleanup()
			repo = nil
		end
	end)

	--- Install the fake with a single thread anchored at foo.lua:2, open the real
	--- file so ctx.source_bufnr resolves to it, mount the layout, wait for render,
	--- and park the cursor on the comment body. Returns (comments_popup, body_line).
	local function mount_with(comment_body, comment_overrides)
		local comment = vim.tbl_extend("force", {
			database_id = 5001,
			author = "alice",
			body = comment_body,
			updated_at = "2026-01-01T00:00:00Z",
			viewer_can_update = true,
			viewer_can_delete = true,
			viewer_can_react = true,
			start_line = 2,
			end_line = 2,
		}, comment_overrides or {})
		local thread = {
			id = "T1",
			is_resolved = false,
			is_outdated = false,
			viewer_can_reply = true,
			comments = { comment },
		}

		fake, uninstall = fake_provider.install("flow_suggestion_fake", {
			git_root = root,
			comments = { ["foo.lua"] = { thread } },
		})

		-- Editing the committed file makes it the current buffer, so
		-- make_comments_layout captures it as source_bufnr.
		vim.cmd.edit(root .. "/foo.lua")
		src_buf = vim.api.nvim_get_current_buf()

		local ui = require("pr.ui")
		local layout, comments_popup = ui.make_comments_layout(thread, "foo.lua")
		layout:mount()

		local body_line
		env.wait_for(function()
			body_line = line_with(comments_popup.bufnr, "How about")
			return body_line ~= nil
		end, 2000, "thread body rendered")

		vim.api.nvim_set_current_win(comments_popup.winid)
		vim.api.nvim_win_set_cursor(comments_popup.winid, { body_line, 0 })
		return comments_popup, body_line
	end

	local function notif_matches(needle)
		for _, n in ipairs(env.notifications) do
			if type(n.msg) == "string" and n.msg:find(needle, 1, true) then
				return true
			end
		end
		return false
	end

	it("a on a comment with a suggestion block replaces the anchored lines in the source buffer", function()
		mount_with("How about this fix:\n```suggestion\nBBB_NEW\n```")

		env.feed("a")

		env.wait_for(function()
			return vim.api.nvim_buf_get_lines(src_buf, 1, 2, false)[1] == "BBB_NEW"
		end, 2000, "anchored source line replaced")

		-- Only line 2 (the anchor) changed; neighbors are untouched.
		assert.same({ "aaa", "BBB_NEW", "ccc" }, vim.api.nvim_buf_get_lines(src_buf, 0, -1, false))
		assert.is_true(notif_matches("Applied suggestion"))
	end)

	it("a on a comment without a suggestion falls through to inline edit (no suggestion.apply)", function()
		local ui = require("pr.ui")
		local suggestion = require("pr.suggestion")

		-- Spy on both handlers: the `a` dispatch must reach inline-edit and never
		-- suggestion.apply. (In headless, the re-fed `a` enters then immediately
		-- leaves insert, so the edit-mode flags are torn down again — asserting the
		-- spy call is robust where asserting the transient pr_edit_comment_id is not.)
		local orig_apply = suggestion.apply
		local apply_calls = 0
		suggestion.apply = function(...)
			apply_calls = apply_calls + 1
			return orig_apply(...)
		end
		local orig_edit = ui._start_inline_edit
		local edit_ids = {}
		ui._start_inline_edit = function(thr, cmt, ctx)
			table.insert(edit_ids, cmt.database_id)
			return orig_edit(thr, cmt, ctx)
		end

		mount_with("How about a plain comment with no fence")

		env.feed("a")

		env.wait_for(function()
			return #edit_ids > 0
		end, 2000, "inline edit engaged via fallback")

		suggestion.apply = orig_apply
		ui._start_inline_edit = orig_edit

		-- Fell through to inline edit on THIS comment, not suggestion.apply.
		assert.same({ 5001 }, edit_ids)
		assert.equals(0, apply_calls)
		-- The non-suggestion `a` never commits an edit either (body unchanged).
		assert.is_nil(called(fake, "edit_comment"))
		-- The source file must be untouched by a non-suggestion `a`.
		assert.same({ "aaa", "bbb", "ccc" }, vim.api.nvim_buf_get_lines(src_buf, 0, -1, false))
	end)

	it('ya yanks the suggestion into + and " registers', function()
		mount_with("How about this fix:\n```suggestion\nBBB_NEW\n```")

		vim.fn.setreg("+", "")
		vim.fn.setreg('"', "")
		env.feed("ya")

		env.wait_for(function()
			return vim.fn.getreg("+") == "BBB_NEW"
		end, 2000, "suggestion yanked to + register")

		assert.equals("BBB_NEW", vim.fn.getreg("+"))
		assert.equals("BBB_NEW", vim.fn.getreg('"'))
		-- Yank must not mutate the source buffer.
		assert.same({ "aaa", "bbb", "ccc" }, vim.api.nvim_buf_get_lines(src_buf, 0, -1, false))
	end)
end)
