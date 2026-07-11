-- Characterization spec for the snacks picker's pure item builders and confirm
-- dispatchers. These exports are UI-independent: they build finder rows and
-- dispatch file-open / checkout without snacks.nvim installed (snacks.lua
-- pcall-requires "snacks" and the builders/confirms never touch it).
--
-- The assertions below document the CURRENT behavior of the inline closures
-- that pick_comments / pick_hunks / pick_prs feed to Snacks.picker(). They are
-- the behavior-preservation net for the extraction.
--
-- Filtering boundary: `_build_comment_items` does NOT apply filter.apply --
-- pick_comments applies it before calling the builder. The fixtures below are
-- therefore already-filtered inputs (they include a resolved thread on purpose,
-- so the builder must emit a row for it regardless of filter state).

local snacks = require("pr.pickers.snacks")
local filter = require("pr.pickers.filter")

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

local GIT_ROOT = "/repo"

-- 2 threads on lua/a.lua: one unresolved single-line, one resolved multi-line.
local COMMENTS = {
	["lua/a.lua"] = {
		{
			id = "T1",
			is_resolved = false,
			is_outdated = false,
			comments = {
				{ author = "alice", body = "first body", start_line = 10, end_line = 10 },
			},
		},
		{
			id = "T2",
			is_resolved = true,
			is_outdated = false,
			comments = {
				{ author = "bob", body = "second body", start_line = 20, end_line = 25 },
			},
		},
	},
}

-- 2 hunks on lua/a.lua: an addition and a single-line deletion.
local HUNKS = {
	["lua/a.lua"] = {
		{ hunk_start = 5, hunk_end = 8, type = "Add" },
		{ hunk_start = 30, hunk_end = 30, type = "Delete" },
	},
}

-- 2 normalized PRs (shape from github._normalize_prs / pr_list output).
local PRS = {
	{ number = 1234, title = "feat: drift", author = "alice", state = "open", branch = "drift", url = "https://example/pull/1234" },
	{ number = 5, title = "fix: x", author = "bob", state = "draft", branch = "x", url = "https://example/pull/5" },
}

-- ---------------------------------------------------------------------------
-- Provider / dispatch stubs for the confirm tests.
-- ---------------------------------------------------------------------------

local fake_provider = { git_root = GIT_ROOT }
local saved_provider, saved_util, saved_pr_list
local util_calls, checkout_calls

