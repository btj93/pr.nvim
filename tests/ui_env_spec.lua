-- Exemplar mount-based flow spec: drives make_comments_layout over the fake
-- provider inside the headless ui_env harness. Every future flow spec copies
-- this shape (setup -> install fake -> mount -> wait_for render -> feed keys ->
-- assert -> teardown).
if not pcall(require, "nui.popup") then
	return
end
local ui_env = require("helpers.ui_env")
local fake_provider = require("helpers.fake_provider")

-- make_comments_layout returns `layout, comments_popup, new_reply_popup`, but
-- this exemplar deliberately locates the comments popup buffer by scanning open
-- floats for the rendered body text (rather than the returned handle) to model
-- the float-scanning pattern other flow specs reuse.
local function find_float_with(env, needle)
	for _, win in ipairs(env.floats()) do
		local buf = vim.api.nvim_win_get_buf(win)
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		if table.concat(lines, "\n"):find(needle, 1, true) then
			return win, buf
		end
	end
	return nil, nil
end

describe("ui_env + make_comments_layout", function()
	local env, fake, uninstall

	before_each(function()
		env = ui_env.setup()
		fake, uninstall = fake_provider.install("ui_env_fake", {
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
								body = "first comment",
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
		uninstall()
		env.teardown()
	end)

	it("mounts, renders the thread body, and quits with q", function()
		local ui = require("pr.ui")
		local layout = ui.make_comments_layout(fake.scenario.comments["lua/a.lua"][1], "lua/a.lua")
		layout:mount()

		local body_win
		env.wait_for(function()
			body_win = (find_float_with(env, "first comment"))
			return body_win ~= nil
		end, 2000, "thread body rendered")

		assert.is_true(#env.floats() > 0)

		vim.api.nvim_set_current_win(body_win)
		env.feed("q")

		env.wait_for(function()
			return #env.floats() == 0
		end, 2000, "floats closed after q")
	end)
end)
