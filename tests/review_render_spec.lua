describe("ui._render_pending_list", function()
	local ui
	before_each(function()
		package.loaded["pr.ui"] = nil
		ui = require("pr.ui")
	end)

	it("renders one bullet per comment with path:end_line + truncated body", function()
		local pending = {
			{ id = 1, path = "lua/pr/init.lua", start_line = 42, end_line = 42, body = "this would race with the autorefresh timer" },
			{ id = 2, path = "lua/pr/ui.lua", start_line = 118, end_line = 120, body = "consider extracting" },
		}
		local lines = ui._render_pending_list(pending)
		assert.is_true(#lines >= 2)
		local body = table.concat(lines, "\n")
		assert.matches("lua/pr/init.lua:42", body)
		assert.matches("lua/pr/ui.lua:120", body)
		assert.matches("this would race", body)
		assert.matches("consider extracting", body)
	end)

	it("emits a placeholder line when pending is empty/nil", function()
		local out_nil = ui._render_pending_list(nil)
		local out_empty = ui._render_pending_list({})
		assert.equals(1, #out_nil)
		assert.equals(1, #out_empty)
		assert.matches("no pending", out_nil[1])
		assert.matches("no pending", out_empty[1])
	end)

	it("replaces newlines in body so each pending occupies one line", function()
		local pending = { { id = 1, path = "x.lua", end_line = 1, body = "first line\nsecond line" } }
		local lines = ui._render_pending_list(pending)
		-- Each bullet must be a single line — the newline should be stripped/replaced.
		assert.equals(1, #lines)
		assert.is_nil(lines[1]:match("\n"))
	end)
end)
