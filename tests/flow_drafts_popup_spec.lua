-- Tier 2 flow spec: the drafts persistence lifecycle as seen through the real
-- popups. drafts.lua is unit-tested in isolation elsewhere (drafts_spec.lua);
-- this spec locks the UI wiring that feeds it:
--   * reply drafts saved by the reply composer's on_lines watcher pre-fill on
--     reopen (ui.make_comments_layout).
--   * an edit draft is dropped when the comment's updated_at moved on remotely
--     (ui.make_comment_popup, the updated_at-mismatch guard).
--   * new-comment drafts keyed "<path>:<start>:<end>" survive close + pre-fill
--     (ui.make_new_comment_layout).
--   * the PRDraftsFlush augroup (init.lua) flushes the debounced write to disk
--     on VimLeavePre.
--
-- ui_env redirects drafts to a temp file per setup (drafts._set_path), so every
-- case here works against that isolated path (the debounce cache lives in the
-- same module instance across mount/unmount within one test).
if not pcall(require, "nui.popup") then
	return
end
local ui_env = require("helpers.ui_env")
local fake_provider = require("helpers.fake_provider")

--- Find the 1-indexed line in `buf` whose text contains `needle`, or nil.
local function line_with(buf, needle)
	for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line:find(needle, 1, true) then
			return i
		end
	end
	return nil
end

--- The editable composer float: the modifiable markdown popup created by
--- make_new_reply_popup (the code-reference popup is read-only + source ft).
local function find_composer(env)
	for _, win in ipairs(env.floats()) do
		local buf = vim.api.nvim_win_get_buf(win)
		if vim.bo[buf].modifiable and vim.bo[buf].filetype == "markdown" then
			return win, buf
		end
	end
	return nil, nil
end

describe("flow: drafts popup lifecycle", function()
	local env, fake, uninstall

	before_each(function()
		env = ui_env.setup()
		fake, uninstall = fake_provider.install("flow_drafts_fake", {
			comments = {
				["lua/a.lua"] = {
					{
						id = "T1",
						is_resolved = false,
						is_outdated = false,
						viewer_can_reply = true,
						viewer_can_resolve = true,
						viewer_can_unresolve = false,
						comments = {
							{
								database_id = 1001,
								author = "alice",
								body = "please fix this",
								updated_at = "2026-01-01T00:00:00Z",
								viewer_can_update = false,
								viewer_can_delete = false,
								viewer_can_react = false,
								start_line = 1,
								end_line = 1,
							},
						},
					},
				},
			},
		})
	end)

	after_each(function()
		-- Drain any scheduled callbacks while buffers are still alive so teardown's
		-- buffer wipe can't race an in-flight re-render.
		env.drain()
		uninstall()
		env.teardown()
	end)

	it("reply draft saved on typing is pre-filled when the popup reopens", function()
		local ui = require("pr.ui")
		local drafts = require("pr.drafts")
		local thread = fake.scenario.comments["lua/a.lua"][1]

		-- First open: type into the reply composer. The composer's on_lines watcher
		-- persists to reply_drafts keyed by thread.id ("T1").
		local layout, _, new_reply_popup = ui.make_comments_layout(thread, "lua/a.lua")
		layout:mount()
		vim.api.nvim_buf_set_lines(new_reply_popup.bufnr, 0, -1, false, { "half-written reply" })

		env.wait_for(function()
			local r = drafts.get_reply("T1")
			return r ~= nil and r.body ~= nil and r.body:find("half-written reply", 1, true) ~= nil
		end, 2000, "reply draft persisted")

		layout:unmount()

		-- Reopen the same thread: the composer must pre-fill from the saved draft.
		local layout2, _, new_reply_popup2 = ui.make_comments_layout(thread, "lua/a.lua")
		layout2:mount()
		env.wait_for(function()
			return line_with(new_reply_popup2.bufnr, "half-written reply") ~= nil
		end, 2000, "reply draft pre-filled on reopen")
		layout2:unmount()
	end)

	it("edit draft is dropped when the comment's updated_at changed remotely", function()
		local ui = require("pr.ui")
		local drafts = require("pr.drafts")

		-- Seed a stale edit draft: its updated_at predates the comment's current
		-- updated_at, so the popup must discard it rather than restore stale text.
		drafts.save_edit(1001, { body = "STALE draft body", updated_at = "2020-01-01T00:00:00Z" })
		assert.is_not_nil(drafts.get_edit(1001))

		local thread = {
			id = "T1",
			is_resolved = false,
			viewer_can_resolve = true,
			viewer_can_unresolve = false,
			viewer_can_reply = true,
		}
		local comment = {
			database_id = 1001,
			author = "alice",
			body = "current upstream body",
			updated_at = "2026-07-11T00:00:00Z", -- moved on since the draft was saved
			viewer_can_update = true,
			viewer_can_delete = false,
			viewer_can_react = false,
			start_line = 1,
			end_line = 1,
			reaction_groups = {},
		}

		-- Building the popup runs the updated_at-mismatch guard synchronously.
		local popup = ui.make_comment_popup(thread, comment, nil, false)

		-- The stale draft is dropped...
		assert.is_nil(drafts.get_edit(1001), "stale edit draft must be dropped")
		-- ...and the popup shows the live comment body, not the discarded draft.
		local body = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)
		assert.equals("current upstream body", body[1])
		assert.is_nil(line_with(popup.bufnr, "STALE draft body"), "discarded draft text must not render")
	end)

	it("new-comment draft keyed by path:start:end survives popup close and pre-fills", function()
		local ui = require("pr.ui")
		local drafts = require("pr.drafts")
		local key = "lua/a.lua:3:5"

		-- First open: type into the composer. on_lines persists to new_drafts[key].
		local layout = ui.make_new_comment_layout({ "local x = 1" }, "lua", "lua/a.lua", 3, 5)
		layout:mount()

		local _, buf
		env.wait_for(function()
			_, buf = find_composer(env)
			return buf ~= nil
		end, 2000, "new-comment composer mounted")

		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "draft new comment text" })
		env.wait_for(function()
			local d = drafts.get_new(key)
			return d ~= nil and d.body ~= nil and d.body:find("draft new comment text", 1, true) ~= nil
		end, 2000, "new-comment draft persisted under path:start:end key")

		layout:unmount()

		-- Reopen the composer for the same path + anchor range: it pre-fills from
		-- the persisted draft.
		local layout2 = ui.make_new_comment_layout({ "local x = 1" }, "lua", "lua/a.lua", 3, 5)
		layout2:mount()
		local buf2
		env.wait_for(function()
			_, buf2 = find_composer(env)
			return buf2 ~= nil and line_with(buf2, "draft new comment text") ~= nil
		end, 2000, "new-comment draft pre-filled on reopen")
		layout2:unmount()
	end)
