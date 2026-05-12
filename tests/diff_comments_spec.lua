local diff = require("pr.comment")._diff_comments

local function thread(id, opts)
	opts = opts or {}
	return {
		id = id,
		is_resolved = opts.is_resolved or false,
		comments = opts.comments or {},
	}
end

local function comment(database_id, opts)
	opts = opts or {}
	return {
		database_id = database_id,
		body = opts.body or "body",
		updated_at = opts.updated_at or "t0",
	}
end

describe("_diff_comments", function()
	it("returns nil when old snapshot is empty (first refresh)", function()
		assert.is_nil(diff({}, { ["foo.lua"] = { thread("a", { comments = { comment(1) } }) } }))
		assert.is_nil(diff(nil, { ["foo.lua"] = { thread("a", { comments = { comment(1) } }) } }))
	end)

	it("returns nil when nothing changed", function()
		local snap = { ["foo.lua"] = { thread("a", { comments = { comment(1) } }) } }
		assert.is_nil(diff(snap, vim.deepcopy(snap)))
	end)

	it("reports a new thread", function()
		local old = { ["foo.lua"] = { thread("a", { comments = { comment(1) } }) } }
		local new = {
			["foo.lua"] = {
				thread("a", { comments = { comment(1) } }),
				thread("b", { comments = { comment(2) } }),
			},
		}
		assert.are.equal("PR: 1 new thread", diff(old, new))
	end)

	it("reports a deleted thread", function()
		local old = {
			["foo.lua"] = {
				thread("a", { comments = { comment(1) } }),
				thread("b", { comments = { comment(2) } }),
			},
		}
		local new = { ["foo.lua"] = { thread("a", { comments = { comment(1) } }) } }
		assert.are.equal("PR: 1 deleted thread", diff(old, new))
	end)

	it("reports a newly resolved thread", function()
		local old = { ["foo.lua"] = { thread("a", { is_resolved = false, comments = { comment(1) } }) } }
		local new = { ["foo.lua"] = { thread("a", { is_resolved = true, comments = { comment(1) } }) } }
		assert.are.equal("PR: 1 resolved", diff(old, new))
	end)

	it("reports a reopened thread", function()
		local old = { ["foo.lua"] = { thread("a", { is_resolved = true, comments = { comment(1) } }) } }
		local new = { ["foo.lua"] = { thread("a", { is_resolved = false, comments = { comment(1) } }) } }
		assert.are.equal("PR: 1 reopened", diff(old, new))
	end)

	it("reports a new reply on an existing thread", function()
		local old = { ["foo.lua"] = { thread("a", { comments = { comment(1) } }) } }
		local new = { ["foo.lua"] = { thread("a", { comments = { comment(1), comment(2) } }) } }
		assert.are.equal("PR: 1 new reply", diff(old, new))
	end)

	it("does NOT count the first comment of a new thread as a 'new reply'", function()
		-- New thread + its inaugural comment should produce a single "1 new thread" message,
		-- not "1 new thread, 1 new reply".
		local old = { ["foo.lua"] = { thread("a", { comments = { comment(1) } }) } }
		local new = {
			["foo.lua"] = {
				thread("a", { comments = { comment(1) } }),
				thread("b", { comments = { comment(99) } }),
			},
		}
		assert.are.equal("PR: 1 new thread", diff(old, new))
	end)

	it("reports an edited comment (updated_at changed)", function()
		local old = { ["foo.lua"] = { thread("a", { comments = { comment(1, { updated_at = "t0" }) } }) } }
		local new = { ["foo.lua"] = { thread("a", { comments = { comment(1, { updated_at = "t1", body = "edited" }) } }) } }
		assert.are.equal("PR: 1 edited", diff(old, new))
	end)

	it("reports a deleted reply (thread survives)", function()
		local old = { ["foo.lua"] = { thread("a", { comments = { comment(1), comment(2) } }) } }
		local new = { ["foo.lua"] = { thread("a", { comments = { comment(1) } }) } }
		assert.are.equal("PR: 1 deleted comment", diff(old, new))
	end)

	it("does NOT double-count comments belonging to a deleted thread", function()
		-- When a thread is deleted, its comments shouldn't also be reported as 'deleted comment'.
		local old = { ["foo.lua"] = { thread("a", { comments = { comment(1), comment(2) } }) } }
		local new = {}
		assert.are.equal("PR: 1 deleted thread", diff(old, new))
	end)

	it("combines multiple kinds of changes into one comma-separated line", function()
		local old = {
			["foo.lua"] = {
				thread("a", { is_resolved = false, comments = { comment(1, { updated_at = "t0" }) } }),
				thread("b", { comments = { comment(2) } }),
			},
		}
		local new = {
			["foo.lua"] = {
				thread("a", { is_resolved = true, comments = { comment(1, { updated_at = "t1" }), comment(3) } }),
				thread("c", { comments = { comment(4) } }),
			},
		}
		local msg = diff(old, new)
		assert.is_not_nil(msg)
		assert.is_truthy(msg:find("1 new thread", 1, true))
		assert.is_truthy(msg:find("1 new reply", 1, true))
		assert.is_truthy(msg:find("1 resolved", 1, true))
		assert.is_truthy(msg:find("1 edited", 1, true))
		assert.is_truthy(msg:find("1 deleted thread", 1, true))
	end)

	it("pluralizes counts above 1", function()
		local old = {
			["foo.lua"] = {
				thread("a", { comments = { comment(1) } }),
				thread("b", { comments = { comment(2) } }),
			},
		}
		local new = {
			["foo.lua"] = {
				thread("a", { comments = { comment(1) } }),
				thread("b", { comments = { comment(2) } }),
				thread("c", { comments = { comment(3) } }),
				thread("d", { comments = { comment(4) } }),
			},
		}
		assert.are.equal("PR: 2 new threads", diff(old, new))
	end)
end)
