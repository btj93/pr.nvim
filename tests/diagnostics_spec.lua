describe("diagnostics._build", function()
	local diag
	local drift
	before_each(function()
		package.loaded["pr.diagnostics"] = nil
		package.loaded["pr.config"] = nil
		diag = require("pr.diagnostics")
		drift = require("pr.drift")
		require("pr.config").setup({})
	end)

	local function thread(opts)
		return vim.tbl_extend("force", {
			is_resolved = false,
			is_outdated = false,
			comments = { { author = "alice", body = "looks risky", start_line = 5, end_line = 7 } },
		}, opts or {})
	end

	it("builds entries for unresolved non-outdated threads at HINT severity", function()
		local entries = diag._build({ thread() }, nil)
		assert.equals(1, #entries)
		assert.equals(4, entries[1].lnum) -- start_line 5 → lnum 4 (0-indexed)
		assert.equals(6, entries[1].end_lnum) -- end_line 7 → end_lnum 6
		assert.equals(0, entries[1].col)
		assert.equals("PR", entries[1].source)
		assert.equals(vim.diagnostic.severity.HINT, entries[1].severity)
		assert.matches("alice", entries[1].message)
		assert.matches("looks risky", entries[1].message)
	end)

	it("skips resolved threads by default (show_resolved_inline defaults to false)", function()
		assert.equals(0, #diag._build({ thread({ is_resolved = true }) }, nil))
	end)

	it("skips outdated threads by default", function()
		assert.equals(0, #diag._build({ thread({ is_outdated = true }) }, nil))
	end)

	it("includes resolved threads when show_resolved_inline = true (unified knob)", function()
		require("pr.config").setup({ show_resolved_inline = true })
		local entries = diag._build({ thread({ is_resolved = true }) }, nil)
		assert.equals(1, #entries)
		assert.equals(vim.diagnostic.severity.INFO, entries[1].severity)
	end)

	it("includes resolved threads when diagnostics.include_resolved = true (back-compat)", function()
		require("pr.config").setup({ diagnostics = { include_resolved = true } })
		assert.equals(1, #diag._build({ thread({ is_resolved = true }) }, nil))
	end)

	it("explicit diagnostics.include_resolved = false overrides show_resolved_inline = true", function()
		require("pr.config").setup({
			show_resolved_inline = true,
			diagnostics = { include_resolved = false },
		})
		assert.equals(0, #diag._build({ thread({ is_resolved = true }) }, nil))
	end)

	it("includes outdated threads when show_outdated_inline = true", function()
		require("pr.config").setup({ show_outdated_inline = true })
		assert.equals(1, #diag._build({ thread({ is_outdated = true }) }, nil))
	end)

	it("includes outdated threads when diagnostics.include_outdated = true (back-compat)", function()
		require("pr.config").setup({ diagnostics = { include_outdated = true } })
		assert.equals(1, #diag._build({ thread({ is_outdated = true }) }, nil))
	end)

	it("translates lines through drift_map", function()
		-- HEAD had 3 lines; buffer added 2 lines at the top.
		local d = drift.compute_drift({ "a", "b", "c" }, { "x", "y", "a", "b", "c" })
		-- thread anchored at commit line 2 → buffer line 4 → lnum 3 (0-indexed)
		local t = thread({ comments = { { author = "a", body = "b", start_line = 2, end_line = 2 } } })
		local entries = diag._build({ t }, d)
		assert.equals(1, #entries)
		assert.equals(3, entries[1].lnum)
	end)

	it("skips threads whose start anchor drifted off buffer", function()
		-- HEAD line 2 was deleted locally; drift returns nil for line 2.
		local d = drift.compute_drift({ "a", "b", "c" }, { "a", "c" })
		local t = thread({ comments = { { author = "a", body = "b", start_line = 2, end_line = 2 } } })
		assert.equals(0, #diag._build({ t }, d))
	end)

	it("returns empty array for nil/empty threads input", function()
		assert.equals(0, #diag._build(nil, nil))
		assert.equals(0, #diag._build({}, nil))
	end)

	it("publishes the full body — no 120-char truncation", function()
		local long = string.rep("x", 200)
		local t = thread({ comments = { { author = "a", body = long, start_line = 1, end_line = 1 } } })
		local entries = diag._build({ t }, nil)
		-- "a: " prefix (3 chars) + 200-char body = 203 chars total
		assert.equals(203, #entries[1].message)
	end)

	it("flattens CRLF and LF in the body to single spaces", function()
		local body = "line1\r\nline2\nline3"
		local t = thread({ comments = { { author = "a", body = body, start_line = 1, end_line = 1 } } })
		local entries = diag._build({ t }, nil)
		assert.is_nil(entries[1].message:find("\r"))
		assert.is_nil(entries[1].message:find("\n"))
		assert.matches("line1 line2 line3", entries[1].message)
	end)

	it("custom severity_resolved is respected", function()
		require("pr.config").setup({
			show_resolved_inline = true,
			diagnostics = { severity_resolved = vim.diagnostic.severity.WARN },
		})
		local entries = diag._build({ thread({ is_resolved = true }) }, nil)
		assert.equals(vim.diagnostic.severity.WARN, entries[1].severity)
	end)
end)