end)

describe("flow: drafts VimLeavePre flush", function()
	local env, uninstall, _
	local PLUGIN_ROOT = vim.fn.getcwd()

	before_each(function()
		vim.cmd.cd(PLUGIN_ROOT)
		env = ui_env.setup()
		_, uninstall = fake_provider.install("flow_drafts_flush_fake", {})
		-- Fresh internal state (timer handle, seeded branch) per test.
		package.loaded["pr"] = nil
	end)

	after_each(function()
		pcall(function()
			require("pr").set_refresh_interval(0)
		end)
		for _, g in ipairs({
			"PRColorScheme",
			"PRDraftsFlush",
			"PRWinbar",
			"PRAutoRefresh",
			"PRHeadChange",
			"PRComment",
			"PRHunk",
		}) do
			pcall(vim.api.nvim_del_augroup_by_name, g)
		end
		uninstall()
		env.teardown()
	end)

	it("VimLeavePre autocmd flushes pending debounced writes to disk", function()
		local drafts = require("pr.drafts")
		-- Re-point to a path we control so we can read the file back.
		local p = vim.fn.tempname()
		drafts._set_path(p)

		local pr = require("pr")
		pr.setup({
			run_on_start = { comments = false, hunks = false },
			auto_refresh = { interval = 0, on_branch_change = false, on_head_change = false },
		})

		drafts.save_reply("THREAD_FLUSH", { body = "unsaved keystrokes", updated_at = "t" })

		-- The disk write is debounced (1s); with no event-loop spin it can't have
		-- landed yet, so the file must not exist.
		assert.equals(0, vim.fn.filereadable(p), "debounced write must not have hit disk yet")

		-- Fire the real PRDraftsFlush augroup callback.
		vim.api.nvim_exec_autocmds("VimLeavePre", {})

		-- flush() writes synchronously, so the file is present immediately.
		assert.equals(1, vim.fn.filereadable(p), "VimLeavePre must flush the draft to disk")
		local data = vim.fn.json_decode(table.concat(vim.fn.readfile(p), "\n"))
		assert.equals("unsaved keystrokes", data.reply_drafts["THREAD_FLUSH"].body)
	end)
end)
