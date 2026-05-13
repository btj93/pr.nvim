local gitlab = require("pr.providers.gitlab")

local function note(overrides)
	return vim.tbl_deep_extend("force", {
		id = "gid://gitlab/Note/100",
		author = { username = "alice" },
		body = "hi",
		createdAt = "2024-01-01T00:00:00Z",
		updatedAt = "2024-01-01T00:00:00Z",
		system = false,
		userPermissions = { adminNote = false, awardEmoji = true },
		position = { newLine = 5, oldLine = vim.NIL, newPath = "src/foo.lua", oldPath = vim.NIL },
		awardEmoji = { nodes = {} },
	}, overrides or {})
end

local function discussion(thread_overrides, notes)
	return vim.tbl_deep_extend("force", {
		id = "gid://gitlab/Discussion/abc123",
		resolvable = true,
		resolved = false,
		resolvedBy = vim.NIL,
	}, thread_overrides or {}, { notes = { nodes = notes or { note() } } })
end

local function response(discussions, diff_refs)
	return {
		data = {
			project = {
				mergeRequest = {
					diffRefs = diff_refs or vim.NIL,
					discussions = { nodes = discussions or { discussion() } },
				},
			},
		},
	}
end

describe("gitlab._normalize_comments", function()
	it("returns nil for malformed responses", function()
		assert.is_nil((gitlab._normalize_comments(nil, "")))
		assert.is_nil((gitlab._normalize_comments({}, "")))
		assert.is_nil((gitlab._normalize_comments({ data = {} }, "")))
	end)

	it("returns empty Comments when discussions.nodes is empty", function()
		local c, tc, uc = gitlab._normalize_comments(response({}), "")
		assert.are.same({}, c)
		assert.equals(0, tc)
		assert.equals(0, uc)
	end)

	it("normalizes a single line-anchored discussion", function()
		local c, tc = gitlab._normalize_comments(response(), "")
		assert.equals(1, tc)
		assert.is_not_nil(c["src/foo.lua"])
		local thread = c["src/foo.lua"][1]
		assert.equals("abc123", thread.id)
		assert.equals(1, #thread.comments)
		assert.equals("alice", thread.comments[1].author)
		assert.equals(5, thread.comments[1].start_line)
		assert.equals(5, thread.comments[1].end_line)
	end)

	it("filters out system notes", function()
		local c = gitlab._normalize_comments(response({ discussion(nil, { note({ system = true }) }) }), "")
		assert.are.same({}, c)
	end)

	it("falls back to oldPath / oldLine when newPath / newLine are nil", function()
		local c = gitlab._normalize_comments(
			response({ discussion(nil, { note({ position = { newLine = vim.NIL, oldLine = 42, newPath = vim.NIL, oldPath = "old.lua" } }) }) }),
			""
		)
		assert.is_not_nil(c["old.lua"])
		assert.equals(42, c["old.lua"][1].comments[1].end_line)
	end)

	it("drops notes without a usable line/path", function()
		local c = gitlab._normalize_comments(
			response({ discussion(nil, { note({ position = { newLine = vim.NIL, oldLine = vim.NIL, newPath = vim.NIL, oldPath = vim.NIL } }) }) }),
			""
		)
		assert.are.same({}, c)
	end)

	it("translates award emoji name to canonical content key", function()
		local c = gitlab._normalize_comments(
			response({
				discussion(nil, {
					note({
						awardEmoji = { nodes = { { id = "gid://gitlab/AwardEmoji/1", name = "tada", user = { username = "alice" } } } },
					}),
				}),
			}),
			""
		)
		local rg = c["src/foo.lua"][1].comments[1].reaction_groups
		assert.equals(1, #rg)
		assert.equals("HOORAY", rg[1].content)
	end)

	it("passes unknown award emoji name through uppercased", function()
		local c = gitlab._normalize_comments(
			response({
				discussion(nil, {
					note({
						awardEmoji = { nodes = { { id = "gid://gitlab/AwardEmoji/1", name = "custom_emoji", user = { username = "alice" } } } },
					}),
				}),
			}),
			""
		)
		local rg = c["src/foo.lua"][1].comments[1].reaction_groups
		assert.equals("CUSTOM_EMOJI", rg[1].content)
	end)

	it("derives viewer_did_author from git_user", function()
		local c1 = gitlab._normalize_comments(response(), "alice")
		assert.is_true(c1["src/foo.lua"][1].comments[1].viewer_did_author)

		local c2 = gitlab._normalize_comments(response(), "bob")
		assert.is_false(c2["src/foo.lua"][1].comments[1].viewer_did_author)

		local c3 = gitlab._normalize_comments(response(), "")
		assert.is_false(c3["src/foo.lua"][1].comments[1].viewer_did_author)
	end)

	it("populates viewer_can_resolve / viewer_can_unresolve from resolvable + resolved", function()
		local c1 = gitlab._normalize_comments(response({ discussion({ resolvable = true, resolved = false }) }), "")
		assert.is_true(c1["src/foo.lua"][1].viewer_can_resolve)
		assert.is_false(c1["src/foo.lua"][1].viewer_can_unresolve)

		local c2 = gitlab._normalize_comments(response({ discussion({ resolvable = true, resolved = true, resolvedBy = { username = "bob" } }) }), "")
		assert.is_false(c2["src/foo.lua"][1].viewer_can_resolve)
		assert.is_true(c2["src/foo.lua"][1].viewer_can_unresolve)
		assert.equals("bob", c2["src/foo.lua"][1].resolved_by)
	end)

	it("populates viewer_can_update from userPermissions.adminNote", function()
		local c = gitlab._normalize_comments(response({ discussion(nil, { note({ userPermissions = { adminNote = true, awardEmoji = true } }) }) }), "")
		assert.is_true(c["src/foo.lua"][1].comments[1].viewer_can_update)
		assert.is_true(c["src/foo.lua"][1].comments[1].viewer_can_delete)
	end)

	it("populates viewer_can_react from userPermissions.awardEmoji", function()
		local c = gitlab._normalize_comments(response({ discussion(nil, { note({ userPermissions = { adminNote = false, awardEmoji = false } }) }) }), "")
		assert.is_false(c["src/foo.lua"][1].comments[1].viewer_can_react)
	end)

	it("extracts diff_refs from the response", function()
		local _, _, _, refs = gitlab._normalize_comments(response(nil, { baseSha = "B", headSha = "H", startSha = "S" }), "")
		assert.are.same({ base_sha = "B", head_sha = "H", start_sha = "S" }, refs)
	end)

	it("returns nil diff_refs when not present", function()
		local _, _, _, refs = gitlab._normalize_comments(response(), "")
		assert.is_nil(refs)
	end)

	it("sets is_outdated when note has only oldLine (line removed from head)", function()
		local c = gitlab._normalize_comments(
			response({ discussion(nil, { note({ position = { newLine = vim.NIL, oldLine = 7, newPath = "x.lua", oldPath = "x.lua" } }) }) }),
			""
		)
		assert.is_not_nil(c["x.lua"])
		assert.is_true(c["x.lua"][1].is_outdated)
		assert.equals(7, c["x.lua"][1].comments[1].end_line)
	end)

	it("is_outdated is false when newLine is present", function()
		local c = gitlab._normalize_comments(response(), "")
		assert.is_false(c["src/foo.lua"][1].is_outdated)
	end)

	it("a thread with one outdated note marks the whole thread outdated", function()
		local c = gitlab._normalize_comments(
			response({
				discussion(nil, {
					note({ id = "gid://gitlab/Note/1", position = { newLine = 5, oldLine = vim.NIL, newPath = "x.lua", oldPath = "x.lua" } }),
					note({ id = "gid://gitlab/Note/2", position = { newLine = vim.NIL, oldLine = 7, newPath = "x.lua", oldPath = "x.lua" } }),
				}),
			}),
			""
		)
		assert.is_true(c["x.lua"][1].is_outdated)
	end)

	it("uses lineRange for start_line / end_line when present", function()
		local c = gitlab._normalize_comments(
			response({
				discussion(nil, {
					note({
						position = {
							newLine = 10,
							oldLine = vim.NIL,
							newPath = "x.lua",
							oldPath = vim.NIL,
							lineRange = {
								start = { newLine = 7, oldLine = vim.NIL },
								["end"] = { newLine = 10, oldLine = vim.NIL },
							},
						},
					}),
				}),
			}),
			""
		)
		assert.equals(7, c["x.lua"][1].comments[1].start_line)
		assert.equals(10, c["x.lua"][1].comments[1].end_line)
	end)

	it("falls back to single line when lineRange is nil", function()
		local c = gitlab._normalize_comments(response(), "")
		local cm = c["src/foo.lua"][1].comments[1]
		assert.equals(5, cm.start_line)
		assert.equals(5, cm.end_line)
	end)
end)
