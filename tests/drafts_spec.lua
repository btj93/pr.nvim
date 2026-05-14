describe("drafts module", function()
	local d
	before_each(function()
		package.loaded["pr.drafts"] = nil
		d = require("pr.drafts")
		d._set_path(vim.fn.tempname())
	end)

	describe("edit drafts", function()
		it("round-trips save/get", function()
			d.save_edit("c1", { body = "hi", updated_at = "t1" })
			d._reload()
			local got = d.get_edit("c1")
			assert.is_not_nil(got)
			assert.equals("hi", got.body)
			assert.equals("t1", got.updated_at)
		end)

		it("delete removes only the keyed entry", function()
			d.save_edit("c1", { body = "a", updated_at = "t1" })
			d.save_edit("c2", { body = "b", updated_at = "t2" })
			d.delete_edit("c1")
			assert.is_nil(d.get_edit("c1"))
			assert.equals("b", d.get_edit("c2").body)
		end)

		it("get_edit returns nil for unknown id", function()
			assert.is_nil(d.get_edit("nope"))
		end)
	end)

	describe("new drafts (keyed by path:start:end)", function()
		it("round-trips save/get", function()
			d.save_new("a.lua:3:5", { body = "new comment" })
			d._reload()
			assert.equals("new comment", d.get_new("a.lua:3:5").body)
		end)

		it("delete works", function()
			d.save_new("a.lua:3:5", { body = "x" })
			d.delete_new("a.lua:3:5")
			assert.is_nil(d.get_new("a.lua:3:5"))
		end)
	end)

	describe("reply drafts (keyed by thread id)", function()
		it("round-trips save/get", function()
			d.save_reply("THREAD_1", { body = "reply" })
			d._reload()
			assert.equals("reply", d.get_reply("THREAD_1").body)
		end)

		it("isolates between kinds and ids", function()
			d.save_edit("X", { body = "edit-X" })
			d.save_new("X", { body = "new-X" })
			d.save_reply("X", { body = "reply-X" })
			assert.equals("edit-X", d.get_edit("X").body)
			assert.equals("new-X", d.get_new("X").body)
			assert.equals("reply-X", d.get_reply("X").body)
		end)
	end)

	describe("drafts.enabled = false gate", function()
		local dd
		before_each(function()
			package.loaded["pr.config"] = nil
			package.loaded["pr.drafts"] = nil
			dd = require("pr.drafts")
			dd._set_path(vim.fn.tempname())
			require("pr.config").setup({ drafts = { enabled = false } })
		end)

		after_each(function()
			package.loaded["pr.config"] = nil
			-- Reload config so subsequent specs see the default (enabled = true).
			require("pr.config")
		end)

		it("save_edit is a no-op when disabled", function()
			dd.save_edit("c1", { body = "hi" })
			assert.is_nil(dd.get_edit("c1"))
		end)

		it("save_new is a no-op when disabled", function()
			dd.save_new("a:1:1", { body = "hi" })
			assert.is_nil(dd.get_new("a:1:1"))
		end)

		it("save_reply is a no-op when disabled", function()
			dd.save_reply("T1", { body = "hi" })
			assert.is_nil(dd.get_reply("T1"))
		end)

		it("get_* returns nil when disabled even if file has data", function()
			-- Enable, write data, then disable and verify reads return nil.
			require("pr.config").setup({ drafts = { enabled = true } })
			dd.save_edit("c1", { body = "x" })
			dd.save_new("k1", { body = "y" })
			dd.save_reply("t1", { body = "z" })
			require("pr.config").setup({ drafts = { enabled = false } })
			assert.is_nil(dd.get_edit("c1"))
			assert.is_nil(dd.get_new("k1"))
			assert.is_nil(dd.get_reply("t1"))
		end)
	end)

	describe("persistence", function()
		it("survives _reload (atomic write actually persists)", function()
			d.save_edit("c1", { body = "persistent", updated_at = "t" })
			d._reload()
			assert.equals("persistent", d.get_edit("c1").body)
		end)

		it("handles missing file gracefully", function()
			d._set_path(vim.fn.tempname() .. "-nonexistent")
			assert.is_nil(d.get_edit("nope"))
		end)

		it("handles corrupted JSON gracefully", function()
			local path = vim.fn.tempname()
			vim.fn.writefile({ "{ this is not valid json" }, path)
			d._set_path(path)
			-- Should not crash; should return empty state.
			assert.is_nil(d.get_edit("nope"))
			-- Should be writable on top of the corrupted file.
			d.save_edit("c1", { body = "x" })
			d._reload()
			assert.equals("x", d.get_edit("c1").body)
		end)
	end)
end)
