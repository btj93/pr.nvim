describe("pr.highlights", function()
	local calls
	before_each(function()
		calls = {}
		_G._orig_set_hl = vim.api.nvim_set_hl
		vim.api.nvim_set_hl = function(ns, name, def)
			table.insert(calls, { ns = ns, name = name, def = def })
		end
		package.loaded["pr.highlights"] = nil
		package.loaded["pr.config"] = nil
	end)
	after_each(function()
		vim.api.nvim_set_hl = _G._orig_set_hl
	end)

	it("applies hl for every owned group with default = true", function()
		require("pr.config").setup({})
		require("pr.highlights").apply()
		assert.is_true(#calls > 10)
		for _, c in ipairs(calls) do
			assert.is_true(c.def.default == true, "missing default = true on " .. c.name)
		end
	end)

	it("uses custom colors from config", function()
		require("pr.config").setup({ colors = { diff_add_bg = "#0d3a0d" } })
		require("pr.highlights").apply()
		local seen = nil
		for _, c in ipairs(calls) do
			if c.name == "PRDiffAdd" then
				seen = c.def
			end
		end
		assert.is_not_nil(seen)
		assert.equals("#0d3a0d", seen.bg)
	end)

	it("re-applies on ColorScheme event (autocmd from init.lua)", function()
		-- Calling pr.setup installs the ColorScheme autocmd in PRColorScheme augroup.
		package.loaded["pr"] = nil
		require("pr").setup({})
		local count_after_setup = #calls
		-- Fire ColorScheme; the autocmd should call apply() again.
		vim.cmd("doautocmd ColorScheme")
		assert.is_true(#calls > count_after_setup, "ColorScheme did not re-apply highlights")
	end)
end)
