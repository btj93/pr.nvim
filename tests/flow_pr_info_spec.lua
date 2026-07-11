-- Tier 2 flow spec: drives :PRInfo's view render and edit-submit flow over the
-- fake provider inside the headless ui_env harness, plus a pure contract check
-- that pr_info._conflict_decision mirrors ui._conflict_decision exactly.
--
-- pr_info.show mounts nui layouts through schedule_wrapped provider callbacks, so
-- post-show assertions are predicate-gated. The edit path is bound with <C-s>;
-- the conflict path re-fetches metadata and routes an updated_at mismatch through
-- vim.fn.confirm (stubbed by ui_env). Covers render, edit submit, every conflict
-- branch (overwrite/refresh/abort), and empty title/body rejection.
if not pcall(require, "nui.popup") then
	return
end
local ui_env = require("helpers.ui_env")
local fake_provider = require("helpers.fake_provider")
local called = fake_provider.called

local function base_metadata()
	return {
		number = 42,
		title = "feat: add drift translation",
		state = "open",
		author = "alice",
		base_ref = "main",
		head_ref = "feature/drift",
		body = "## Summary\nTranslate line numbers across HEAD and buffer.",
		labels = { "enhancement", "needs-review" },
		reviewers = { { user = "bob", state = "APPROVED" } },
		assignees = { "carol" },
		url = "https://example.test/pr/42",
		updated_at = "2026-07-01T00:00:00Z",
	}
end

local function base_checks()
	return {
		{ name = "test", status = "completed", conclusion = "success", url = "https://ci/test" },
		{ name = "lint", status = "in_progress", conclusion = nil, url = "https://ci/lint" },
	}
end

