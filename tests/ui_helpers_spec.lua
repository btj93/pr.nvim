-- Swap in a fake provider before requiring ui so glyph_for sees a controlled palette.
local fake_provider = {
	reaction_palette = {
		{ content = "THUMBS_UP", glyph = "👍" },
		{ content = "HEART", glyph = "❤️" },
	},
}
package.loaded["pr.provider"] = {
	get_provider = function()
		return fake_provider
	end,
}

local ui = require("pr.ui")

describe("ui._glyph_for", function()
	it("returns the palette glyph for a palette content key", function()
		assert.equals("👍", ui._glyph_for("THUMBS_UP"))
		assert.equals("❤️", ui._glyph_for("HEART"))
	end)

	it("falls back to lowercased shortcode for non-palette content", function()
		assert.equals(":fire:", ui._glyph_for("FIRE"))
		assert.equals(":custom_emoji:", ui._glyph_for("CUSTOM_EMOJI"))
	end)

	it("handles content not in palette with empty palette", function()
		fake_provider.reaction_palette = {}
		assert.equals(":thumbs_up:", ui._glyph_for("THUMBS_UP"))
		fake_provider.reaction_palette = {
			{ content = "THUMBS_UP", glyph = "👍" },
			{ content = "HEART", glyph = "❤️" },
		}
	end)

	it("falls back to shortcode when palette is nil", function()
		local saved = fake_provider.reaction_palette
		fake_provider.reaction_palette = nil
		assert.equals(":heart:", ui._glyph_for("HEART"))
		fake_provider.reaction_palette = saved
	end)
end)

describe("ui.format_reaction", function()
	-- The prefix is a 3-codepoint glyph-marker string (space, U+EE62, space) baked
	-- into ui.lua; capture it from a known-empty call rather than hardcoding the
	-- raw bytes here.
	local EMPTY_PREFIX = ui.format_reaction({})

	it("returns empty prefix when no reactions have count > 0", function()
		local s = ui.format_reaction({})
		assert.equals(EMPTY_PREFIX, s)
		-- Sanity check: empty input produces only the prefix (no "(" or "|").
		assert.is_nil(s:find("(", 1, true))
		assert.is_nil(s:find("|", 1, true))
	end)

	it("filters out zero-count reactions", function()
		local s = ui.format_reaction({
			{ content = "THUMBS_UP", reactors = { totalCount = 0 } },
		})
		assert.equals(EMPTY_PREFIX, s)
	end)

	it("renders a single reaction with glyph and count", function()
		local s = ui.format_reaction({
			{ content = "THUMBS_UP", reactors = { totalCount = 3 } },
		})
		assert.is_truthy(s:find("👍", 1, true))
		assert.is_truthy(s:find("3", 1, true))
	end)

	it("joins multiple reactions with ' | '", function()
		local s = ui.format_reaction({
			{ content = "THUMBS_UP", reactors = { totalCount = 2 } },
			{ content = "HEART", reactors = { totalCount = 1 } },
		})
		assert.is_truthy(s:find("👍", 1, true))
		assert.is_truthy(s:find("❤️", 1, true))
		assert.is_truthy(s:find("|", 1, true))
	end)

	it("uses :shortcode: for non-palette content", function()
		local s = ui.format_reaction({
			{ content = "FIRE", reactors = { totalCount = 1 } },
		})
		assert.is_truthy(s:find(":fire:", 1, true))
	end)
end)

describe("ui._build_menu_items", function()
	local palette = {
		{ content = "THUMBS_UP", glyph = "👍" },
		{ content = "HEART", glyph = "❤️" },
	}

	it("returns one item per palette entry when no existing reactions", function()
		local items = ui._build_menu_items({}, palette)
		assert.equals(2, #items)
		assert.equals("THUMBS_UP", items[1].content)
		assert.equals("👍", items[1].glyph)
		assert.equals(0, items[1].count)
		assert.is_false(items[1].viewer_has_reacted)
		assert.equals("HEART", items[2].content)
	end)

	it("preserves palette order even with existing reactions", function()
		local items = ui._build_menu_items({
			{ content = "HEART", viewerHasReacted = true, reactors = { totalCount = 1, nodes = {} } },
		}, palette)
		assert.equals("THUMBS_UP", items[1].content)
		assert.equals("HEART", items[2].content)
		assert.equals(1, items[2].count)
		assert.is_true(items[2].viewer_has_reacted)
	end)

	it("appends non-palette existing reactions after the palette entries", function()
		local items = ui._build_menu_items({
			{ content = "FIRE", viewerHasReacted = false, reactors = { totalCount = 2, nodes = {} } },
		}, palette)
		assert.equals(3, #items)
		assert.equals("THUMBS_UP", items[1].content)
		assert.equals("HEART", items[2].content)
		assert.equals("FIRE", items[3].content)
		assert.equals(":fire:", items[3].glyph)
	end)

	it("returns empty list when palette is nil and no reactions exist", function()
		local items = ui._build_menu_items({}, nil)
		assert.equals(0, #items)
	end)

	it("returns one item per existing reaction when palette is nil", function()
		local items = ui._build_menu_items({
			{ content = "FIRE", viewerHasReacted = false, reactors = { totalCount = 1, nodes = {} } },
		}, nil)
		assert.equals(1, #items)
		assert.equals("FIRE", items[1].content)
	end)
end)
