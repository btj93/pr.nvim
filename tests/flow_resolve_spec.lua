-- Tier 2 flow spec: drives the resolve/unresolve `r` keymap over the fake
-- provider inside the headless ui_env harness. Both `it`s press the SAME key
-- `r`; which action fires is decided by the resolve/unresolve can_perform
-- collision gate (resolve fires on open threads, unresolve on resolved ones).
--
-- Mirrors tests/ui_env_spec.lua's mount pattern. The fixtures differ only in
-- their resolved state + viewer permissions so the collision gate has exactly
-- one applicable action per thread.
if not pcall(require, "nui.popup") then
	return
end
local ui_env = require("helpers.ui_env")
local fake_provider = require("helpers.fake_provider")
local called = fake_provider.called

--- Find the 1-indexed line in `buf` whose text contains `needle`, or nil.
local function line_with(buf, needle)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for i, line in ipairs(lines) do
		if line:find(needle, 1, true) then
			return i
		end
	end
	return nil
end

describe("flow: resolve / unresolve via r", function()
	local env, fake, uninstall

	after_each(function()
		-- A successful resolve/unresolve schedules an async re-fetch + re-render.
		-- Drain those callbacks while the popup buffers are still alive so
		-- teardown's buffer wipe (which triggers nui's auto-unmount) can't race a
		-- re-render against an already-torn-down buffer.
		env.drain()
		uninstall()
		env.teardown()
	end)

	--- Install the fake with a single thread carrying `thread_overrides`, mount
	--- the layout, wait for the body to render, and park the cursor on the
	--- comment body line so the `r` dispatch has a comment under the cursor.
	local function mount_with(thread_overrides)
		env = ui_env.setup()
		local thread = vim.tbl_extend("force", {
			id = "T1",
			is_outdated = false,
			viewer_can_reply = true,
			comments = {
				{
					database_id = 1001,
					author = "alice",
					body = "please fix this",
					updated_at = "2026-01-01T00:00:00Z",
					viewer_can_update = false,
					viewer_can_delete = false,
					viewer_can_react = true,
					start_line = 1,
					end_line = 1,
				},
			},
		}, thread_overrides)
		fake, uninstall = fake_provider.install("flow_resolve_fake", {
			comments = { ["lua/a.lua"] = { thread } },
		})

		local ui = require("pr.ui")
		local layout, comments_popup = ui.make_comments_layout(fake.scenario.comments["lua/a.lua"][1], "lua/a.lua")
		layout:mount()

		local body_line
		env.wait_for(function()
			body_line = line_with(comments_popup.bufnr, "please fix this")
			return body_line ~= nil
		end, 2000, "thread body rendered")

		-- Focus the conversation popup and place the cursor on the body line so
		-- under_cursor() resolves to the fixture comment when `r` dispatches.
		vim.api.nvim_set_current_win(comments_popup.winid)
		vim.api.nvim_win_set_cursor(comments_popup.winid, { body_line, 0 })
		return comments_popup
	end

	it("r on an unresolved thread calls resolve_thread", function()
		mount_with({ is_resolved = false, viewer_can_resolve = true, viewer_can_unresolve = true })

		env.feed("r")

		env.wait_for(function()
			return called(fake, "resolve_thread") ~= nil
		end, 2000, "resolve")
		assert.is_nil(called(fake, "unresolve_thread"))
		assert.equals("T1", called(fake, "resolve_thread").args[1])
	end)

	it("r on a resolved thread calls unresolve_thread (can_perform collision gate)", function()
		mount_with({ is_resolved = true, viewer_can_resolve = true, viewer_can_unresolve = true, resolved_by = "alice" })

		env.feed("r")

		env.wait_for(function()
			return called(fake, "unresolve_thread") ~= nil
		end, 2000, "unresolve")
		assert.is_nil(called(fake, "resolve_thread"))
		assert.equals("T1", called(fake, "unresolve_thread").args[1])
	end)

	it("firing a deferred re-fetch after the popup unmounts does not crash refresh_thread", function()
		-- Regression: refresh_thread's scheduled get_comments callback guards on
		-- vim.api.nvim_buf_is_valid(comments_popup.bufnr). nui's unmount() sets
		-- bufnr = nil, and nvim_buf_is_valid(nil) is a type error. This exercises
		-- the post-unmount race: resolve schedules refresh_thread, we unmount, then
		-- the re-fetch fires against a dead popup buffer.
		local comments_popup = mount_with({ is_resolved = false, viewer_can_resolve = true, viewer_can_unresolve = true })

		-- Capture the re-fetch that refresh_thread triggers so we can unmount first.
		fake.deferred.get_comments = true

		env.feed("r")
		env.wait_for(function()
			return #fake._captured > 0
		end, 2000, "refresh_thread captured get_comments")

		-- Quit the layout; nui nils out comments_popup.bufnr on unmount.
		env.feed("q")
		env.wait_for(function()
			return comments_popup.bufnr == nil or not vim.api.nvim_buf_is_valid(comments_popup.bufnr)
		end, 2000, "popup unmounted")

		-- Fire the deferred re-fetch: the scheduled callback runs with a dead
		-- popup. vim.v.errmsg captures errors raised inside vim.schedule_wrap.
		vim.v.errmsg = ""
		fake.fire("get_comments")
		env.drain()
		assert.equals("", vim.v.errmsg, "refresh_thread crashed after unmount: " .. vim.v.errmsg)
	end)
end)
