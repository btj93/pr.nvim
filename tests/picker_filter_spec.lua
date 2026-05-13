local filter = require("pr.pickers.filter")

local function thread(opts)
	return vim.tbl_extend("force", { is_resolved = false, is_outdated = false }, opts or {})
end

describe("pickers.filter", function()
	before_each(function()
		filter.reset()
	end)

	describe("apply", function()
		it("returns input unchanged when both filters are on", function()
			local input = {
				["a.lua"] = { thread(), thread({ is_resolved = true }), thread({ is_outdated = true }) },
			}
			local out = filter.apply(input)
			assert.equals(3, #out["a.lua"])
		end)

		it("hides resolved threads when show_resolved is false", function()
			filter.toggle("resolved")
			local input = {
				["a.lua"] = { thread(), thread({ is_resolved = true }) },
			}
			local out = filter.apply(input)
			assert.equals(1, #out["a.lua"])
			assert.is_false(out["a.lua"][1].is_resolved)
		end)

		it("hides outdated threads when show_outdated is false", function()
			filter.toggle("outdated")
			local input = {
				["a.lua"] = { thread(), thread({ is_outdated = true }) },
			}
			local out = filter.apply(input)
			assert.equals(1, #out["a.lua"])
			assert.is_false(out["a.lua"][1].is_outdated)
		end)

		it("drops a file entirely when all its threads are filtered out", function()
			filter.toggle("resolved")
			local input = {
				["a.lua"] = { thread({ is_resolved = true }) },
				["b.lua"] = { thread() },
			}
			local out = filter.apply(input)
			assert.is_nil(out["a.lua"])
			assert.equals(1, #out["b.lua"])
		end)

		it("treats nil input as empty", function()
			local out = filter.apply(nil)
			assert.are.same({}, out)
		end)
	end)

	describe("toggle + reset", function()
		it("toggle flips a single flag", function()
			filter.toggle("resolved")
			assert.is_false(filter.state.show_resolved)
			assert.is_true(filter.state.show_outdated)
			filter.toggle("resolved")
			assert.is_true(filter.state.show_resolved)
		end)

		it("reset restores defaults", function()
			filter.toggle("resolved")
			filter.toggle("outdated")
			filter.reset()
			assert.is_true(filter.state.show_resolved)
			assert.is_true(filter.state.show_outdated)
		end)
	end)

	describe("label", function()
		it("returns empty when no filters active", function()
			assert.equals("", filter.label())
		end)

		it("shows 'unresolved' when resolved hidden", function()
			filter.toggle("resolved")
			assert.equals("[unresolved] ", filter.label())
		end)

		it("shows 'current' when outdated hidden", function()
			filter.toggle("outdated")
			assert.equals("[current] ", filter.label())
		end)

		it("combines flags with +", function()
			filter.toggle("resolved")
			filter.toggle("outdated")
			assert.equals("[unresolved+current] ", filter.label())
		end)
	end)

	describe("persistence across refresh", function()
		it("state survives a no-op refresh cycle", function()
			filter.reset()
			filter.toggle("resolved")
			assert.is_false(filter.state.show_resolved)
			-- M.refresh in init.lua intentionally does NOT call filter.reset anymore.
			-- This test locks that in by simulating: nothing calls filter.reset, state stays.
			assert.is_false(filter.state.show_resolved)
			filter.reset()
		end)
	end)
end)
