-- Characterization spec for the fzf-lua picker's pure line builders and confirm
-- dispatchers. These exports are UI-independent: they build the finder row
-- STRINGS and dispatch file-open / checkout without fzf-lua installed (fzf.lua
-- defers its `require("fzf-lua")` into the pick_* functions, and the
-- builders/confirms never touch it).
--
-- The assertions below document the CURRENT behavior of the inline closures
-- that pick_comments / pick_hunks / pick_prs feed to fzf-lua's fzf_exec and
-- action handlers. They are the behavior-preservation net for the extraction.
--
-- Structural deviation from snacks/telescope (per the plan): fzf rows are plain
-- display STRINGS, not item tables.
--   * `_build_comment_items` / `_build_hunk_items` return a bare `string[]`.
--     Each row encodes "file:line:1:..." (fzf-lua's builtin previewer format);
--     the confirm re-parses file+line straight out of the selected string via a
--     regex, so there is no per-row lookup and `_confirm_comment` /
--     `_confirm_hunk` take only the fzf `selected` list.
--   * PR rows can't be reverse-parsed to a payload, so `_build_pr_items` returns
--     `{ lines = string[], lookup = table<string, PRSummary> }` keyed by the row
--     string, and `_confirm_pr(selected, lookup)` resolves through that lookup.
--
-- fzf passes the confirm callback a *table* of selected lines; the confirms read
-- `selected[1]`, so the tests wrap a row string as `{ row }`.
--
-- Filtering boundary: `_build_comment_items` does NOT apply filter.apply --
-- pick_comments applies it before calling the builder. The COMMENTS fixture is
-- therefore an already-filtered input (it includes a resolved thread on purpose,
-- so the builder must emit a row for it regardless of filter state).

local fzf = require("pr.pickers.fzf")
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
-- Provider / dispatch stubs for the confirm tests.
-- ---------------------------------------------------------------------------

local fake_provider = { git_root = GIT_ROOT }
local saved_provider, saved_util, saved_pr_list
local util_calls, checkout_calls

describe("fzf picker line builders + confirm dispatchers", function()
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
	-- _build_comment_items -> string[]
	-- ---------------------------------------------------------------------------

	describe("fzf._build_comment_items", function()
		it("emits one row per thread (no filtering inside the builder)", function()
			local lines = fzf._build_comment_items(COMMENTS, GIT_ROOT)
			assert.equals(2, #lines)
		end)

		it("formats each row as `file:line:1:<glyph> <author>: <body>`", function()
			local lines = fzf._build_comment_items(COMMENTS, GIT_ROOT)

			-- Single file + ipairs over the thread list => deterministic order.
			-- The unresolved thread renders the "·" glyph; the resolved one "✓"
			-- (see filter.state_glyph). Only the glyph's first return value is
			-- interpolated (the inline code captures it into a single local).
			assert.equals("·", (filter.state_glyph(COMMENTS["lua/a.lua"][1])))
			assert.equals("lua/a.lua:10:1:· alice: first body", lines[1])

			assert.equals("✓", (filter.state_glyph(COMMENTS["lua/a.lua"][2])))
			assert.equals("lua/a.lua:20:1:✓ bob: second body", lines[2])
		end)

		it("collapses newlines to spaces and truncates bodies over 60 chars with …", function()
			local long = string.rep("a", 40) .. "\n" .. string.rep("b", 40)
			local comments = {
				["lua/a.lua"] = {
					{
						id = "T",
						is_resolved = false,
						is_outdated = false,
						comments = { { author = "carol", body = long, start_line = 3, end_line = 3 } },
					},
				},
			}
			local lines = fzf._build_comment_items(comments, GIT_ROOT)

			-- gsub("\r?\n", " ") first, then a 60-char cut plus the "…" ellipsis.
			local collapsed = long:gsub("\r?\n", " ")
			local body = collapsed:sub(1, 60) .. "…"
			assert.equals("lua/a.lua:3:1:· carol: " .. body, lines[1])
		end)
	end)

	-- ---------------------------------------------------------------------------
	-- _build_hunk_items -> string[]
	-- ---------------------------------------------------------------------------

	describe("fzf._build_hunk_items", function()
		it("emits one row per hunk", function()
			local lines = fzf._build_hunk_items(HUNKS, GIT_ROOT)
			assert.equals(2, #lines)
		end)

		it("formats each row as `file:hunk_start:1:[type] start-end`", function()
			local lines = fzf._build_hunk_items(HUNKS, GIT_ROOT)
			assert.equals("lua/a.lua:5:1:[Add] 5-8", lines[1])
			assert.equals("lua/a.lua:30:1:[Delete] 30-30", lines[2])
		end)
	end)

	-- ---------------------------------------------------------------------------
	-- _build_pr_items -> { lines = string[], lookup = row -> PRSummary }
	-- ---------------------------------------------------------------------------

	describe("fzf._build_pr_items", function()
		it("emits one line per PR and a lookup keyed by the row string", function()
			local built = fzf._build_pr_items(PRS)
			assert.equals(2, #built.lines)

			assert.equals(string.format("#%-5d %-8s %s  @%s", 1234, "open", "feat: drift", "alice"), built.lines[1])
			assert.equals(string.format("#%-5d %-8s %s  @%s", 5, "draft", "fix: x", "bob"), built.lines[2])
		end)

		it("round-trips every line back to its PR payload via lookup", function()
			local built = fzf._build_pr_items(PRS)
			-- Every emitted line resolves a payload, and it is the SAME table
			-- (identity) that produced it.
			assert.are.equal(PRS[1], built.lookup[built.lines[1]])
			assert.are.equal(PRS[2], built.lookup[built.lines[2]])
			assert.equals(1234, built.lookup[built.lines[1]].number)
			assert.equals(5, built.lookup[built.lines[2]].number)
		end)

		it("coalesces nil state/title/author to empty strings", function()
			local built = fzf._build_pr_items({ { number = 9 } })
			assert.equals(string.format("#%-5d %-8s %s  @%s", 9, "", "", ""), built.lines[1])
			assert.equals(9, built.lookup[built.lines[1]].number)
		end)

		it("returns empty lines/lookup for an empty PR list", function()
			local built = fzf._build_pr_items({})
			assert.equals(0, #built.lines)
			assert.are.same({}, built.lookup)
		end)
	end)

	-- ---------------------------------------------------------------------------
	-- _confirm_comment / _confirm_hunk (selected list -> regex-parse -> open)
	-- ---------------------------------------------------------------------------

	describe("fzf._confirm_comment", function()
		it("parses file:line from the selected row and opens the absolute path", function()
			local lines = fzf._build_comment_items(COMMENTS, GIT_ROOT)
			fzf._confirm_comment({ lines[1] })

			assert.equals(1, #util_calls)
			assert.equals("/repo/lua/a.lua", util_calls[1].abs)
			assert.equals("lua/a.lua", util_calls[1].rel)
			assert.same({ line = 10 }, util_calls[1].opts)
		end)

		it("is a no-op when selected is nil or empty", function()
			fzf._confirm_comment(nil)
			fzf._confirm_comment({})
			assert.equals(0, #util_calls)
		end)

		it("is a no-op when the selected row has no file:line prefix", function()
			fzf._confirm_comment({ "no-colon-row" })
			assert.equals(0, #util_calls)
		end)
	end)

	describe("fzf._confirm_hunk", function()
		it("parses file:line from the selected row and opens the absolute path", function()
			local lines = fzf._build_hunk_items(HUNKS, GIT_ROOT)
			fzf._confirm_hunk({ lines[2] })

			assert.equals(1, #util_calls)
			assert.equals("/repo/lua/a.lua", util_calls[1].abs)
			assert.equals("lua/a.lua", util_calls[1].rel)
			assert.same({ line = 30 }, util_calls[1].opts)
		end)

		it("is a no-op when selected is nil or empty", function()
			fzf._confirm_hunk(nil)
			fzf._confirm_hunk({})
			assert.equals(0, #util_calls)
		end)
	end)

	-- ---------------------------------------------------------------------------
	-- _confirm_pr (selected list + lookup -> pr_list.checkout(number))
	-- ---------------------------------------------------------------------------

	describe("fzf._confirm_pr", function()
		it("resolves the row through the lookup and checks out its PR number", function()
			local built = fzf._build_pr_items(PRS)
			fzf._confirm_pr({ built.lines[1] }, built.lookup)

			assert.equals(1, #checkout_calls)
			assert.equals(1234, checkout_calls[1])
		end)

		it("is a no-op when selected is nil or empty", function()
			fzf._confirm_pr(nil, {})
			fzf._confirm_pr({}, {})
			assert.equals(0, #checkout_calls)
		end)

		it("is a no-op when the row is not in the lookup", function()
			fzf._confirm_pr({ "unknown row" }, {})
			assert.equals(0, #checkout_calls)
		end)

		it("does not dispatch when pr_list.checkout is unavailable", function()
			package.loaded["pr.pr_list"] = { checkout = nil }
			local built = fzf._build_pr_items(PRS)
			-- Should not error; falls through to the notify branch.
			fzf._confirm_pr({ built.lines[1] }, built.lookup)
			assert.equals(0, #checkout_calls)
		end)
	end)
end)
