-- Stub the provider before requiring ui so the module loads in the
-- test environment without trying to shell out to `gh` / `git`.
local fake_provider = {
	reaction_palette = {},
	refetch_comment = function(_, cb)
		cb(nil)
	end,
	edit_comment = function(_, _, cb)
		if cb then
			cb(true)
		end
	end,
}
package.loaded["pr.provider"] = {
	get_provider = function()
		return fake_provider
	end,
}

local ui = require("pr.ui")
local config = require("pr.config")

describe("ui._conflict_decision", function()
	it("returns 'proceed' when fresh is nil (provider returned no data)", function()
		assert.equals("proceed", ui._conflict_decision(nil, "2024-01-01T00:00:00Z", 0))
		-- Even if a confirm_choice was given, lack of fresh data short-circuits.
		assert.equals("proceed", ui._conflict_decision(nil, "2024-01-01T00:00:00Z", 1))
		assert.equals("proceed", ui._conflict_decision(nil, "2024-01-01T00:00:00Z", 2))
		assert.equals("proceed", ui._conflict_decision(nil, "2024-01-01T00:00:00Z", 3))
	end)

	it("returns 'proceed' when fresh.updated_at matches snapshot", function()
		local fresh = { updated_at = "2024-01-01T00:00:00Z" }
		assert.equals("proceed", ui._conflict_decision(fresh, "2024-01-01T00:00:00Z", 0))
		-- A matching timestamp means no remote drift; confirm_choice is irrelevant.
		assert.equals("proceed", ui._conflict_decision(fresh, "2024-01-01T00:00:00Z", 1))
		assert.equals("proceed", ui._conflict_decision(fresh, "2024-01-01T00:00:00Z", 2))
	end)

	it("returns 'overwrite' when timestamps differ and user picks 1", function()
		local fresh = { updated_at = "2024-01-02T00:00:00Z" }
		assert.equals("overwrite", ui._conflict_decision(fresh, "2024-01-01T00:00:00Z", 1))
	end)

	it("returns 'refresh' when timestamps differ and user picks 2", function()
		local fresh = { updated_at = "2024-01-02T00:00:00Z" }
		assert.equals("refresh", ui._conflict_decision(fresh, "2024-01-01T00:00:00Z", 2))
	end)

	it("returns 'abort' when timestamps differ and user picks 3", function()
		local fresh = { updated_at = "2024-01-02T00:00:00Z" }
		assert.equals("abort", ui._conflict_decision(fresh, "2024-01-01T00:00:00Z", 3))
	end)

	it("returns 'abort' when timestamps differ and user dismisses (choice == 0)", function()
		-- vim.fn.confirm returns 0 when the dialog is dismissed (e.g. <Esc>).
		-- That's the safest fallback: do nothing.
		local fresh = { updated_at = "2024-01-02T00:00:00Z" }
		assert.equals("abort", ui._conflict_decision(fresh, "2024-01-01T00:00:00Z", 0))
	end)

	it("treats a nil snapshot as a mismatch when fresh has an updated_at", function()
		-- A comment without a recorded snapshot is the same situation as a
		-- mismatch — we should still prompt and obey the user's choice.
		local fresh = { updated_at = "2024-01-02T00:00:00Z" }
		assert.equals("overwrite", ui._conflict_decision(fresh, nil, 1))
		assert.equals("abort", ui._conflict_decision(fresh, nil, 3))
	end)

	it("returns 'proceed' when both updated_at values are nil/empty and match", function()
		-- Some providers (stubs) return empty updated_at. Equal values =
		-- proceed, even when both are empty.
		local fresh = { updated_at = "" }
		assert.equals("proceed", ui._conflict_decision(fresh, "", 0))
	end)
end)

describe("config.conflict_detection", function()
	it("is enabled by default after setup", function()
		package.loaded["pr.config"] = nil
		local cfg = require("pr.config")
		cfg.setup({})
		assert.is_table(cfg.opts.conflict_detection)
		assert.is_true(cfg.opts.conflict_detection.enabled)
	end)

	it("respects an explicit override to false", function()
		package.loaded["pr.config"] = nil
		local cfg = require("pr.config")
		cfg.setup({ conflict_detection = { enabled = false } })
		assert.is_false(cfg.opts.conflict_detection.enabled)
	end)

	-- Restore module state for subsequent specs.
	after_each(function()
		package.loaded["pr.config"] = nil
		require("pr.config").setup({})
	end)
end)

-- Reference `config` so luacheck doesn't flag the require as unused. The
-- describe block above re-requires it after clearing package.loaded.
assert.is_table(config.opts)
