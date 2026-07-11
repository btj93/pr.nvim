-- Tier 2 flow spec: drives the reply composer's real <CR> keymap over the fake
-- provider inside the headless ui_env harness. Locks the reply submit flow end
-- to end: focus the reply popup, type a body, press <CR>, and assert the
-- provider `reply` call fired with the anchor comment's database_id + the body,
-- then that the re-render surfaces the new reply in the conversation popup.
--
-- Mirrors tests/ui_env_spec.lua's mount pattern. make_comments_layout now
-- returns (layout, comments_popup, new_reply_popup) so the flow can address the
-- reply buffer/window directly instead of scanning floats.
if not pcall(require, "nui.popup") then
	return
end
local ui_env = require("helpers.ui_env")
local fake_provider = require("helpers.fake_provider")

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

describe("flow: reply submit via <CR>", function()
	local env, fake, uninstall

	before_each(function()
		env = ui_env.setup()
		fake, uninstall = fake_provider.install("flow_reply_fake", {
			comments = {
				["lua/a.lua"] = {
					{
						id = "T1",
						is_resolved = false,
						is_outdated = false,
						viewer_can_reply = true,
						comments = {
							{
								-- The real reply path (ui.lua:558-559) sends the FIRST
								-- comment's database_id, not the thread id. This fixture
								-- pins it to 1001 so the assertion below is exact.
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
					},
				},
			},
		})
	end)

	after_each(function()
		-- A successful reply schedules an async re-fetch + re-render. Drain those
		-- callbacks while the popup buffers are still alive so teardown's buffer
		-- wipe (which triggers nui's auto-unmount) can't race a re-render against
		-- an already-torn-down buffer.
		env.drain()
		uninstall()
		env.teardown()
	end)

	--- Mount the layout for the single fixture thread, wait until the body has
	--- rendered, and return the popup handles.
	local function mount()
		local ui = require("pr.ui")
		local layout, comments_popup, new_reply_popup = ui.make_comments_layout(fake.scenario.comments["lua/a.lua"][1], "lua/a.lua")
		layout:mount()
		env.wait_for(function()
			return line_with(comments_popup.bufnr, "please fix this") ~= nil
		end, 2000, "thread body rendered")
		return layout, comments_popup, new_reply_popup
	end

	it("submits a reply via <CR> and records the provider call", function()
		local _, _, new_reply_popup = mount()

		vim.api.nvim_buf_set_lines(new_reply_popup.bufnr, 0, -1, false, { "my reply body" })
		vim.api.nvim_set_current_win(new_reply_popup.winid)
		env.feed("<CR>")

		env.wait_for(function()
			return fake_provider.called(fake, "reply") ~= nil
		end, 2000, "reply call")

		local call = fake_provider.called(fake, "reply")
		-- ui.lua passes first_comment.database_id (1001) as the first arg, and the
		-- joined composer body as the second.
		assert.equals(1001, call.args[1])
		assert.truthy(tostring(call.args[2]):find("my reply body", 1, true))
	end)

	it("re-renders the thread with the new reply", function()
		local _, comments_popup, new_reply_popup = mount()

		vim.api.nvim_buf_set_lines(new_reply_popup.bufnr, 0, -1, false, { "my reply body" })
		vim.api.nvim_set_current_win(new_reply_popup.winid)
		env.feed("<CR>")

		-- After the reply succeeds the layout re-fetches through the fake (whose
		-- reply mutator appended the new comment) and re-renders into the same
		-- comments buffer, so the reply body must appear there.
		env.wait_for(function()
			return line_with(comments_popup.bufnr, "my reply body") ~= nil
		end, 2000, "reply body re-rendered in conversation")
	end)
end)
