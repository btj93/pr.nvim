-- Characterization spec for the telescope picker's pure entry builders and
-- confirm dispatchers. These exports are UI-independent: they build finder
-- entries and dispatch file-open / checkout without telescope.nvim installed
-- (telescope.lua defers its `require("telescope.*")` into the pick_* functions,
-- and the builders/confirms never touch them).
--
-- The assertions below document the CURRENT behavior of the inline closures
-- that pick_comments / pick_hunks / pick_prs feed to telescope's finder and
-- select_default:replace handlers. They are the behavior-preservation net for
-- the extraction.
--
-- Filtering boundary: `_build_comment_items` does NOT apply filter.apply --
-- pick_comments applies it (filter.apply over the cached comments) before
-- calling the builder. The COMMENTS fixture below is therefore an
-- already-filtered input (it includes a resolved thread on purpose, so the
-- builder must emit a row for it regardless of filter state).
--
-- Note for the cross-backend spec (Task 4): telescope entries carry the
-- ABSOLUTE path under `path` (git_root .. "/" .. rel) so telescope's previewer
-- resolves the file regardless of cwd; the relative payload stays under
-- `value.file` (snacks uses `file`/`pos`), which is what the display fns render
-- and what the confirm dispatchers resolve against the provider's git_root.

local telescope = require("pr.pickers.telescope")
local filter = require("pr.pickers.filter")

-- ---------------------------------------------------------------------------
-- Fixtures (shape mirrors tests/picker_snacks_items_spec.lua).
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
-- Provider / dispatch / devicons stubs.
-- ---------------------------------------------------------------------------

local fake_provider = { git_root = GIT_ROOT }
local saved_provider, saved_util, saved_pr_list, saved_devicons
local util_calls, checkout_calls

