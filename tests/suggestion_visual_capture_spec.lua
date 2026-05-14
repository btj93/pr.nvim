describe("suggestion._capture_visual_lines", function()
	local s
	before_each(function()
		package.loaded["pr.suggestion"] = nil
		s = require("pr.suggestion")
	end)

	local function make_buf(lines)
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		return buf
	end

	it("captures exactly the requested line range (inclusive)", function()
		local buf = make_buf({ "AA", "BB", "CC", "DD", "EE" })
		local lines = s._capture_visual_lines(buf, 2, 3)
		assert.equals(2, #lines)
		assert.equals("BB", lines[1])
		assert.equals("CC", lines[2])
	end)

	it("captures a single-line selection", function()
		local buf = make_buf({ "AA", "BB", "CC" })
		local lines = s._capture_visual_lines(buf, 2, 2)
		assert.equals(1, #lines)
		assert.equals("BB", lines[1])
	end)

	it("captures the full buffer when start=1 and end=#lines", function()
		local buf = make_buf({ "AA", "BB", "CC" })
		local lines = s._capture_visual_lines(buf, 1, 3)
		assert.equals(3, #lines)
		assert.equals("CC", lines[3])
	end)

	it("handles selection ending at EOF without throwing", function()
		local buf = make_buf({ "AA", "BB" })
		local lines = s._capture_visual_lines(buf, 1, 2)
		assert.equals(2, #lines)
	end)

	it("returns empty for invalid range", function()
		local buf = make_buf({ "AA", "BB" })
		assert.equals(0, #s._capture_visual_lines(buf, 5, 7))
		assert.equals(0, #s._capture_visual_lines(buf, 2, 1))
		assert.equals(0, #s._capture_visual_lines(buf, 0, 1))
	end)

	it("returns empty for invalid buffer", function()
		assert.equals(0, #s._capture_visual_lines(99999, 1, 2))
	end)
end)
