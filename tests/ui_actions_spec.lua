-- Tests for lua/pr/ui.lua's M.actions table.
--
-- The actions table is the single source of truth for the keybindings exposed
-- by the unified comments popup, and `can_perform` is what gates each binding.
-- A regression here silently breaks popup shortcuts, so this spec covers the
-- full matrix: every action, every branch of its can_perform predicate, plus
-- the static contract fields (mode, key, show_hint) that consumers rely on.
--
-- The provider is access-time-resolved via the proxy in lua/pr/provider.lua, so
-- we install a fake provider into `package.loaded` and flip `config.opts.provider`
-- to it. Each test case can override `git.reaction_palette` / `git.thread_url`
-- by mutating the fake module table — no need to re-require pr.ui.

local config = require("pr.config")
config.opts = config.opts or {}

-- ---------------------------------------------------------------------------
-- Fake provider scaffolding
-- ---------------------------------------------------------------------------

local FAKE_NAME = "ui_actions_fake"

---@type table
local fake = {
	-- Default to a non-empty palette so the "emoji" happy path tests pass
	-- without per-test setup. The palette-empty branch overrides this.
	reaction_palette = { { content = "thumbs_up", glyph = "👍" } },
	-- thread_url is set per-test (or removed) to exercise both can_perform branches.
	thread_url = function()
		return "https://example.test/pr/1#thread"
	end,
	-- Minimal stubs for fields read at module load — none of the can_perform
	-- predicates we test reach these, but having them avoids accidental nils
	-- if a future action does.
	git_user = "tester",
	comments = {},
	hunks = {},
}

local function install_fake_provider()
	package.loaded["pr.providers." .. FAKE_NAME] = fake
	config.opts.provider = FAKE_NAME
end

install_fake_provider()

-- Require pr.ui AFTER the fake is installed, so any access-time provider
-- resolution during require resolves against the fake.
local ui = require("pr.ui")

-- ---------------------------------------------------------------------------
-- Fixture helpers
-- ---------------------------------------------------------------------------

---Build a CommentInfo-shaped table with sensible defaults; overrides win.
local function mk_comment(overrides)
	local c = {
		database_id = 100,
		author = "alice",
		body = "hello",
		viewer_did_author = false,
		viewer_can_react = true,
		viewer_can_update = false,
		viewer_can_delete = false,
		reaction_groups = {},
		start_line = 1,
		end_line = 1,
		updated_at = "2026-01-01T00:00:00Z",
	}
	for k, v in pairs(overrides or {}) do
		c[k] = v
	end
	return c
end

---Build a ReviewThread-shaped table with sensible defaults; overrides win.
local function mk_thread(overrides)
	local t = {
		id = "T_1",
		is_resolved = false,
		is_outdated = false,
		viewer_can_reply = true,
		viewer_can_resolve = true,
		viewer_can_unresolve = true,
		resolved_by = nil,
		comments = { mk_comment() },
	}
	for k, v in pairs(overrides or {}) do
		t[k] = v
	end
	return t
end

local SUGGESTION_BODY = "looks fine\n```suggestion\nfoo\nbar\n```\n"

-- ---------------------------------------------------------------------------
-- Test cases
-- ---------------------------------------------------------------------------

describe("ui.M.actions: contract & matrix", function()
	-- Snapshot the action keys so it's obvious when one is added/removed and
	-- this spec needs to be extended to cover it.
	it("registers exactly the documented action keys", function()
		local expected = {
			"emoji",
			"resolve",
			"unresolve",
			"reply",
			"quote_reply",
			"edit",
			"save",
			"delete",
			"yank_url",
			"open_url",
			"apply_suggestion",
			"yank_suggestion",
			"help",
			"quit",
		}
		local got = {}
		for k, _ in pairs(ui.actions) do
			table.insert(got, k)
		end
		table.sort(expected)
		table.sort(got)
		assert.are.same(expected, got)
	end)

	it("every action carries the required contract fields", function()
		for name, action in pairs(ui.actions) do
			-- `mode` may be `nil` (the menu-only `edit` action), but every action
			-- must declare can_perform/perform and the menu/hint metadata.
			assert.is_function(action.can_perform, name .. ".can_perform")
			assert.is_function(action.perform, name .. ".perform")
			assert.is_string(action.menu_text, name .. ".menu_text")
			assert.is_string(action.menu_desc, name .. ".menu_desc")
			assert.is_string(action.popup_hint, name .. ".popup_hint")
			assert.is_boolean(action.show_hint, name .. ".show_hint")
		end
	end)
end)

