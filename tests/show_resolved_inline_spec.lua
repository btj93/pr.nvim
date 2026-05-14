describe("show_resolved_inline", function()
	before_each(function()
		package.loaded["pr.config"] = nil
	end)

	it("defaults to true", function()
		require("pr.config").setup({})
		assert.is_true(require("pr.config").opts.show_resolved_inline)
	end)

	it("accepts user override to false", function()
		require("pr.config").setup({ show_resolved_inline = false })
		assert.is_false(require("pr.config").opts.show_resolved_inline)
	end)

	it("leaves show_outdated_inline default unchanged", function()
		require("pr.config").setup({})
		assert.is_false(require("pr.config").opts.show_outdated_inline)
	end)
end)