describe("snacks picker item builders + confirm dispatchers", function()
	before_each(function()
		saved_provider = package.loaded["pr.provider"]
		saved_util = package.loaded["pr.util"]
		saved_pr_list = package.loaded["pr.pr_list"]

		fake_provider.git_root = GIT_ROOT
		util_calls, checkout_calls = {}, {}

		package.loaded["pr.provider"] = {
			get_provider = function()
				return fake_provider
			end,
		}
		package.loaded["pr.util"] = {
			open_pr_file = function(abs, rel, opts)
				table.insert(util_calls, { abs = abs, rel = rel, opts = opts })
			end,
		}
		package.loaded["pr.pr_list"] = {
			checkout = function(n)
				table.insert(checkout_calls, n)
			end,
		}
	end)

	after_each(function()
		package.loaded["pr.provider"] = saved_provider
		package.loaded["pr.util"] = saved_util
		package.loaded["pr.pr_list"] = saved_pr_list
	end)

	-- ---------------------------------------------------------------------------
	-- _build_comment_items
	-- ---------------------------------------------------------------------------

	describe("snacks._build_comment_items", function()
		it("emits one row per thread (no filtering inside the builder)", function()
			local items = snacks._build_comment_items(COMMENTS, GIT_ROOT)
			assert.equals(2, #items)
		end)

		it("carries the relative file path and start/end positions per thread", function()
			local items = snacks._build_comment_items(COMMENTS, GIT_ROOT)

			-- Single file + ipairs over the thread list => deterministic order.
			assert.equals("lua/a.lua", items[1].file)
			assert.same({ 10, 0 }, items[1].pos)
			assert.same({ 10, 0 }, items[1].end_pos)

			assert.equals("lua/a.lua", items[2].file)
			assert.same({ 20, 0 }, items[2].pos)
			assert.same({ 25, 0 }, items[2].end_pos)
		end)

		it("packs author/body/resolved/outdated into item.data and text", function()
			local items = snacks._build_comment_items(COMMENTS, GIT_ROOT)

			assert.equals("alice", items[1].data.author)
			assert.equals("first body", items[1].data.body)
			assert.is_false(items[1].data.is_resolved)
			assert.is_false(items[1].data.is_outdated)
			assert.equals("alice" .. "first body" .. "lua/a.lua", items[1].text)

			assert.equals("bob", items[2].data.author)
			assert.equals("second body", items[2].data.body)
			assert.is_true(items[2].data.is_resolved)
			assert.is_false(items[2].data.is_outdated)
			assert.equals("bob" .. "second body" .. "lua/a.lua", items[2].text)
		end)

		it("row data drives the expected filter.state_glyph (·/✓)", function()
			local items = snacks._build_comment_items(COMMENTS, GIT_ROOT)

			local g1, hl1 = filter.state_glyph(items[1].data)
			assert.equals("·", g1)
			assert.equals("NonText", hl1)

			local g2, hl2 = filter.state_glyph(items[2].data)
			assert.equals("✓", g2)
			assert.equals("Comment", hl2)
		end)
	end)

	-- ---------------------------------------------------------------------------
	-- _build_hunk_items
	-- ---------------------------------------------------------------------------

	describe("snacks._build_hunk_items", function()
		it("emits one row per hunk", function()
			local items = snacks._build_hunk_items(HUNKS, GIT_ROOT)
			assert.equals(2, #items)
		end)

		it("carries relative file, hunk bounds, type, text and positions", function()
			local items = snacks._build_hunk_items(HUNKS, GIT_ROOT)

			assert.equals("lua/a.lua", items[1].file)
			assert.equals(5, items[1].data.hunk_start)
			assert.equals(8, items[1].data.hunk_end)
			assert.equals("Add", items[1].data.type)
			assert.equals("lua/a.lua 5:8", items[1].text)
			assert.same({ 5, 0 }, items[1].pos)
			assert.same({ 8, 0 }, items[1].end_pos)

			assert.equals("lua/a.lua", items[2].file)
			assert.equals(30, items[2].data.hunk_start)
			assert.equals(30, items[2].data.hunk_end)
			assert.equals("Delete", items[2].data.type)
			assert.equals("lua/a.lua 30:30", items[2].text)
			assert.same({ 30, 0 }, items[2].pos)
			assert.same({ 30, 0 }, items[2].end_pos)
		end)
	end)

	-- ---------------------------------------------------------------------------
	-- _build_pr_items
	-- ---------------------------------------------------------------------------

	describe("snacks._build_pr_items", function()
		it("emits one row per PR", function()
			local items = snacks._build_pr_items(PRS)
			assert.equals(2, #items)
		end)

		it("formats text as `#<n> <title> <author>` and packs data", function()
			local items = snacks._build_pr_items(PRS)

			assert.equals("#1234 feat: drift alice", items[1].text)
			assert.equals(1234, items[1].data.number)
			assert.equals("feat: drift", items[1].data.title)
			assert.equals("alice", items[1].data.author)
			assert.equals("open", items[1].data.state)
			assert.equals("drift", items[1].data.branch)
			assert.equals("https://example/pull/1234", items[1].data.url)

			assert.equals("#5 fix: x bob", items[2].text)
			assert.equals(5, items[2].data.number)
			assert.equals("draft", items[2].data.state)
		end)

		it("coalesces nil title/author/state/branch/url to empty strings", function()
			local items = snacks._build_pr_items({ { number = 9 } })
			assert.equals("#9  ", items[1].text)
			assert.equals("", items[1].data.title)
			assert.equals("", items[1].data.author)
			assert.equals("", items[1].data.state)
			assert.equals("", items[1].data.branch)
			assert.equals("", items[1].data.url)
		end)
	end)

	-- ---------------------------------------------------------------------------
	-- _confirm_comment / _confirm_hunk -> util.open_pr_file(absolute, rel, {line})
	-- ---------------------------------------------------------------------------

	describe("snacks._confirm_comment", function()
		it("opens the absolute path (git_root/rel) at the thread start line", function()
			local items = snacks._build_comment_items(COMMENTS, GIT_ROOT)
			snacks._confirm_comment(items[1])

			assert.equals(1, #util_calls)
			assert.equals("/repo/lua/a.lua", util_calls[1].abs)
			assert.equals("lua/a.lua", util_calls[1].rel)
			assert.same({ line = 10 }, util_calls[1].opts)
		end)

		it("is a no-op when item is nil", function()
			snacks._confirm_comment(nil)
			assert.equals(0, #util_calls)
		end)
	end)

	describe("snacks._confirm_hunk", function()
		it("opens the absolute path at the hunk start line", function()
			local items = snacks._build_hunk_items(HUNKS, GIT_ROOT)
			snacks._confirm_hunk(items[2])

			assert.equals(1, #util_calls)
			assert.equals("/repo/lua/a.lua", util_calls[1].abs)
			assert.equals("lua/a.lua", util_calls[1].rel)
			assert.same({ line = 30 }, util_calls[1].opts)
		end)

		it("is a no-op when item is nil", function()
			snacks._confirm_hunk(nil)
			assert.equals(0, #util_calls)
		end)
	end)

	-- ---------------------------------------------------------------------------
	-- _confirm_pr -> pr_list.checkout(item.data.number)
	-- ---------------------------------------------------------------------------

	describe("snacks._confirm_pr", function()
		it("checks out the PR number carried by the item", function()
			local items = snacks._build_pr_items(PRS)
			snacks._confirm_pr(items[1])

			assert.equals(1, #checkout_calls)
			assert.equals(1234, checkout_calls[1])
		end)

		it("is a no-op when item is nil", function()
			snacks._confirm_pr(nil)
			assert.equals(0, #checkout_calls)
		end)

		it("does not dispatch when pr_list.checkout is unavailable", function()
			package.loaded["pr.pr_list"] = { checkout = nil }
			local items = snacks._build_pr_items(PRS)
			-- Should not error; falls through to the notify branch.
			snacks._confirm_pr(items[1])
			assert.equals(0, #checkout_calls)
		end)
	end)
end)