describe("ui.M.actions.emoji.can_perform", function()
	local original_palette
	before_each(function()
		original_palette = fake.reaction_palette
		fake.reaction_palette = { { content = "thumbs_up", glyph = "👍" } }
	end)
	after_each(function()
		fake.reaction_palette = original_palette
	end)

	it("returns false when viewer_can_react is false", function()
		local thread = mk_thread({ comments = { mk_comment({ viewer_can_react = false }) } })
		assert.is_false(ui.actions.emoji.can_perform(thread, thread.comments[1]))
	end)

	it("returns false when the provider has no reaction palette (bitbucket-like)", function()
		fake.reaction_palette = {}
		local thread = mk_thread()
		assert.is_false(ui.actions.emoji.can_perform(thread, thread.comments[1]))
	end)

	it("returns false when the provider's palette is nil", function()
		fake.reaction_palette = nil
		local thread = mk_thread()
		assert.is_false(ui.actions.emoji.can_perform(thread, thread.comments[1]))
	end)

	it("returns true when viewer_can_react and palette is populated", function()
		local thread = mk_thread()
		assert.is_true(ui.actions.emoji.can_perform(thread, thread.comments[1]))
	end)
end)

describe("ui.M.actions.resolve / unresolve.can_perform", function()
	-- The "r" key collision between resolve and unresolve is intentional: the
	-- popup map loop only binds an action whose can_perform returns true for
	-- the focused comment, so at most one is active for any given thread. If
	-- both ever returned true simultaneously, the binding would be ambiguous.
	it("resolve fires only on open threads the viewer can resolve", function()
		local can = ui.actions.resolve.can_perform
		assert.is_true(can(mk_thread({ is_resolved = false, viewer_can_resolve = true })))
		assert.is_false(can(mk_thread({ is_resolved = true, viewer_can_resolve = true })))
		assert.is_false(can(mk_thread({ is_resolved = false, viewer_can_resolve = false })))
	end)

	it("unresolve fires only on resolved threads the viewer can unresolve", function()
		local can = ui.actions.unresolve.can_perform
		assert.is_true(can(mk_thread({ is_resolved = true, viewer_can_unresolve = true })))
		assert.is_false(can(mk_thread({ is_resolved = false, viewer_can_unresolve = true })))
		assert.is_false(can(mk_thread({ is_resolved = true, viewer_can_unresolve = false })))
	end)

	it("resolve and unresolve never both return true for the same thread", function()
		-- Walk a representative cross-product. The dispatcher relies on this
		-- invariant; if the predicates ever overlap, the "r" keypress becomes
		-- ambiguous.
		for _, is_resolved in ipairs({ true, false }) do
			for _, vcr in ipairs({ true, false }) do
				for _, vcu in ipairs({ true, false }) do
					local thread = mk_thread({
						is_resolved = is_resolved,
						viewer_can_resolve = vcr,
						viewer_can_unresolve = vcu,
					})
					local r = ui.actions.resolve.can_perform(thread)
					local u = ui.actions.unresolve.can_perform(thread)
					assert.is_false(r and u, ("both true for is_resolved=%s vcr=%s vcu=%s"):format(tostring(is_resolved), tostring(vcr), tostring(vcu)))
				end
			end
		end
	end)
end)

describe("ui.M.actions.reply / quote_reply.can_perform", function()
	it("both gate purely on thread.viewer_can_reply", function()
		assert.is_true(ui.actions.reply.can_perform(mk_thread({ viewer_can_reply = true })))
		assert.is_false(ui.actions.reply.can_perform(mk_thread({ viewer_can_reply = false })))
		assert.is_true(ui.actions.quote_reply.can_perform(mk_thread({ viewer_can_reply = true })))
		assert.is_false(ui.actions.quote_reply.can_perform(mk_thread({ viewer_can_reply = false })))
	end)

	it("quote_reply is the visual-mode entry point", function()
		assert.are.equal("v", ui.actions.quote_reply.mode)
		assert.are.equal("n", ui.actions.reply.mode)
		-- Same key ("c") in different modes is intentional and not a collision.
		assert.are.equal("c", ui.actions.reply.key)
		assert.are.equal("c", ui.actions.quote_reply.key)
	end)
end)

