-- Tier 2 flow spec: drives the visual-selection new-comment composer end to end.
-- The entry point is comment.M.comment (the `:PRComment` handler): it reads the
-- '< / '> visual marks, captures the selected lines, and mounts
-- ui.make_new_comment_layout. From there we exercise the popup's real keymaps:
--   <CR>  -> git.comment(path, start, end, body)
--   <M-s> -> wrap/unwrap the body in a ```suggestion fence
--   <C-r> -> queue via start_pending_review + add_review_comment
--   <C-r> on a locally-inserted (uncommitted) line -> drift-guard abort
--
-- The drift paths run against a REAL git repo (helpers.git_repo): the fake
-- provider's git_root is pointed at the repo root and the buffer edits the
-- committed file, so drift.get_for_buffer shells real `git show HEAD:<path>`.
--
-- Selections stay on interior lines: comment.M.comment captures with
-- nvim_buf_get_text(buf, start-1, 0, end+1, -1), which throws "Index out of
-- bounds" within two lines of EOF (that latent crash is fixed + regression-
-- tested separately). Every post-key assertion gates on env.wait_for because the
-- git.get_git_root / drift callbacks are schedule_wrapped.
if not pcall(require, "nui.popup") then
	return
end
local ui_env = require("helpers.ui_env")
local fake_provider = require("helpers.fake_provider")
local git_repo = require("helpers.git_repo")
local called = fake_provider.called

describe("flow: new comment via visual selection", function()
	local env, fake, uninstall, repo, root

	before_each(function()
		env = ui_env.setup()
		repo = git_repo.create({
			files = { ["foo.lua"] = { "c1", "c2", "c3", "c4", "c5" } },
		})
		-- macOS resolves /var -> /private/var when :edit opens the file, so the
		-- buffer name would not match repo.root. Resolve up front so git_root and
		-- the buffer path agree (relative_path math + drift both depend on it).
		root = vim.fn.resolve(repo.root)
		fake, uninstall = fake_provider.install("flow_new_comment_fake", {
			git_root = root,
		})
	end)

	after_each(function()
		-- A successful submit/queue schedules async provider work + a layout
		-- unmount. Drain those callbacks while buffers are still alive so
		-- teardown's buffer wipe can't race an in-flight callback.
		vim.wait(100, function()
			return false
		end)
		require("pr.drift").invalidate_all()
		uninstall()
		env.teardown()
		if repo then
			repo.cleanup()
			repo = nil
		end
	end)

	--- Find the editable composer float: the modifiable markdown popup created by
	--- make_new_reply_popup (the code-reference popup is read-only + source ft).
	local function find_composer()
		for _, win in ipairs(env.floats()) do
			local buf = vim.api.nvim_win_get_buf(win)
			if vim.bo[buf].modifiable and vim.bo[buf].filetype == "markdown" then
				return win, buf
			end
		end
		return nil, nil
	end

	--- Find a float whose text contains `needle` (e.g. the code-reference popup).
	local function find_float_with(needle)
		for _, win in ipairs(env.floats()) do
			local buf = vim.api.nvim_win_get_buf(win)
			if table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find(needle, 1, true) then
				return win, buf
			end
		end
		return nil, nil
	end

	--- Make a linewise visual selection of buffer lines [s, e] in the current
	--- window, then leave visual mode so '< / '> are set for comment.M.comment.
	local function visual_select(s, e)
		vim.api.nvim_win_set_cursor(0, { s, 0 })
		local motion = s == e and "V" or ("V" .. string.rep("j", e - s))
		env.feed(motion)
		env.feed("<Esc>")
	end

	--- Invoke comment.M.comment and wait until the composer popup is mounted.
	--- Returns (win, buf) of the composer.
	local function open_composer()
		require("pr.comment").comment()
		local win, buf
		env.wait_for(function()
			win, buf = find_composer()
			return buf ~= nil
		end, 2000, "new-comment composer mounted")
		return win, buf
	end

	--- Put `lines` into the composer buffer and return to normal mode so the
	--- normal-mode <CR> / <C-r> maps fire.
	local function set_composer_body(win, buf, lines)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_set_current_win(win)
		env.feed("<Esc>")
	end

	local function notif_matches(needle)
		for _, n in ipairs(env.notifications) do
			if type(n.msg) == "string" and n.msg:find(needle, 1, true) then
				return true
			end
		end
		return false
	end

	it("visual selection -> M.comment -> <CR> submits git.comment with path and line range", function()
		vim.cmd.edit(root .. "/foo.lua")
		visual_select(2, 2)
		local win, buf = open_composer()

		-- The code-reference popup mirrors the selected source line.
		assert.is_not_nil((find_float_with("c2")))

		set_composer_body(win, buf, { "please rename this" })
		env.feed("<CR>")

		env.wait_for(function()
			return called(fake, "comment") ~= nil
		end, 2000, "git.comment call")

		local call = called(fake, "comment")
		assert.equals("foo.lua", call.args[1])
		assert.equals(2, call.args[2])
		assert.equals(2, call.args[3])
		assert.truthy(tostring(call.args[4]):find("please rename this", 1, true))
		-- The <CR> submit path is not the queue-as-review path.
		assert.is_nil(called(fake, "start_pending_review"))
	end)

	it("<M-s> wraps the popup body in a suggestion fence and unwraps on second press", function()
		vim.cmd.edit(root .. "/foo.lua")
		visual_select(2, 2)
		local win, buf = open_composer()

		set_composer_body(win, buf, { "hello", "world" })

		env.feed("<M-s>")
		env.wait_for(function()
			return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "```suggestion"
		end, 2000, "body wrapped as suggestion")
		assert.same({ "```suggestion", "hello", "world", "```" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

		env.feed("<M-s>")
		env.wait_for(function()
			return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "hello"
		end, 2000, "body unwrapped")
		assert.same({ "hello", "world" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

		-- Toggling the fence must never touch the provider.
		assert.is_nil(called(fake, "comment"))
	end)

	it("<C-r> queues via start_pending_review + add_review_comment instead of git.comment", function()
		vim.cmd.edit(root .. "/foo.lua")
		visual_select(2, 2)
		local win, buf = open_composer()

		set_composer_body(win, buf, { "queue this note" })
		env.feed("<C-r>")

		env.wait_for(function()
			return called(fake, "add_review_comment") ~= nil
		end, 2000, "add_review_comment call")

		assert.is_not_nil(called(fake, "start_pending_review"))
		local call = called(fake, "add_review_comment")
		assert.equals("foo.lua", call.args[2])
		assert.equals(2, call.args[3])
		assert.equals(2, call.args[4])
		assert.truthy(tostring(call.args[5]):find("queue this note", 1, true))
		-- Queue-as-review must not fall through to the direct-comment path.
		assert.is_nil(called(fake, "comment"))
	end)

	it("<C-r> on a line missing from the committed diff aborts with the drift-guard notification", function()
		vim.cmd.edit(root .. "/foo.lua")
		-- Insert an uncommitted line after committed line 2. Buffer line 3 ("NEW")
		-- has no counterpart at HEAD, so buffer_to_commit(3) returns nil.
		vim.api.nvim_buf_set_lines(0, 2, 2, false, { "NEW" })
		visual_select(3, 3)
		local win, buf = open_composer()

		set_composer_body(win, buf, { "comment on uncommitted line" })
		env.feed("<C-r>")

		env.wait_for(function()
			return notif_matches("not in the PR's committed diff")
		end, 2000, "drift-guard abort notification")

		-- The abort happens before any review is started, and never posts.
		assert.is_nil(called(fake, "start_pending_review"))
		assert.is_nil(called(fake, "add_review_comment"))
		assert.is_nil(called(fake, "comment"))
	end)

	it("no user-visible TODO notifications occur in any exercised flow", function()
		-- Exercise a representative composer flow (the live draft-save + submit
		-- path that neighbors the removed dead branch), then assert nothing
		-- surfaced a stray "TODO" notification.
		vim.cmd.edit(root .. "/foo.lua")
		visual_select(2, 2)
		local win, buf = open_composer()

		set_composer_body(win, buf, { "some feedback" })
		env.feed("<M-s>")
		env.feed("<M-s>")
		env.feed("<CR>")

		env.wait_for(function()
			return called(fake, "comment") ~= nil
		end, 2000, "git.comment call")

		for _, n in ipairs(env.notifications) do
			assert.is_nil(tostring(n.msg):find("TODO", 1, true))
		end
	end)

	it("commenting on the last line of the file opens the composer (regression: near-EOF capture)", function()
		-- Regression for the fixed off-by-two in comment.M.comment's line capture:
		-- nvim_buf_get_text(..., end_line + 1, ...) threw "Index out of bounds"
		-- for any selection within two lines of EOF, so :PRComment on the last
		-- line never opened a popup. Select the final line and assert the composer
		-- mounts and the code reference shows exactly that line.
		vim.cmd.edit(root .. "/foo.lua")
		visual_select(5, 5)
		local win, buf = open_composer()

		assert.is_not_nil(win)
		assert.is_not_nil((find_float_with("c5")))

		set_composer_body(win, buf, { "comment on the last line" })
		env.feed("<CR>")

		env.wait_for(function()
			return called(fake, "comment") ~= nil
		end, 2000, "git.comment call for EOF selection")

		local call = called(fake, "comment")
		assert.equals("foo.lua", call.args[1])
		assert.equals(5, call.args[2])
		assert.equals(5, call.args[3])
	end)
end)
