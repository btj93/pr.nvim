describe("drafts.invalidate_orphans", function()
	local d
	before_each(function()
		package.loaded["pr.drafts"] = nil
		package.loaded["pr.config"] = nil
		d = require("pr.drafts")
		require("pr.config").setup({})
		d._set_path(vim.fn.tempname())
	end)

	it("drops edit drafts whose comment_id is not in known.comment_ids", function()
		d.save_edit("c1", { body = "stale" })
		d.save_edit("c2", { body = "alive" })
		d.invalidate_orphans({
			paths = {},
			thread_ids = {},
			comment_ids = { c2 = true },
		})
		assert.is_nil(d.get_edit("c1"))
		assert.equals("alive", d.get_edit("c2").body)
	end)

	it("drops new drafts whose path is not in known.paths", function()
		d.save_new("a.lua:1:2", { body = "alive" })
		d.save_new("gone.lua:3:4", { body = "stale" })
		d.invalidate_orphans({
			paths = { ["a.lua"] = true },
			thread_ids = {},
			comment_ids = {},
		})
		assert.equals("alive", d.get_new("a.lua:1:2").body)
		assert.is_nil(d.get_new("gone.lua:3:4"))
	end)

	it("drops reply drafts whose thread id is not in known.thread_ids", function()
		d.save_reply("T1", { body = "alive" })
		d.save_reply("T2", { body = "stale" })
		d.invalidate_orphans({
			paths = {},
			thread_ids = { T1 = true },
			comment_ids = {},
		})
		assert.equals("alive", d.get_reply("T1").body)
		assert.is_nil(d.get_reply("T2"))
	end)

	it("is a no-op when all drafts are still known", function()
		d.save_edit("c1", { body = "x" })
		d.save_new("a.lua:1:2", { body = "y" })
		d.save_reply("T1", { body = "z" })
		d.invalidate_orphans({
			paths = { ["a.lua"] = true },
			thread_ids = { T1 = true },
			comment_ids = { c1 = true },
		})
		assert.equals("x", d.get_edit("c1").body)
		assert.equals("y", d.get_new("a.lua:1:2").body)
		assert.equals("z", d.get_reply("T1").body)
	end)

	it("preserves drafts of kinds whose known set is missing (no-opinion semantics)", function()
		-- Missing sets are treated as 'no opinion' rather than 'empty', so
		-- accidentally calling with {} doesn't destroy everything.
		d.save_edit("c1", { body = "x" })
		d.save_new("a.lua:1:2", { body = "y" })
		d.save_reply("T1", { body = "z" })
		d.invalidate_orphans({})
		assert.equals("x", d.get_edit("c1").body)
		assert.equals("y", d.get_new("a.lua:1:2").body)
		assert.equals("z", d.get_reply("T1").body)
	end)
end)
