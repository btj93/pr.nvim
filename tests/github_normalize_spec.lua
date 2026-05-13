local github = require("pr.providers.github")

-- Helper to build a minimal valid GraphQL response for one thread.
local function single_thread_response(thread_overrides, comment_overrides)
	local thread = vim.tbl_deep_extend("force", {
		id = "T1",
		isResolved = false,
		resolvedBy = vim.NIL,
		isOutdated = false,
		isCollapsed = false,
		viewerCanReply = true,
		viewerCanResolve = true,
		viewerCanUnresolve = false,
	}, thread_overrides or {})

	local comment = vim.tbl_deep_extend("force", {
		databaseId = 100,
		author = { login = "alice" },
		body = "hi",
		path = "src/foo.lua",
		publishedAt = "2024-01-01T00:00:00Z",
		updatedAt = "2024-01-01T00:00:00Z",
		viewerDidAuthor = false,
		viewerCanUpdate = false,
		viewerCanDelete = false,
		viewerCanReact = true,
		line = 5,
		startLine = vim.NIL,
		originalLine = vim.NIL,
		originalStartLine = vim.NIL,
		reactionGroups = {},
		reactions = { nodes = {} },
	}, comment_overrides or {})

	return {
		data = {
			repository = {
				pullRequest = {
					reviewThreads = {
						edges = {
							{
								node = vim.tbl_deep_extend("force", thread, {
									comments = { edges = { { node = comment } } },
								}),
							},
						},
					},
				},
			},
		},
	}
end

describe("github._normalize_comments", function()
	it("returns nil for empty or malformed responses", function()
		assert.is_nil((github._normalize_comments(nil)))
		assert.is_nil((github._normalize_comments({})))
		assert.is_nil((github._normalize_comments({ data = {} })))
		assert.is_nil((github._normalize_comments({ data = { repository = {} } })))
	end)

	it("returns empty Comments when reviewThreads.edges is empty", function()
		local data = {
			data = { repository = { pullRequest = { reviewThreads = { edges = {} } } } },
		}
		local c, tc, uc = github._normalize_comments(data)
		assert.are.same({}, c)
		assert.equals(0, tc)
		assert.equals(0, uc)
	end)

	it("normalizes a single line-anchored thread", function()
		local c, tc, uc = github._normalize_comments(single_thread_response())
		assert.equals(1, tc)
		assert.equals(1, uc)
		assert.is_not_nil(c["src/foo.lua"])
		local thread = c["src/foo.lua"][1]
		assert.equals("T1", thread.id)
		assert.is_false(thread.is_resolved)
		assert.is_false(thread.is_outdated)
		assert.equals(1, #thread.comments)
		assert.equals("alice", thread.comments[1].author)
		assert.equals(5, thread.comments[1].start_line)
		assert.equals(5, thread.comments[1].end_line)
	end)

	it("derives start_line from startLine when present", function()
		local data = single_thread_response(nil, { line = 10, startLine = 7 })
		local c = github._normalize_comments(data)
		local cm = c["src/foo.lua"][1].comments[1]
		assert.equals(7, cm.start_line)
		assert.equals(10, cm.end_line)
	end)

	it("falls back to originalLine when line is vim.NIL", function()
		local data = single_thread_response(nil, { line = vim.NIL, originalLine = 42 })
		local c = github._normalize_comments(data)
		assert.is_not_nil(c["src/foo.lua"])
		assert.equals(42, c["src/foo.lua"][1].comments[1].end_line)
	end)

	it("drops file-level comments (no line/originalLine)", function()
		local data = single_thread_response(nil, { line = vim.NIL, originalLine = vim.NIL })
		local c, tc = github._normalize_comments(data)
		-- File-level comments are filtered out of thread.comments; the thread
		-- shell still exists (counted toward thread_count) but carries no
		-- comments and is keyed under "" because `file` was never assigned.
		assert.is_nil(c["src/foo.lua"])
		assert.equals(1, tc)
		assert.is_not_nil(c[""])
		assert.equals(0, #c[""][1].comments)
	end)

	it("populates is_resolved + resolved_by when thread is resolved", function()
		local data = single_thread_response({
			isResolved = true,
			resolvedBy = { login = "bob" },
		})
		local c, tc, uc = github._normalize_comments(data)
		assert.equals(1, tc)
		assert.equals(0, uc)
		assert.is_true(c["src/foo.lua"][1].is_resolved)
		assert.equals("bob", c["src/foo.lua"][1].resolved_by)
	end)

	it("populates is_outdated", function()
		local data = single_thread_response({ isOutdated = true })
		local c = github._normalize_comments(data)
		assert.is_true(c["src/foo.lua"][1].is_outdated)
	end)

	it("normalizes reactions: groups, reactors with database_id, viewerHasReacted", function()
		local data = single_thread_response(nil, {
			reactionGroups = {
				{ content = "THUMBS_UP", viewerHasReacted = true, reactors = { totalCount = 2 } },
			},
			reactions = {
				nodes = {
					{ databaseId = 1, content = "THUMBS_UP", user = { login = "alice" } },
					{ databaseId = 2, content = "THUMBS_UP", user = { login = "bob" } },
				},
			},
		})
		local c = github._normalize_comments(data)
		local rg = c["src/foo.lua"][1].comments[1].reaction_groups
		assert.equals(1, #rg)
		assert.equals("THUMBS_UP", rg[1].content)
		assert.is_true(rg[1].viewerHasReacted)
		assert.equals(2, rg[1].reactors.totalCount)
		assert.equals(2, #rg[1].reactors.nodes)
		assert.equals(1, rg[1].reactors.nodes[1].database_id)
		assert.equals("alice", rg[1].reactors.nodes[1].user)
	end)

	it("counts resolved vs unresolved threads correctly", function()
		local data = {
			data = {
				repository = {
					pullRequest = {
						reviewThreads = {
							edges = {
								{
									node = vim.tbl_deep_extend(
										"force",
										single_thread_response().data.repository.pullRequest.reviewThreads.edges[1].node,
										{ id = "T1", isResolved = false }
									),
								},
								{
									node = vim.tbl_deep_extend(
										"force",
										single_thread_response().data.repository.pullRequest.reviewThreads.edges[1].node,
										{ id = "T2", isResolved = true, resolvedBy = { login = "bob" } }
									),
								},
								{
									node = vim.tbl_deep_extend(
										"force",
										single_thread_response().data.repository.pullRequest.reviewThreads.edges[1].node,
										{ id = "T3", isResolved = false }
									),
								},
							},
						},
					},
				},
			},
		}
		local _, tc, uc = github._normalize_comments(data)
		assert.equals(3, tc)
		assert.equals(2, uc)
	end)

	it("merges threads into per-file lists", function()
		local node1 = single_thread_response(nil, { path = "a.lua", line = 1 }).data.repository.pullRequest.reviewThreads.edges[1].node
		node1.id = "T1"
		local node2 = single_thread_response(nil, { path = "b.lua", line = 2 }).data.repository.pullRequest.reviewThreads.edges[1].node
		node2.id = "T2"
		local node3 = single_thread_response(nil, { path = "a.lua", line = 3 }).data.repository.pullRequest.reviewThreads.edges[1].node
		node3.id = "T3"

		local data = {
			data = {
				repository = {
					pullRequest = {
						reviewThreads = {
							edges = { { node = node1 }, { node = node2 }, { node = node3 } },
						},
					},
				},
			},
		}
		local c = github._normalize_comments(data)
		assert.equals(2, #c["a.lua"])
		assert.equals(1, #c["b.lua"])
	end)
end)
