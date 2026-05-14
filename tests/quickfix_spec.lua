describe("quickfix._build_entries", function()
	local qf
	before_each(function()
		package.loaded["pr.quickfix"] = nil
		qf = require("pr.quickfix")
	end)

	local function thread(opts, comments)
		return vim.tbl_extend("force", {
			is_resolved = false,
			is_outdated = false,
			comments = comments or { { author = "alice", body = "fix this", start_line = 5, end_line = 5 } },
		}, opts or {})
	end

	it("returns one entry per included thread", function()
		local comments = {
			["a.lua"] = { thread(), thread({ is_resolved = true }), thread() },
			["b.lua"] = { thread() },
		}
		local entries = qf._build_entries(comments, { kind = "unresolved" }, "/root")
		-- 3 unresolved threads total (the resolved one is filtered out by default)
		assert.equals(3, #entries)
	end)

	it("filters unresolved", function()
		local comments = {
			["a.lua"] = { thread(), thread({ is_resolved = true }) },
		}
		local entries = qf._build_entries(comments, { kind = "unresolved" }, "/root")
		assert.equals(1, #entries)
	end)

	it("filters outdated", function()
		local comments = {
			["a.lua"] = { thread(), thread({ is_outdated = true }) },
		}
		local entries = qf._build_entries(comments, { kind = "outdated" }, "/root")
		assert.equals(1, #entries)
		assert.is_true(comments["a.lua"][2].is_outdated)
	end)

	it("kind = all returns every thread regardless of state", function()
		local comments = {
			["a.lua"] = {
				thread(),
				thread({ is_resolved = true }),
				thread({ is_outdated = true }),
			},
		}
		assert.equals(3, #qf._build_entries(comments, { kind = "all" }, "/root"))
	end)

	it("kind = file restricts to the named path", function()
		local comments = {
			["a.lua"] = { thread() },
			["b.lua"] = { thread() },
		}
		local entries = qf._build_entries(comments, { kind = "file", file = "a.lua" }, "/root")
		assert.equals(1, #entries)
		assert.matches("a.lua", entries[1].filename)
	end)

	it("formats entries with absolute filename, lnum, col=1, text including author and body", function()
		local comments = {
			["foo/bar.lua"] = { thread({}, { { author = "carol", body = "make this idempotent", start_line = 42, end_line = 44 } }) },
		}
		local entries = qf._build_entries(comments, { kind = "unresolved" }, "/repo")
		assert.equals("/repo/foo/bar.lua", entries[1].filename)
		assert.equals(42, entries[1].lnum)
		assert.equals(1, entries[1].col)
		assert.matches("carol", entries[1].text)
		assert.matches("make this idempotent", entries[1].text)
	end)

	it("returns empty for nil/empty comments", function()
		assert.equals(0, #qf._build_entries(nil, { kind = "unresolved" }, "/r"))
		assert.equals(0, #qf._build_entries({}, { kind = "unresolved" }, "/r"))
	end)

	it("truncates very long body in text", function()
		local long = string.rep("x", 200)
		local comments = {
			["a.lua"] = { thread({}, { { author = "a", body = long, start_line = 1, end_line = 1 } }) },
		}
		local entries = qf._build_entries(comments, { kind = "unresolved" }, "/r")
		assert.is_true(#entries[1].text < 150)
	end)
end)
