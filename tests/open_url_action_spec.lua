-- Verifies the `open_url` action in ui.actions: gating + dispatch to
-- vim.ui.open. The action exists so users can fall back to the browser for
-- content the plugin can't render (notably Copilot's "Suggested changeset"
-- autofixes, which GitHub doesn't expose in REST or GraphQL).

local fake_provider = {
	reaction_palette = {},
	thread_url = function(_thread, comment)
		if not comment or not comment.database_id then
			return nil
		end
		return "https://example.com/pull/1#discussion_r" .. tostring(comment.database_id)
	end,
}

package.loaded["pr.provider"] = {
	get_provider = function()
		return fake_provider
	end,
}

local ui = require("pr.ui")

describe("ui.actions.open_url", function()
	local action = ui.actions.open_url

	it("is defined with the expected metadata", function()
		assert.is_table(action)
		assert.equals("n", action.mode)
		assert.equals("gx", action.key)
		assert.equals("Open thread in browser", action.menu_text)
		-- show_hint = false: action is discoverable via `?` help menu, but not
		-- pinned to the popup hint line (keeps the hint line uncluttered).
		assert.equals(false, action.show_hint)
	end)

	it("can_perform returns true with a comment and a thread_url provider", function()
		assert.is_true(action.can_perform({}, { database_id = 42 }))
	end)

	it("can_perform returns false when comment is nil", function()
		assert.is_false(action.can_perform({}, nil) or false)
	end)

	it("can_perform returns false when provider lacks thread_url", function()
		local saved = fake_provider.thread_url
		fake_provider.thread_url = nil
		assert.is_false(action.can_perform({}, { database_id = 1 }) or false)
		fake_provider.thread_url = saved
	end)

	it("perform calls vim.ui.open with the resolved URL", function()
		local saved = vim.ui.open
		local captured
		vim.ui.open = function(url)
			captured = url
		end
		action.perform({ id = "T_1" }, { database_id = 99 })
		assert.equals("https://example.com/pull/1#discussion_r99", captured)
		vim.ui.open = saved
	end)

	it("perform notifies and skips open when thread_url returns nil", function()
		local saved_open = vim.ui.open
		local saved_notify = vim.notify
		local opened = false
		local notified
		vim.ui.open = function()
			opened = true
		end
		vim.notify = function(msg)
			notified = msg
		end
		-- No database_id -> stub returns nil
		action.perform({}, {})
		assert.is_false(opened)
		assert.is_not_nil(notified)
		assert.is_truthy(notified:find("Permalink unavailable", 1, true))
		vim.ui.open = saved_open
		vim.notify = saved_notify
	end)

	it("perform notifies on Neovim < 0.10 (vim.ui.open missing)", function()
		local saved_open = vim.ui.open
		local saved_notify = vim.notify
		local notified
		vim.ui.open = nil
		vim.notify = function(msg)
			notified = msg
		end
		action.perform({ id = "T_1" }, { database_id = 1 })
		assert.is_not_nil(notified)
		assert.is_truthy(notified:find("vim.ui.open unavailable", 1, true))
		vim.ui.open = saved_open
		vim.notify = saved_notify
	end)
end)
