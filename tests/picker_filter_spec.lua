local filter = require("pr.pickers.filter")

local function thread(opts)
	return vim.tbl_extend("force", { is_resolved = false, is_outdated = false }, opts or {})
end

describe("pickers.filter", function()
	before_each(function()
		filter.reset()
	end)

	describe("apply", function()
		it("hides resolved + outdated by default (aligned with inline defaults)", function()
			local input = {
				["a.lua"] = { thread(), thread({ is_resolved = true }), thread({ is_outdated = true }) },
			}
			local out = filter.apply(input)
			assert.equals(1, #out["a.lua"])
			assert.is_false(out["a.lua"][1].is_resolved)
			assert.is_false(out["a.lua"][1].is_outdated)
		end)

		it("returns all threads when both filters are toggled on", function()
			filter.toggle("resolved")
			filter.toggle("outdated")
			local input = {
				["a.lua"] = { thread(), thread({ is_resolved = true }), thread({ is_outdated = true }) },
			}
			local out = filter.apply(input)
			assert.equals(3, #out["a.lua"])
		end)

		it("hides resolved threads when show_resolved is false (default)", function()
			local input = {
				["a.lua"] = { thread(), thread({ is_resolved = true }) },
			}
			local out = filter.apply(input)
			assert.equals(1, #out["a.lua"])
			assert.is_false(out["a.lua"][1].is_resolved)
		end)

		it("hides outdated threads when show_outdated is false (default)", function()
			local input = {
				["a.lua"] = { thread(), thread({ is_outdated = true }) },
			}
			local out = filter.apply(input)
			assert.equals(1, #out["a.lua"])
			assert.is_false(out["a.lua"][1].is_outdated)
		end)

		it("drops a file entirely when all its threads are filtered out", function()
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
		it("toggle flips a single flag (from default false)", function()
			assert.is_false(filter.state.show_resolved)
			filter.toggle("resolved")
			assert.is_true(filter.state.show_resolved)
			assert.is_false(filter.state.show_outdated)
			filter.toggle("resolved")
			assert.is_false(filter.state.show_resolved)
		end)

		it("reset restores defaults (both false)", function()
			filter.toggle("resolved")
			filter.toggle("outdated")
			filter.reset()
			assert.is_false(filter.state.show_resolved)
			assert.is_false(filter.state.show_outdated)
		end)
	end)

	describe("label", function()
		it("shows both [unresolved+current] by default", function()
			-- Defaults hide both, so the label reflects both restrictions.
			assert.equals("[unresolved+current] ", filter.label())
		end)

		it("returns empty when both filters are toggled on", function()
			filter.toggle("resolved")
			filter.toggle("outdated")
			assert.equals("", filter.label())
		end)

		it("shows just 'unresolved' when only resolved is hidden", function()
			filter.toggle("outdated") -- show outdated; resolved still hidden
			assert.equals("[unresolved] ", filter.label())
		end)

		it("shows just 'current' when only outdated is hidden", function()
			filter.toggle("resolved") -- show resolved; outdated still hidden
			assert.equals("[current] ", filter.label())
		end)
	end)

	describe("persistence across refresh", function()
		it("state survives a no-op refresh cycle", function()
			filter.reset()
			filter.toggle("resolved")
			assert.is_true(filter.state.show_resolved)
			-- M.refresh in init.lua intentionally does NOT call filter.reset anymore.
			-- This test locks that in by simulating: nothing calls filter.reset, state stays.
			assert.is_true(filter.state.show_resolved)
			filter.reset()
		end)
	end)

	describe("state_glyph", function()
		it("returns active glyph for normal threads", function()
			local g, hl = filter.state_glyph({ is_resolved = false, is_outdated = false })
			assert.equals("·", g)
			assert.equals("NonText", hl)
		end)

		it("returns resolved glyph for resolved threads (regardless of outdated)", function()
			local g, hl = filter.state_glyph({ is_resolved = true })
			assert.equals("✓", g)
			assert.equals("Comment", hl)
			-- Resolved wins over outdated when both flags are set.
			g = filter.state_glyph({ is_resolved = true, is_outdated = true })
			assert.equals("✓", g)
		end)

		it("returns outdated glyph for outdated, non-resolved threads", function()
			local g, hl = filter.state_glyph({ is_outdated = true })
			assert.equals("~", g)
			assert.equals("DiagnosticHint", hl)
		end)

		it("returns active glyph for nil thread (defensive)", function()
			local g = filter.state_glyph(nil)
			assert.equals("·", g)
		end)
	end)
end)
