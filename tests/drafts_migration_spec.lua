describe("drafts v1 → v2 migration", function()
	local d
	before_each(function()
		package.loaded["pr.drafts"] = nil
		d = require("pr.drafts")
	end)

	local function write_v1(path, content_table)
		vim.fn.writefile({ vim.fn.json_encode(content_table) }, path)
	end

	it("loads v1 flat map as edit_drafts and preserves data", function()
		local path = vim.fn.tempname()
		-- v1 shape: { "<comment_id>": { body, updated_at } }
		write_v1(path, {
			["c1"] = { body = "first edit", updated_at = "2026-01-01T00:00:00Z" },
			["c2"] = { body = "second edit", updated_at = "2026-01-02T00:00:00Z" },
		})
		d._set_path(path)
		local got1 = d.get_edit("c1")
		local got2 = d.get_edit("c2")
		assert.is_not_nil(got1)
		assert.is_not_nil(got2)
		assert.equals("first edit", got1.body)
		assert.equals("2026-01-01T00:00:00Z", got1.updated_at)
		assert.equals("second edit", got2.body)
	end)

	it("next write persists as v2 (saves alongside the migrated entries)", function()
		local path = vim.fn.tempname()
		write_v1(path, { ["c1"] = { body = "v1 edit", updated_at = "t" } })
		d._set_path(path)
		-- Trigger a write by saving a new draft of a different kind.
		d.save_new("a.lua:1:1", { body = "new" })
		-- Reload and verify both the migrated edit AND the new kind survive.
		d._reload()
		assert.equals("v1 edit", d.get_edit("c1").body)
		assert.equals("new", d.get_new("a.lua:1:1").body)
		-- The on-disk file now has version=2; verify by reading raw.
		local raw = vim.fn.readfile(path)
		local decoded = vim.fn.json_decode(table.concat(raw, "\n"))
		assert.equals(2, decoded.version)
		assert.is_not_nil(decoded.edit_drafts.c1)
		assert.is_not_nil(decoded.new_drafts["a.lua:1:1"])
	end)

	it("ignores new_drafts/reply_drafts in v1 (they didn't exist) and starts them empty", function()
		local path = vim.fn.tempname()
		write_v1(path, { ["c1"] = { body = "v1 edit" } })
		d._set_path(path)
		assert.is_nil(d.get_new("any-key"))
		assert.is_nil(d.get_reply("any-thread"))
	end)
end)
