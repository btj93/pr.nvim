local parse = require("pr.providers.github")._parse_diff_hunks

describe("parse_diff_hunks", function()
	it("returns empty result for empty input", function()
		assert.are.same({}, parse({}))
	end)

	it("ignores diff lines before the first file header", function()
		assert.are.same({}, parse({ "@@ -1,1 +1,1 @@", " line", "+added" }))
	end)

	it("captures a pure addition as type Add", function()
		local result = parse({
			"diff --git a/foo.txt b/foo.txt",
			"@@ -1,2 +1,3 @@",
			" context",
			"+added line",
			" context2",
		})
		assert.are.same({
			["foo.txt"] = { { hunk_start = 2, hunk_end = 2, type = "Add" } },
		}, result)
	end)

	it("captures a multi-line addition spanning the right range", function()
		local result = parse({
			"diff --git a/foo.txt b/foo.txt",
			"@@ -1,1 +1,3 @@",
			"+a",
			"+b",
			" c",
		})
		assert.are.same({
			["foo.txt"] = { { hunk_start = 1, hunk_end = 2, type = "Add" } },
		}, result)
	end)

	it("captures a pure deletion as type Del with single-line range", function()
		local result = parse({
			"diff --git a/foo.txt b/foo.txt",
			"@@ -1,3 +1,2 @@",
			" context",
			"-deleted",
			" context2",
		})
		assert.are.same({
			["foo.txt"] = { { hunk_start = 2, hunk_end = 2, type = "Del" } },
		}, result)
	end)

	it("captures an add-and-delete block as type Change", function()
		local result = parse({
			"diff --git a/foo.txt b/foo.txt",
			"@@ -1,2 +1,2 @@",
			" context",
			"-old",
			"+new",
		})
		assert.are.same({
			["foo.txt"] = { { hunk_start = 2, hunk_end = 2, type = "Change" } },
		}, result)
	end)

	it("breaks contiguous change blocks on context lines", function()
		local result = parse({
			"diff --git a/foo.txt b/foo.txt",
			"@@ -1,5 +1,5 @@",
			" a",
			"+inserted1",
			" b",
			"+inserted2",
			" c",
		})
		assert.are.same({
			["foo.txt"] = {
				{ hunk_start = 2, hunk_end = 2, type = "Add" },
				{ hunk_start = 4, hunk_end = 4, type = "Add" },
			},
		}, result)
	end)

	it("handles multiple hunks in the same file", function()
		local result = parse({
			"diff --git a/foo.txt b/foo.txt",
			"@@ -1,1 +1,2 @@",
			" a",
			"+inserted",
			"@@ -10,1 +11,2 @@",
			" x",
			"+also_inserted",
		})
		assert.are.same({
			["foo.txt"] = {
				{ hunk_start = 2, hunk_end = 2, type = "Add" },
				{ hunk_start = 12, hunk_end = 12, type = "Add" },
			},
		}, result)
	end)

	it("handles multiple files in one diff", function()
		local result = parse({
			"diff --git a/foo.txt b/foo.txt",
			"@@ -1,1 +1,2 @@",
			" a",
			"+x",
			"diff --git a/bar.txt b/bar.txt",
			"@@ -1,1 +1,2 @@",
			" b",
			"+y",
		})
		assert.are.same({
			["foo.txt"] = { { hunk_start = 2, hunk_end = 2, type = "Add" } },
			["bar.txt"] = { { hunk_start = 2, hunk_end = 2, type = "Add" } },
		}, result)
	end)

	it("flushes the trailing block when input ends mid-hunk", function()
		local result = parse({
			"diff --git a/foo.txt b/foo.txt",
			"@@ -1,1 +1,2 @@",
			" a",
			"+trailing",
		})
		assert.are.same({
			["foo.txt"] = { { hunk_start = 2, hunk_end = 2, type = "Add" } },
		}, result)
	end)

	it("classifies del-then-add as Change with end matching the added range", function()
		local result = parse({
			"diff --git a/foo.txt b/foo.txt",
			"@@ -1,3 +1,3 @@",
			" a",
			"-old",
			"+new1",
			"+new2",
		})
		-- block_start is set on '-' (line 2 in new file), block_end advances with each '+'
		assert.are.same({
			["foo.txt"] = { { hunk_start = 2, hunk_end = 3, type = "Change" } },
		}, result)
	end)
end)
