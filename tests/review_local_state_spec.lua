local function tmpfile()
	return vim.fn.tempname()
end

describe("review_local", function()
	local local_review
	before_each(function()
		package.loaded["pr.review_local"] = nil
		local_review = require("pr.review_local")
		local_review._set_path(tmpfile())
	end)

	it("round-trips a single comment", function()
		local_review.save("gitlab", "group", "proj", 42, {
			id = 1,
			path = "a.lua",
			start_line = 10,
			end_line = 10,
			body = "looks good",
		})
		local_review._clear_cache()
		local list = local_review.load("gitlab", "group", "proj", 42)
		assert.equals(1, #list)
		assert.equals("looks good", list[1].body)
	end)

	it("isolates between (provider, owner, repo, pr) tuples", function()
		local_review.save("gitlab", "g", "p", 1, { id = 1, path = "a", end_line = 1, body = "x" })
		local_review.save("gitlab", "g", "p", 2, { id = 2, path = "b", end_line = 2, body = "y" })
		assert.equals(1, #local_review.load("gitlab", "g", "p", 1))
		assert.equals(1, #local_review.load("gitlab", "g", "p", 2))
		assert.equals(0, #local_review.load("gitlab", "g", "p", 3))
	end)

	it("returns empty list for unknown key", function()
		assert.equals(0, #local_review.load("gitlab", "g", "p", 999))
	end)

	it("clear removes only the keyed entry", function()
		local_review.save("gitlab", "g", "p", 1, { id = 1, path = "a", end_line = 1, body = "x" })
		local_review.save("gitlab", "g", "p", 2, { id = 2, path = "b", end_line = 2, body = "y" })
		local_review.clear("gitlab", "g", "p", 1)
		assert.equals(0, #local_review.load("gitlab", "g", "p", 1))
		assert.equals(1, #local_review.load("gitlab", "g", "p", 2))
	end)

	it("handles missing/empty file gracefully", function()
		local_review._set_path(vim.fn.tempname() .. "-nonexistent")
		assert.equals(0, #local_review.load("gitlab", "g", "p", 1))
	end)
end)