local function buf_text(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function has_notification(env, needle)
	for _, n in ipairs(env.notifications) do
		if type(n.msg) == "string" and n.msg:find(needle, 1, true) then
			return true
		end
	end
	return false
end

-- nui renders each popup's border as its own floating window, so env.floats()
-- also surfaces borderless helper windows with no keymaps. The real editor
-- popups are the ones carrying our normal-mode maps; the body editor is markdown,
-- the single-line title editor is not. The read view is a lone markdown popup.
local function has_maps(buf)
	return #vim.api.nvim_buf_get_keymap(buf, "n") > 0
end

local function markdown_win(env)
	for _, win in ipairs(env.floats()) do
		local buf = vim.api.nvim_win_get_buf(win)
		if vim.bo[buf].filetype == "markdown" then
			return win, buf
		end
	end
end

local function edit_body_win(env)
	return markdown_win(env)
end

local function edit_title_win(env)
	for _, win in ipairs(env.floats()) do
		local buf = vim.api.nvim_win_get_buf(win)
		if vim.bo[buf].filetype ~= "markdown" and has_maps(buf) then
			return win, buf
		end
	end
end

local function close_floats(env)
	for _, win in ipairs(env.floats()) do
		pcall(vim.api.nvim_win_close, win, true)
	end
end

describe("flow: :PRInfo view / edit", function()
	local env, fake, uninstall

	before_each(function()
		env = ui_env.setup()
		fake, uninstall = fake_provider.install("flow_pr_info_fake", {
			pr_metadata = base_metadata(),
			checks = base_checks(),
		})
	end)

	after_each(function()
		-- Drain scheduled metadata/checks callbacks before teardown wipes buffers.
		env.drain()
		uninstall()
		env.teardown()
	end)

	it("pr_info._conflict_decision matches ui._conflict_decision's contract for all 4 outcomes", function()
		local pr_info = require("pr.pr_info")
		local ui = require("pr.ui")
		-- fresh, snapshot, confirm_choice, expected
		local cases = {
			{ nil, "t1", 0, "proceed" },
			{ nil, "t1", 1, "proceed" },
			{ { updated_at = "t1" }, "t1", 3, "proceed" },
			{ { updated_at = "t2" }, "t1", 1, "overwrite" },
			{ { updated_at = "t2" }, "t1", 2, "refresh" },
			{ { updated_at = "t2" }, "t1", 3, "abort" },
			{ { updated_at = "t2" }, "t1", 0, "abort" },
		}
		local seen = {}
		for _, tc in ipairs(cases) do
			local got = pr_info._conflict_decision(tc[1], tc[2], tc[3])
			assert.equals(tc[4], got)
			-- Byte-for-byte agreement with the ui-layer helper it mirrors.
			assert.equals(ui._conflict_decision(tc[1], tc[2], tc[3]), got)
			seen[got] = true
		end
		assert.is_true(seen.proceed)
		assert.is_true(seen.overwrite)
		assert.is_true(seen.refresh)
		assert.is_true(seen.abort)
	end)

	it(":PRInfo renders title/state/checks from fake metadata", function()
		require("pr.pr_info").show()

		env.wait_for(function()
			local _, buf = markdown_win(env)
			return buf ~= nil and buf_text(buf):find("feat: add drift", 1, true) ~= nil
		end, 2000, "pr info rendered")

		local _, view_buf = markdown_win(env)
		local text = buf_text(view_buf)
		assert.matches("PR #42", text)
		assert.matches("feat: add drift translation", text)
		assert.matches("open", text) -- state, in the "wants to merge … · open" line
		assert.matches("test", text) -- check name
		assert.matches("lint", text) -- check name
	end)

	it("edit submit calls update_pr_metadata with changed fields", function()
		require("pr.pr_info").show("edit")

		env.wait_for(function()
			return edit_body_win(env) ~= nil and edit_title_win(env) ~= nil
		end, 2000, "edit layout mounted")

		local title_win, title_buf = edit_title_win(env)
		local _, body_buf = edit_body_win(env)
		vim.api.nvim_buf_set_lines(title_buf, 0, -1, false, { "feat: renamed title" })
		vim.api.nvim_buf_set_lines(body_buf, 0, -1, false, { "Rewritten body content." })
		vim.api.nvim_set_current_win(title_win)
		env.feed("<C-s>")

		env.wait_for(function()
			return called(fake, "update_pr_metadata") ~= nil
		end, 2000, "update_pr_metadata call")

		local fields = called(fake, "update_pr_metadata").args[1]
		assert.equals("feat: renamed title", fields.title)
		assert.matches("Rewritten body content", fields.body)
	end)

	it("remote updated_at change routes through the confirm prompt (each branch)", function()
		-- Open edit mode, simulate a remote metadata edit landing afterwards, then
		-- drive <C-s> so open_edit re-fetches, detects the mismatch, and prompts.
		-- Returns a getter for whether the confirm prompt was actually shown.
		local function run_branch(choice)
			fake.scenario.pr_metadata = base_metadata()
			require("pr.pr_info").show("edit")
			env.wait_for(function()
				return edit_body_win(env) ~= nil and edit_title_win(env) ~= nil
			end, 2000, "edit layout mounted")

			local title_win, title_buf = edit_title_win(env)
			local _, body_buf = edit_body_win(env)
			vim.api.nvim_buf_set_lines(title_buf, 0, -1, false, { "conflicting title" })
			vim.api.nvim_buf_set_lines(body_buf, 0, -1, false, { "conflicting body" })
			-- Remote edit: the re-fetch on submit will observe a newer updated_at
			-- than the snapshot open_edit captured on entry.
			fake.scenario.pr_metadata.updated_at = "2026-09-09T00:00:00Z"

			local confirm_seen = false
			vim.fn.confirm = function()
				confirm_seen = true
				return choice
			end
			vim.api.nvim_set_current_win(title_win)
			env.feed("<C-s>")
			return function()
				return confirm_seen
			end
		end

		-- Overwrite (choice 1) proceeds to update_pr_metadata.
		local seen = run_branch(1)
		env.wait_for(function()
			return called(fake, "update_pr_metadata") ~= nil
		end, 2000, "overwrite updates")
		assert.is_true(seen())

		fake.calls = {}
		vim.wait(50, function()
			return false
		end)
		close_floats(env)

		-- Refresh (choice 2) re-opens the read view (get_checks) and does not update.
		seen = run_branch(2)
		env.wait_for(function()
			return called(fake, "get_checks") ~= nil
		end, 2000, "refresh re-opens view")
		assert.is_true(seen())
		assert.is_nil(called(fake, "update_pr_metadata"))

		fake.calls = {}
		vim.wait(50, function()
			return false
		end)
		close_floats(env)

		-- Abort (choice 3) prompts but performs no update and no view refresh.
		seen = run_branch(3)
		env.wait_for(function()
			return seen()
		end, 2000, "abort confirm shown")
		vim.wait(100, function()
			return called(fake, "update_pr_metadata") ~= nil
		end)
		assert.is_nil(called(fake, "update_pr_metadata"))
		assert.is_nil(called(fake, "get_checks"))
	end)

	it("empty title or body is rejected, popup stays open", function()
		require("pr.pr_info").show("edit")
		env.wait_for(function()
			return edit_body_win(env) ~= nil and edit_title_win(env) ~= nil
		end, 2000, "edit layout mounted")

		local title_win, title_buf = edit_title_win(env)
		local _, body_buf = edit_body_win(env)

		-- Empty title -> rejected.
		vim.api.nvim_buf_set_lines(title_buf, 0, -1, false, { "" })
		vim.api.nvim_buf_set_lines(body_buf, 0, -1, false, { "some body" })
		vim.api.nvim_set_current_win(title_win)
		env.feed("<C-s>")
		env.wait_for(function()
			return has_notification(env, "Title is empty")
		end, 2000, "empty title rejected")
		assert.is_nil(called(fake, "update_pr_metadata"))
		assert.is_true(#env.floats() > 0)

		-- Empty body -> rejected too; the layout is still open from above.
		vim.api.nvim_buf_set_lines(title_buf, 0, -1, false, { "a valid title" })
		vim.api.nvim_buf_set_lines(body_buf, 0, -1, false, { "" })
		vim.api.nvim_set_current_win(title_win)
		env.feed("<C-s>")
		env.wait_for(function()
			return has_notification(env, "Body is empty")
		end, 2000, "empty body rejected")
		assert.is_nil(called(fake, "update_pr_metadata"))
		assert.is_true(#env.floats() > 0)
	end)
end)
