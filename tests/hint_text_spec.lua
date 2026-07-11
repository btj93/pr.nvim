-- Unit spec for the exported ui._compute_hint_text: the pure function that joins
-- each bound action's `popup_hint` into the single virt_text hint line shown
-- under the focused comment. It composes over M.actions, filtering by
--   action.mode == mode  AND  action.show_hint  AND  action.can_perform(...)
-- so this spec pins that composition without mounting any popup.
--
-- No nui is required (pr.ui loads its nui deps via safe_require, and the pure
-- helpers here never touch them). A fake provider is installed so the provider
-- proxy resolves deterministically for the few can_perform closures that read
-- provider fields (git.thread_url for the URL actions, git.reaction_palette for
-- emoji).
local fake_provider = require("helpers.fake_provider")

describe("ui._compute_hint_text", function()
	local ui, uninstall, _

	-- A plain user-authored comment on an unresolved, replyable thread the viewer
	-- can neither delete nor react to, with no ```suggestion fence. That pins the
	-- can_perform-true set to exactly resolve + reply + quit (see below).
	local function fixtures()
		local thread = {
			id = "T1",
			is_resolved = false,
			viewer_can_resolve = true,
			viewer_can_unresolve = false,
			viewer_can_reply = true,
		}
		local comment = {
			database_id = 1,
			author = "alice",
			body = "just a plain comment with no suggestion",
			updated_at = "t0",
			viewer_can_update = false,
			viewer_can_delete = false,
			viewer_can_react = false,
			start_line = 1,
			end_line = 1,
			reaction_groups = {},
		}
		return thread, comment
	end

	before_each(function()
		_, uninstall = fake_provider.install("hint_text_fake", {})
		ui = require("pr.ui")
	end)

	after_each(function()
		uninstall()
	end)

	it("hints include only can_perform-true actions with show_hint", function()
		local thread, comment = fixtures()
		local hint = ui._compute_hint_text(thread, comment, "n")

		-- Included: the normal-mode, show_hint actions whose can_perform is true
		-- for this fixture.
		assert.truthy(hint:find("[R]esolve", 1, true), "resolve should show (unresolved + can resolve)")
		assert.truthy(hint:find("[C]omment", 1, true), "reply should show (viewer_can_reply)")
		assert.truthy(hint:find("[Q]uit", 1, true), "quit always shows")

		-- Excluded because can_perform is false for this fixture.
		assert.is_nil(hint:find("Un[R]esolve", 1, true), "unresolve hidden on an unresolved thread")
		assert.is_nil(hint:find("<M-d>elete", 1, true), "delete hidden when viewer_can_delete=false")
		assert.is_nil(hint:find("[E]moji", 1, true), "emoji hidden when viewer_can_react=false")
		assert.is_nil(hint:find("apply suggestion", 1, true), "apply hidden with no suggestion fence")
		assert.is_nil(hint:find("yank suggestion", 1, true), "yank-suggestion hidden with no suggestion fence")

		-- Excluded because show_hint=false regardless of can_perform.
		assert.is_nil(hint:find("[S]ave edited", 1, true), "save is show_hint=false")

		-- Format: the line is padded with a leading/trailing space and joined by
		-- " | " (three parts → two separators).
		assert.equals(" ", hint:sub(1, 1))
		assert.equals(" ", hint:sub(-1))
		assert.truthy(hint:find(" | ", 1, true), "parts are joined with ' | '")
	end)

	it("url actions contribute no hint (show_hint = false per project convention)", function()
		local thread, comment = fixtures()

		-- The URL actions exist with real hint text, and their can_perform WOULD be
		-- true here (thread_url is a function on the installed provider)...
		assert.is_false(ui.actions.yank_url.show_hint)
		assert.is_false(ui.actions.open_url.show_hint)
		assert.is_true(ui.actions.yank_url.can_perform(thread, comment))
		assert.is_true(ui.actions.open_url.can_perform(thread, comment))

		-- ...yet neither contributes to the hint line, because show_hint gates them
		-- out ahead of can_perform.
		local hint = ui._compute_hint_text(thread, comment, "n")
		assert.is_nil(hint:find("yank URL", 1, true), "yank_url must not appear")
		assert.is_nil(hint:find("open in browser", 1, true), "open_url must not appear")
	end)

	it("insert mode yields the insert-mode hint set", function()
		local thread, comment = fixtures()

		local n_hint = ui._compute_hint_text(thread, comment, "n")
		local i_hint = ui._compute_hint_text(thread, comment, "i")

		-- Normal mode has bound, show_hint actions.
		assert.is_true(#n_hint > 0, "normal mode has hints")

		-- No action in M.actions binds insert mode (every entry is mode "n", "v",
		-- or nil), so the insert-mode hint set is empty. This pins the mode filter:
		-- change the mode gate and this asserts against the regression.
		assert.equals("", i_hint)
	end)
end)
