local bb = require("pr.providers.bitbucket")

local function comment(overrides)
	return vim.tbl_deep_extend("force", {
		id = 100,
		content = { raw = "hi" },
		user = { nickname = "alice" },
		created_on = "2024-01-01T00:00:00Z",
		updated_on = "2024-01-01T00:00:00Z",
		deleted = false,
		parent = vim.NIL,
		inline = { path = "src/foo.lua", to = 5, from = vim.NIL },
		resolution = vim.NIL,
	}, overrides or {})
end

local function response(values)
	return { values = values or { comment() } }
end

describe("bitbucket._normalize_comments", function()
	it("returns nil for malformed responses", function()
		assert.is_nil((bb._normalize_comments(nil, "")))
		assert.is_nil((bb._normalize_comments({}, "")))
	end)

	it("returns empty Comments when values is empty", function()
		local c, tc, uc = bb._normalize_comments(response({}), "")
		assert.are.same({}, c)
		assert.equals(0, tc)
		assert.equals(0, uc)
	end)

	it("normalizes a single line-anchored root comment", function()
		local c, tc = bb._normalize_comments(response(), "")
		assert.equals(1, tc)
		assert.is_not_nil(c["src/foo.lua"])
		local thread = c["src/foo.lua"][1]
		assert.equals("100", thread.id)
		assert.equals(1, #thread.comments)
		assert.equals("alice", thread.comments[1].author)
		assert.equals(5, thread.comments[1].start_line)
		assert.equals(5, thread.comments[1].end_line)
	end)

	it("groups replies into the parent's thread", function()
		local c = bb._normalize_comments(
			response({
				comment({ id = 100, content = { raw = "root" } }),
				comment({ id = 101, parent = { id = 100 }, inline = vim.NIL, content = { raw = "reply1" } }),
				comment({ id = 102, parent = { id = 101 }, inline = vim.NIL, content = { raw = "reply2" } }),
			}),
			""
		)
		assert.equals(3, #c["src/foo.lua"][1].comments)
		assert.equals("root", c["src/foo.lua"][1].comments[1].body)
		assert.equals("reply1", c["src/foo.lua"][1].comments[2].body)
		assert.equals("reply2", c["src/foo.lua"][1].comments[3].body)
	end)

	it("treats orphan replies (missing parent) as their own root", function()
		local c = bb._normalize_comments(
			response({
				comment({ id = 200, parent = { id = 9999 } }),
			}),
			""
		)
		-- Orphan becomes its own root; since it has inline, it shows up.
		assert.is_not_nil(c["src/foo.lua"])
	end)

	it("excludes deleted comments from the thread", function()
		local c = bb._normalize_comments(
			response({
				comment({ id = 100 }),
				comment({ id = 101, parent = { id = 100 }, inline = vim.NIL, deleted = true }),
				comment({ id = 102, parent = { id = 100 }, inline = vim.NIL, content = { raw = "kept" } }),
			}),
			""
		)
		assert.equals(2, #c["src/foo.lua"][1].comments)
	end)

	it("drops file-level (no inline) root comments", function()
		local c, tc = bb._normalize_comments(response({ comment({ inline = vim.NIL }) }), "")
		assert.are.same({}, c)
		assert.equals(0, tc)
	end)

	it("falls back to inline.from when to is nil", function()
		local c = bb._normalize_comments(response({ comment({ inline = { path = "x.lua", to = vim.NIL, from = 7 } }) }), "")
		assert.is_not_nil(c["x.lua"])
		assert.equals(7, c["x.lua"][1].comments[1].end_line)
	end)

	it("populates resolved + resolved_by from resolution", function()
		local c, tc, uc = bb._normalize_comments(response({ comment({ resolution = { user = { nickname = "bob" } } }) }), "")
		assert.equals(1, tc)
		assert.equals(0, uc)
		assert.is_true(c["src/foo.lua"][1].is_resolved)
		assert.equals("bob", c["src/foo.lua"][1].resolved_by)
		assert.is_false(c["src/foo.lua"][1].viewer_can_resolve)
		assert.is_true(c["src/foo.lua"][1].viewer_can_unresolve)
	end)

	it("derives viewer_did_author from git_user nickname", function()
		local c1 = bb._normalize_comments(response(), "alice")
		assert.is_true(c1["src/foo.lua"][1].comments[1].viewer_did_author)

		local c2 = bb._normalize_comments(response(), "bob")
		assert.is_false(c2["src/foo.lua"][1].comments[1].viewer_did_author)
	end)

	it("uses display_name when nickname is missing", function()
		local v = comment()
		v.user = { display_name = "Alice Smith" }
		local c = bb._normalize_comments(response({ v }), "")
		assert.equals("Alice Smith", c["src/foo.lua"][1].comments[1].author)
	end)

	it("never sets viewer_can_react to true (bitbucket has no reactions)", function()
		local c = bb._normalize_comments(response(), "alice")
		assert.is_false(c["src/foo.lua"][1].comments[1].viewer_can_react)
		assert.are.same({}, c["src/foo.lua"][1].comments[1].reaction_groups)
	end)

	it("groups threads per file when multiple", function()
		local c = bb._normalize_comments(
			response({
				comment({ id = 100, inline = { path = "a.lua", to = 1 } }),
				comment({ id = 200, inline = { path = "b.lua", to = 2 } }),
				comment({ id = 300, inline = { path = "a.lua", to = 3 } }),
			}),
			""
		)
		assert.equals(2, #c["a.lua"])
		assert.equals(1, #c["b.lua"])
	end)

	it("marks is_outdated when inline.path is not in current_paths", function()
		local c = bb._normalize_comments(response(), "", { ["other.lua"] = true })
		assert.is_true(c["src/foo.lua"][1].is_outdated)
	end)

	it("is_outdated is false when inline.path is in current_paths", function()
		local c = bb._normalize_comments(response(), "", { ["src/foo.lua"] = true })
		assert.is_false(c["src/foo.lua"][1].is_outdated)
	end)

	it("is_outdated stays false when current_paths is nil (back-compat)", function()
		local c = bb._normalize_comments(response(), "", nil)
		assert.is_false(c["src/foo.lua"][1].is_outdated)
	end)

	it("reads multi-line inline with both from and to", function()
		local c = bb._normalize_comments(response({ comment({ inline = { path = "x.lua", from = 7, to = 10 } }) }), "")
		assert.equals(7, c["x.lua"][1].comments[1].start_line)
		assert.equals(10, c["x.lua"][1].comments[1].end_line)
	end)

	it("collapses to single line when only `to` is present", function()
		local c = bb._normalize_comments(response({ comment({ inline = { path = "x.lua", to = 5 } }) }), "")
		assert.equals(5, c["x.lua"][1].comments[1].start_line)
		assert.equals(5, c["x.lua"][1].comments[1].end_line)
	end)
end)
