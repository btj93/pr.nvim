-- Tier 2 flow spec: drives the emoji-reaction menu and the <M-d> delete confirm
-- over the fake provider inside the headless ui_env harness.
--
-- Mirrors tests/flow_resolve_spec.lua's mount pattern: the cursor is parked on
-- the comment body line so the per-action dispatcher resolves `under_cursor()`
-- to the fixture comment. The emoji action mounts a nui Menu (not vim.ui.select),
-- so it is driven with real keystrokes (`j` = focus_next, `<CR>` = submit); the
-- delete action's confirmation IS a vim.ui.select, driven by env.select_choice.
--
-- The remove-reaction case pins the bug fixed in this commit: the on_submit
-- remove path must identify the VIEWER's reactor node (login == git.git_user)
-- and pass THAT node's database_id to remove_reaction. The fixture seeds two
-- reactors on the reacted group -- someone else first, the viewer second -- so a
-- regression that matches the wrong node (e.g. the old `reaction.user.login ==
-- M.git_user`, which is `nil == nil` and always matches the first reactor) is
-- caught by asserting the viewer's id, not merely "some" id.
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

describe("flow: emoji reactions + delete", function()
	local env, fake, uninstall

	after_each(function()
		-- A successful react/delete schedules an async re-fetch + re-render.
		-- Drain those callbacks while the popup buffers are still alive so
		-- teardown's buffer wipe (which triggers nui's auto-unmount) can't race a
		-- re-render against an already-torn-down buffer.
		env.drain()
		uninstall()
		env.teardown()
	end)

	--- Build a single thread whose lone comment carries `comment_overrides`
	--- merged over sensible defaults (viewer can react + delete; author "alice").
	local function make_thread(comment_overrides)
		local comment = vim.tbl_extend("force", {
			database_id = 5001,
			author = "alice",
			body = "please fix this",
			updated_at = "2026-01-01T00:00:00Z",
			viewer_can_update = false,
			viewer_can_delete = true,
			viewer_can_react = true,
			start_line = 1,
			end_line = 1,
		}, comment_overrides or {})
		return {
			id = "T1",
			is_resolved = false,
			is_outdated = false,
			viewer_can_reply = true,
			comments = { comment },
		}
	end

	--- Install the fake with `thread`, mount the layout, wait for the body to
	--- render, focus the conversation popup, and park the cursor on the comment
	--- body line. Returns (comments_popup, body_line).
	local function mount_with(thread)
		env = ui_env.setup()
		fake, uninstall = fake_provider.install("flow_delete_react_fake", {
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

		vim.api.nvim_set_current_win(comments_popup.winid)
		vim.api.nvim_win_set_cursor(comments_popup.winid, { body_line, 0 })
		return comments_popup, body_line
	end

	--- Press `e` on the focused comment to open the nui emoji Menu, wait for the
	--- new float, focus it so its buffer-local keymaps receive keys, and return
	--- the menu window handle.
	local function open_emoji_menu(comments_popup, body_line)
		vim.api.nvim_set_current_win(comments_popup.winid)
		vim.api.nvim_win_set_cursor(comments_popup.winid, { body_line, 0 })

		local before = {}
		for _, w in ipairs(env.floats()) do
			before[w] = true
		end

		env.feed("e")

		local menu_win
		env.wait_for(function()
			for _, w in ipairs(env.floats()) do
				if not before[w] then
					menu_win = w
					return true
				end
			end
			return false
		end, 2000, "emoji menu opened")

		vim.api.nvim_set_current_win(menu_win)
		return menu_win
	end

	-- A reaction group the viewer has reacted to. Two reactor nodes: someone
	-- else FIRST, the viewer ("tester", the fake's git_user) SECOND, each with a
	-- distinct databaseId. The remove path must pick the viewer's (777), not the
	-- first node's (111). Node shape matches CommentReactionReactorsNode:
	-- `user` is the login STRING (see providers/interface.lua + github.lua:104),
	-- not a `{ login = ... }` table.
	local function reacted_thumbs_up()
		return {
			{
				content = "THUMBS_UP",
				viewerHasReacted = true,
				reactors = {
					totalCount = 2,
					nodes = {
						{ database_id = 111, content = "THUMBS_UP", user = "alice" },
						{ database_id = 777, content = "THUMBS_UP", user = "tester" },
					},
				},
			},
		}
	end

	it("removing your own reaction calls git.remove_reaction with the reactor databaseId", function()
		local comments_popup, body_line = mount_with(make_thread({ reaction_groups = reacted_thumbs_up() }))

		open_emoji_menu(comments_popup, body_line)
		-- THUMBS_UP is the reacted palette entry and the menu's top row, so submit
		-- the focused item straight away.
		env.feed("<CR>")

		env.wait_for(function()
			return called(fake, "remove_reaction") ~= nil
		end, 2000, "remove_reaction")

		local call = called(fake, "remove_reaction")
		assert.is_not_nil(call)
		-- arg[1] = comment database_id, arg[2] = the VIEWER's reactor id (777),
		-- not the first reactor's (111).
		assert.equals(5001, call.args[1])
		assert.equals(777, call.args[2])
		-- No add on a remove.
		assert.is_nil(called(fake, "add_reaction"))
	end)

	it("adding a reaction calls git.add_reaction with the canonical name", function()
		-- Same reacted-THUMBS_UP fixture; HEART is in the palette but not yet
		-- reacted, so it is the menu's second (unreacted) row.
		local comments_popup, body_line = mount_with(make_thread({ reaction_groups = reacted_thumbs_up() }))

		open_emoji_menu(comments_popup, body_line)
		-- Move off the reacted top row to the HEART row, then submit.
		env.feed("j")
		env.feed("<CR>")

		env.wait_for(function()
			return called(fake, "add_reaction") ~= nil
		end, 2000, "add_reaction")

		local call = called(fake, "add_reaction")
		assert.is_not_nil(call)
		assert.equals(5001, call.args[1])
		-- The canonical content key, not the glyph.
		assert.equals("HEART", call.args[2])
		-- Adding an unreacted emoji must not remove anything.
		assert.is_nil(called(fake, "remove_reaction"))
	end)

	it("<M-d> delete: confirming Yes calls git.delete_comment with the database_id", function()
		local comments_popup, body_line = mount_with(make_thread({ viewer_can_delete = true }))

		-- vim.ui.select is stubbed by ui_env; choose the "Yes" item by predicate.
		env.select_choice = function(item)
			return item == "Yes"
		end

		vim.api.nvim_set_current_win(comments_popup.winid)
		vim.api.nvim_win_set_cursor(comments_popup.winid, { body_line, 0 })
		env.feed("<M-d>")

		env.wait_for(function()
			return called(fake, "delete_comment") ~= nil
		end, 2000, "delete_comment")

		local call = called(fake, "delete_comment")
		assert.is_not_nil(call)
		assert.equals(5001, call.args[1])
	end)

	it("<M-d> delete: declining No makes no git.delete_comment call", function()
		local comments_popup, body_line = mount_with(make_thread({ viewer_can_delete = true }))

		-- Decline: pick "No". ui_env's vim.ui.select stub resolves the choice
		-- synchronously inside the feed, so the delete branch never runs.
		env.select_choice = function(item)
			return item == "No"
		end

		vim.api.nvim_set_current_win(comments_popup.winid)
		vim.api.nvim_win_set_cursor(comments_popup.winid, { body_line, 0 })
		env.feed("<M-d>")

		assert.is_nil(called(fake, "delete_comment"))
	end)
end)
