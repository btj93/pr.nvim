describe("suggestion.apply", function()
	local s
	local drift
	before_each(function()
		package.loaded["pr.suggestion"] = nil
		s = require("pr.suggestion")
		drift = require("pr.drift")
	end)

	local function make_buf(lines)
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		return buf
	end

	it("replaces a single anchored line when buffer matches HEAD", function()
		local buf = make_buf({ "a", "b", "c", "d" })
		local dm = drift.compute_drift({ "a", "b", "c", "d" }, { "a", "b", "c", "d" })
		local ok, err = s.apply(buf, {
			content_lines = { "B1", "B2" },
			anchor_start_line = 2,
			anchor_end_line = 2,
		}, dm)
		assert.is_true(ok, err)
		local got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		assert.equals(5, #got)
		assert.equals("a", got[1])
		assert.equals("B1", got[2])
		assert.equals("B2", got[3])
		assert.equals("c", got[4])
		assert.equals("d", got[5])
	end)

	it("replaces a multi-line range", function()
		local buf = make_buf({ "a", "b", "c", "d", "e" })
		local dm = drift.compute_drift({ "a", "b", "c", "d", "e" }, { "a", "b", "c", "d", "e" })
		local ok = s.apply(buf, {
			content_lines = { "X" },
			anchor_start_line = 2,
			anchor_end_line = 4,
		}, dm)
		assert.is_true(ok)
		local got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		assert.equals(3, #got)
		assert.equals("a", got[1])
		assert.equals("X", got[2])
		assert.equals("e", got[3])
	end)

	it("translates commit-space anchors through a drift map (locally inserted lines above)", function()
		-- Local buffer has 2 new lines at the top: commit line 2 = buffer line 4.
		local buf = make_buf({ "new1", "new2", "a", "b", "c" })
		local dm = drift.compute_drift({ "a", "b", "c" }, { "new1", "new2", "a", "b", "c" })
		local ok = s.apply(buf, {
			content_lines = { "B" },
			anchor_start_line = 2, -- commit-space (which is buffer-space line 4)
			anchor_end_line = 2,
		}, dm)
		assert.is_true(ok)
		local got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		assert.equals("new1", got[1])
		assert.equals("new2", got[2])
		assert.equals("a", got[3])
		assert.equals("B", got[4]) -- replaces former "b"
		assert.equals("c", got[5])
	end)

	it("returns (false, err) when start anchor drifted off buffer", function()
		-- The commit had 3 lines but the buffer deleted line 2. Trying to apply to commit-line-2 → nil.
		local buf = make_buf({ "a", "c" })
		local dm = drift.compute_drift({ "a", "b", "c" }, { "a", "c" })
		local ok, err = s.apply(buf, {
			content_lines = { "B" },
			anchor_start_line = 2,
			anchor_end_line = 2,
		}, dm)
		assert.is_false(ok)
		assert.is_not_nil(err)
	end)

	it("returns (false, err) when buffer is invalid", function()
		local ok, err = s.apply(99999, {
			content_lines = { "x" },
			anchor_start_line = 1,
			anchor_end_line = 1,
		}, nil)
		assert.is_false(ok)
		assert.is_not_nil(err)
	end)

	it("uses raw anchors when drift_map is nil", function()
		local buf = make_buf({ "a", "b", "c" })
		local ok = s.apply(buf, {
			content_lines = { "X" },
			anchor_start_line = 2,
			anchor_end_line = 2,
		}, nil)
		assert.is_true(ok)
		local got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		assert.equals("X", got[2])
	end)
end)