describe("telescope picker entry builders + confirm dispatchers", function()
	before_each(function()
		saved_provider = package.loaded["pr.provider"]
		saved_util = package.loaded["pr.util"]
		saved_pr_list = package.loaded["pr.pr_list"]
		saved_devicons = package.loaded["nvim-web-devicons"]

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
		-- nvim-web-devicons is not installed in the test env; the display
		-- functions require it, so stub a deterministic icon.
		package.loaded["nvim-web-devicons"] = {
			get_icon = function()
				return "IC", "IconHL"
			end,
		}
	end)

	after_each(function()
		package.loaded["pr.provider"] = saved_provider
		package.loaded["pr.util"] = saved_util
		package.loaded["pr.pr_list"] = saved_pr_list
		package.loaded["nvim-web-devicons"] = saved_devicons
	end)

	-- ---------------------------------------------------------------------------
	-- _build_comment_items
	-- ---------------------------------------------------------------------------

	describe("telescope._build_comment_items", function()
		it("emits one entry per thread (no filtering inside the builder)", function()
			local items = telescope._build_comment_items(COMMENTS, GIT_ROOT)
			assert.equals(2, #items)
		end)

		it("carries value/absolute path/lnum/ordinal and the format_comments display fn", function()
			local items = telescope._build_comment_items(COMMENTS, GIT_ROOT)

			-- Single file + ipairs over the thread list => deterministic order.
			-- `path` is ABSOLUTE (git_root .. "/" .. rel) so telescope's previewer
			-- resolves the file even when cwd != git root; `value.file` stays
			-- relative for display/confirm.
			local e1 = items[1]
			assert.equals("lua/a.lua", e1.value.file)
			assert.equals("alice", e1.value.author)
			assert.equals("first body", e1.value.body)
			assert.equals(10, e1.value.start_line)
			assert.equals(10, e1.value.end_line)
			assert.is_false(e1.value.is_resolved)
			assert.is_false(e1.value.is_outdated)
			assert.equals("/repo/lua/a.lua", e1.path)
			assert.equals(10, e1.lnum)
			assert.equals("alice" .. "first body" .. "lua/a.lua", e1.ordinal)
			assert.equals(telescope.format_comments, e1.display)

			local e2 = items[2]
			assert.equals("lua/a.lua", e2.value.file)
			assert.equals("bob", e2.value.author)
			assert.equals("second body", e2.value.body)
			assert.equals(20, e2.value.start_line)
			assert.equals(25, e2.value.end_line)
			assert.is_true(e2.value.is_resolved)
			assert.is_false(e2.value.is_outdated)
			assert.equals("/repo/lua/a.lua", e2.path)
			assert.equals(20, e2.lnum)
			assert.equals("bob" .. "second body" .. "lua/a.lua", e2.ordinal)
			assert.equals(telescope.format_comments, e2.display)
		end)

		it("display fn renders glyph + icon + author + truncated body + RELATIVE file", function()
			local items = telescope._build_comment_items(COMMENTS, GIT_ROOT)

			-- The unresolved thread renders the "·" state glyph; the resolved one
			-- renders "✓" (see filter.state_glyph).
			local g1 = filter.state_glyph(items[1].value)
			assert.equals("·", g1)
			assert.equals(string.format("%s %s %-15s %-40s %s", "·", "IC", "alice", "first body", "lua/a.lua"), items[1].display(items[1]))

			local g2 = filter.state_glyph(items[2].value)
			assert.equals("✓", g2)
			assert.equals(string.format("%s %s %-15s %-40s %s", "✓", "IC", "bob", "second body", "lua/a.lua"), items[2].display(items[2]))
		end)
	end)

	-- ---------------------------------------------------------------------------
	-- _build_hunk_items
	-- ---------------------------------------------------------------------------

	describe("telescope._build_hunk_items", function()
		it("emits one entry per hunk", function()
			local items = telescope._build_hunk_items(HUNKS, GIT_ROOT)
			assert.equals(2, #items)
		end)

		it("carries value/absolute path/lnum/ordinal and the format_hunks display fn", function()
			local items = telescope._build_hunk_items(HUNKS, GIT_ROOT)

			-- `path` is ABSOLUTE for the previewer; `value.file` stays relative.
			local e1 = items[1]
			assert.equals("lua/a.lua", e1.value.file)
			assert.equals(5, e1.value.hunk_start)
			assert.equals(8, e1.value.hunk_end)
			assert.equals("Add", e1.value.type)
			assert.equals("/repo/lua/a.lua", e1.path)
			assert.equals(5, e1.lnum)
			assert.equals("lua/a.lua 5:8", e1.ordinal)
			assert.equals(telescope.format_hunks, e1.display)

			local e2 = items[2]
			assert.equals("lua/a.lua", e2.value.file)
			assert.equals(30, e2.value.hunk_start)
			assert.equals(30, e2.value.hunk_end)
			assert.equals("Delete", e2.value.type)
			assert.equals("/repo/lua/a.lua", e2.path)
			assert.equals(30, e2.lnum)
			assert.equals("lua/a.lua 30:30", e2.ordinal)
			assert.equals(telescope.format_hunks, e2.display)
		end)

		it("display fn renders icon + padded RELATIVE file + start:end", function()
			local items = telescope._build_hunk_items(HUNKS, GIT_ROOT)
			assert.equals(string.format("%s %-80s %s:%s", "IC", "lua/a.lua", 5, 8), items[1].display(items[1]))
			assert.equals(string.format("%s %-80s %s:%s", "IC", "lua/a.lua", 30, 30), items[2].display(items[2]))
		end)
	end)

	-- ---------------------------------------------------------------------------
	-- _build_pr_items
	-- ---------------------------------------------------------------------------

	describe("telescope._build_pr_items", function()
		it("emits one entry per PR", function()
			local items = telescope._build_pr_items(PRS)
			assert.equals(2, #items)
		end)

		it("packs value fields and a formatted string display", function()
			local items = telescope._build_pr_items(PRS)

			local e1 = items[1]
			assert.equals(1234, e1.value.number)
			assert.equals("feat: drift", e1.value.title)
			assert.equals("alice", e1.value.author)
			assert.equals("open", e1.value.state)
			assert.equals("drift", e1.value.branch)
			assert.equals("https://example/pull/1234", e1.value.url)
			assert.equals(string.format("#%-5d %-8s %s  @%s", 1234, "open", "feat: drift", "alice"), e1.display)
			assert.equals("1234 feat: drift alice", e1.ordinal)

			local e2 = items[2]
			assert.equals(5, e2.value.number)
			assert.equals("draft", e2.value.state)
			assert.equals(string.format("#%-5d %-8s %s  @%s", 5, "draft", "fix: x", "bob"), e2.display)
			assert.equals("5 fix: x bob", e2.ordinal)
		end)

		it("coalesces nil title/author/state/branch/url to empty strings", function()
			local items = telescope._build_pr_items({ { number = 9 } })
			assert.equals("", items[1].value.title)
			assert.equals("", items[1].value.author)
			assert.equals("", items[1].value.state)
			assert.equals("", items[1].value.branch)
			assert.equals("", items[1].value.url)
			assert.equals(string.format("#%-5d %-8s %s  @%s", 9, "", "", ""), items[1].display)
			assert.equals("9  ", items[1].ordinal)
		end)
	end)

	-- ---------------------------------------------------------------------------
	-- _confirm_comment / _confirm_hunk -> util.open_pr_file(absolute, rel, {line})
	-- The exports take the selected ENTRY (selection), matching the closure that
	-- reads action_state.get_selected_entry().
	-- ---------------------------------------------------------------------------

	describe("telescope._confirm_comment", function()
		it("opens the absolute path (git_root/rel) at the thread start line", function()
			local items = telescope._build_comment_items(COMMENTS, GIT_ROOT)
			telescope._confirm_comment(items[1])

			assert.equals(1, #util_calls)
			assert.equals("/repo/lua/a.lua", util_calls[1].abs)
			assert.equals("lua/a.lua", util_calls[1].rel)
			assert.same({ line = 10 }, util_calls[1].opts)
		end)

		it("is a no-op when the selection is nil", function()
			telescope._confirm_comment(nil)
			assert.equals(0, #util_calls)
		end)
	end)

	describe("telescope._confirm_hunk", function()
		it("opens the absolute path at the hunk start line", function()
			local items = telescope._build_hunk_items(HUNKS, GIT_ROOT)
			telescope._confirm_hunk(items[2])

			assert.equals(1, #util_calls)
			assert.equals("/repo/lua/a.lua", util_calls[1].abs)
			assert.equals("lua/a.lua", util_calls[1].rel)
			assert.same({ line = 30 }, util_calls[1].opts)
		end)

		it("is a no-op when the selection is nil", function()
			telescope._confirm_hunk(nil)
			assert.equals(0, #util_calls)
		end)
	end)

	-- ---------------------------------------------------------------------------
	-- _confirm_pr -> pr_list.checkout(selection.value.number)
	-- ---------------------------------------------------------------------------

	describe("telescope._confirm_pr", function()
		it("checks out the PR number carried by the selection", function()
			local items = telescope._build_pr_items(PRS)
			telescope._confirm_pr(items[1])

			assert.equals(1, #checkout_calls)
			assert.equals(1234, checkout_calls[1])
		end)

		it("is a no-op when the selection is nil", function()
			telescope._confirm_pr(nil)
			assert.equals(0, #checkout_calls)
		end)

		it("is a no-op when the selection has no value", function()
			telescope._confirm_pr({})
			assert.equals(0, #checkout_calls)
		end)

		it("does not dispatch when pr_list.checkout is unavailable", function()
			package.loaded["pr.pr_list"] = { checkout = nil }
			local items = telescope._build_pr_items(PRS)
			-- Should not error; falls through to the notify branch.
			telescope._confirm_pr(items[1])
			assert.equals(0, #checkout_calls)
		end)
	end)
end)