describe("ui.M.actions.edit.can_perform", function()
	it("gates on comment.viewer_can_update", function()
		local can = ui.actions.edit.can_perform
		local thread = mk_thread()
		assert.is_true(can(thread, mk_comment({ viewer_can_update = true })))
		assert.is_false(can(thread, mk_comment({ viewer_can_update = false })))
	end)

	it("has nil mode/key so it does not bind a keymap (menu-only)", function()
		-- The popup map loop gates on `action.key`, so a nil key keeps the
		-- action menu-discoverable without consuming a top-level keypress.
		assert.is_nil(ui.actions.edit.mode)
		assert.is_nil(ui.actions.edit.key)
		assert.is_false(ui.actions.edit.show_hint)
	end)
end)

describe("ui.M.actions.save.can_perform", function()
	-- `save` reads from drafts.get_edit(database_id) at predicate time, so we
	-- swap in a fake drafts module per-test rather than touching the real
	-- on-disk drafts file.
	local original_drafts
	before_each(function()
		original_drafts = package.loaded["pr.drafts"]
	end)
	after_each(function()
		package.loaded["pr.drafts"] = original_drafts
	end)

	it("returns falsy when no draft exists for this comment", function()
		package.loaded["pr.drafts"] = {
			get_edit = function()
				return nil
			end,
		}
		local thread = mk_thread()
		assert.is_falsy(ui.actions.save.can_perform(thread, mk_comment({ database_id = 1 })))
	end)

	it("returns falsy when the draft is missing body or updated_at", function()
		package.loaded["pr.drafts"] = {
			get_edit = function()
				return { body = "wip" } -- no updated_at
			end,
		}
		local thread = mk_thread()
		assert.is_falsy(ui.actions.save.can_perform(thread, mk_comment({ database_id = 1 })))

		package.loaded["pr.drafts"] = {
			get_edit = function()
				return { updated_at = "x" } -- no body
			end,
		}
		assert.is_falsy(ui.actions.save.can_perform(thread, mk_comment({ database_id = 1 })))
	end)

	it("returns truthy when the draft has both body and updated_at", function()
		package.loaded["pr.drafts"] = {
			get_edit = function()
				return { body = "wip", updated_at = "2026-01-01T00:00:00Z" }
			end,
		}
		local thread = mk_thread()
		assert.is_truthy(ui.actions.save.can_perform(thread, mk_comment({ database_id = 1 })))
	end)
end)

describe("ui.M.actions.delete.can_perform", function()
	it("gates on comment.viewer_can_delete", function()
		local can = ui.actions.delete.can_perform
		local thread = mk_thread()
		assert.is_true(can(thread, mk_comment({ viewer_can_delete = true })))
		assert.is_false(can(thread, mk_comment({ viewer_can_delete = false })))
	end)
end)

describe("ui.M.actions.yank_url / open_url.can_perform", function()
	local original_thread_url
	before_each(function()
		original_thread_url = fake.thread_url
	end)
	after_each(function()
		fake.thread_url = original_thread_url
	end)

	it("returns true when the provider exposes thread_url and a comment is focused", function()
		fake.thread_url = function()
			return "https://example.test/"
		end
		local thread = mk_thread()
		assert.is_true(ui.actions.yank_url.can_perform(thread, thread.comments[1]))
		assert.is_true(ui.actions.open_url.can_perform(thread, thread.comments[1]))
	end)

	it("returns false when the provider does not implement thread_url", function()
		fake.thread_url = nil
		local thread = mk_thread()
		assert.is_false(ui.actions.yank_url.can_perform(thread, thread.comments[1]))
		assert.is_false(ui.actions.open_url.can_perform(thread, thread.comments[1]))
	end)

	it("returns false when no comment is under the cursor (nil comment)", function()
		fake.thread_url = function()
			return "https://example.test/"
		end
		assert.is_false(ui.actions.yank_url.can_perform(mk_thread(), nil))
		assert.is_false(ui.actions.open_url.can_perform(mk_thread(), nil))
	end)

	it("URL actions never set show_hint (per the URL-actions convention)", function()
		assert.is_false(ui.actions.yank_url.show_hint)
		assert.is_false(ui.actions.open_url.show_hint)
	end)
end)

