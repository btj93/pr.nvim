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

	it("builds entries for unresolved non-outdated threads", function()
		local entries = diag._build({ thread() }, nil)
		assert.equals(1, #entries)
		assert.equals(4, entries[1].lnum) -- start_line 5 → lnum 4 (0-indexed)
		assert.equals(6, entries[1].end_lnum) -- end_line 7 → end_lnum 6
		assert.equals(0, entries[1].col)
		assert.equals("PR", entries[1].source)
		assert.matches("alice", entries[1].message)
		assert.matches("looks risky", entries[1].message)
	end)

	it("skips resolved threads by default", function()
		assert.equals(0, #diag._build({ thread({ is_resolved = true }) }, nil))
	end)

	it("skips outdated threads by default", function()
		assert.equals(0, #diag._build({ thread({ is_outdated = true }) }, nil))
	end)

	it("includes resolved threads when configured", function()
		require("pr.config").setup({ diagnostics = { include_resolved = true } })
		assert.equals(1, #diag._build({ thread({ is_resolved = true }) }, nil))
	end)

	it("includes outdated threads when configured", function()
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

	it("truncates very long bodies in the message", function()
		local long = string.rep("x", 200)
		local t = thread({ comments = { { author = "a", body = long, start_line = 1, end_line = 1 } } })
		local entries = diag._build({ t }, nil)
		assert.is_true(#entries[1].message < 150)
	end)
end)