describe("ui.M.actions.apply_suggestion / yank_suggestion.can_perform", function()
	-- Both predicates re-run the pure `extract_suggestions` parser, so the
	-- relevant branches are: nil comment, nil body, body without a fence,
	-- body with a fence, body with multiple fences.
	it("returns false when comment is nil", function()
		assert.is_false(ui.actions.apply_suggestion.can_perform(mk_thread(), nil))
		assert.is_false(ui.actions.yank_suggestion.can_perform(mk_thread(), nil))
	end)

	it("returns false when comment.body is nil", function()
		local c = mk_comment({ body = nil })
		assert.is_false(ui.actions.apply_suggestion.can_perform(mk_thread(), c))
		assert.is_false(ui.actions.yank_suggestion.can_perform(mk_thread(), c))
	end)

	it("returns false when the body has no suggestion fence", function()
		local c = mk_comment({ body = "just a plain comment, no fence" })
		assert.is_false(ui.actions.apply_suggestion.can_perform(mk_thread(), c))
		assert.is_false(ui.actions.yank_suggestion.can_perform(mk_thread(), c))
	end)

	it("returns true when the body contains a closed suggestion fence", function()
		local c = mk_comment({ body = SUGGESTION_BODY })
		assert.is_true(ui.actions.apply_suggestion.can_perform(mk_thread(), c))
		assert.is_true(ui.actions.yank_suggestion.can_perform(mk_thread(), c))
	end)

	it("returns false when the suggestion fence is unclosed", function()
		-- extract_suggestions skips unclosed fences, so the count is 0.
		local c = mk_comment({ body = "```suggestion\nfoo\nno closer" })
		assert.is_false(ui.actions.apply_suggestion.can_perform(mk_thread(), c))
		assert.is_false(ui.actions.yank_suggestion.can_perform(mk_thread(), c))
	end)
end)

describe("ui.M.actions.help / quit.can_perform", function()
	it("help is always available", function()
		assert.is_true(ui.actions.help.can_perform(mk_thread(), mk_comment()))
		-- nil thread/comment must also be acceptable: the dispatcher passes
		-- both, but `?` should fire even when the cursor isn't on a comment.
		assert.is_true(ui.actions.help.can_perform(nil, nil))
	end)

	it("quit is always available", function()
		assert.is_true(ui.actions.quit.can_perform(mk_thread(), mk_comment()))
		assert.is_true(ui.actions.quit.can_perform(nil, nil))
	end)
end)

-- ---------------------------------------------------------------------------
-- Keybinding contract
-- ---------------------------------------------------------------------------

describe("ui.M.actions keybinding contract", function()
	it("the 'r' collision (resolve/unresolve) is the only same-mode-same-key pair", function()
		-- Build a set of "mode|key" -> { action_name, ... } and assert that no
		-- entry has 2+ actions other than the known resolve/unresolve pair.
		local by_binding = {}
		for name, action in pairs(ui.actions) do
			if action.key and action.mode then
				local k = action.mode .. "|" .. action.key
				by_binding[k] = by_binding[k] or {}
				table.insert(by_binding[k], name)
			end
		end
		for binding, names in pairs(by_binding) do
			if #names > 1 then
				table.sort(names)
				assert.are.same({ "resolve", "unresolve" }, names, "unexpected key collision at " .. binding)
			end
		end
	end)

	it("URL actions follow the no-popup-hint convention (memory: url-actions-no-hint)", function()
		-- yank_url / open_url have side-effects that don't mutate the thread,
		-- so the popup hint line is reserved for thread-mutating actions.
		assert.is_false(ui.actions.yank_url.show_hint)
		assert.is_false(ui.actions.open_url.show_hint)
	end)

	it("non-side-effect actions that mutate the thread expose a popup hint", function()
		-- Spot-check: every action below mutates server-side state and so its
		-- presence in the bottom hint line is meaningful to the user.
		assert.is_true(ui.actions.resolve.show_hint)
		assert.is_true(ui.actions.unresolve.show_hint)
		assert.is_true(ui.actions.reply.show_hint)
		assert.is_true(ui.actions.delete.show_hint)
		-- emoji is thread-decorative but mutates server state, so hinted.
		assert.is_true(ui.actions.emoji.show_hint)
		-- apply_suggestion mutates the underlying buffer; hinted.
		assert.is_true(ui.actions.apply_suggestion.show_hint)
	end)

	it("every action with a key declares a mode (or both nil, for menu-only edit)", function()
		for name, action in pairs(ui.actions) do
			if action.key ~= nil then
				assert.is_not_nil(action.mode, name .. " has key but no mode")
			end
			if action.mode == nil then
				assert.is_nil(action.key, name .. " has mode=nil but a non-nil key")
			end
		end
	end)
end)
