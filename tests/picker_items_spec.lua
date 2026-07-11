-- Cross-backend equivalence spec for the three picker item/line builders and
-- confirm dispatchers (snacks / telescope / fzf).
--
-- Tasks 1-3 characterized each backend in isolation. This spec proves the three
-- pure surfaces are INTERCHANGEABLE: fed one shared fixture, they must emit the
-- same rows (per kind), target the same (path, line), reference the same PRs,
-- render the same state glyph per thread, and — driven through their NATIVE
-- confirm argument shapes — dispatch the same file-open / checkout.
--
-- The three backends carry the target differently:
--   * snacks    — item.file (relative) + item.pos = { line, col }
--   * telescope — entry.path (ABSOLUTE, git_root .. "/" .. rel, for the
--                 previewer) + entry.lnum; the relative payload lives at
--                 entry.value.file, which is what the extractors below compare
--   * fzf       — a bare "file:line:col:label" string (parsed back with the same
--                 `^([^:]+):(%d+):` regex the fzf confirms use)
-- and identify a PR differently (snacks item.data.number / telescope
-- entry.value.number / fzf lookup[line].number). Every assertion below extracts
-- through those native shapes and compares SETS (order-independent), so pairs()
-- traversal order across the three backends never matters.
--
-- Filtering boundary: the builders do NOT apply filter.apply (pick_* applies it
-- before calling them). The fixture is therefore an already-filtered input that
-- deliberately includes a resolved thread AND an outdated thread, so every
-- builder must emit a row for each regardless of filter state — which is exactly
-- what lets us assert glyph parity across all three state classes (· / ✓ / ~).
--
-- Snacks glyph note: snacks.format_comments needs the `Snacks` runtime upvalue
-- (align/icon/truncate) which is absent in the test env, so — as the snacks
-- characterization spec does — snacks' rendered glyph is taken from
-- filter.state_glyph(item.data), the SAME function its formatter calls. Telescope
-- and fzf glyphs are extracted from the ACTUAL rendered strings (display fn /
-- row string).

local snacks = require("pr.pickers.snacks")
local telescope = require("pr.pickers.telescope")
local fzf = require("pr.pickers.fzf")
local filter = require("pr.pickers.filter")

-- ---------------------------------------------------------------------------
-- One shared fixture (adapted from the three characterization specs: adds an
-- outdated thread and a second file for multi-file coverage).
-- ---------------------------------------------------------------------------

local GIT_ROOT = "/repo"

-- 3 threads across 2 files, one per state class:
--   lua/a.lua  T1 unresolved single-line (10)   -> glyph "·"
--   lua/a.lua  T2 resolved   multi-line  (20-25) -> glyph "✓"
--   lua/b.lua  T3 outdated   single-line (7)     -> glyph "~"
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
	["lua/b.lua"] = {
		{
			id = "T3",
			is_resolved = false,
			is_outdated = true,
			comments = {
				{ author = "carol", body = "third body", start_line = 7, end_line = 7 },
			},
		},
	},
}

-- 2 hunks across 2 files: an addition and a single-line deletion.
local HUNKS = {
	["lua/a.lua"] = {
		{ hunk_start = 5, hunk_end = 8, type = "Add" },
	},
	["lua/b.lua"] = {
		{ hunk_start = 30, hunk_end = 30, type = "Delete" },
	},
}

-- 2 normalized PRs (shape from github._normalize_prs / pr_list output).
local PRS = {
	{ number = 1234, title = "feat: drift", author = "alice", state = "open", branch = "drift", url = "https://example/pull/1234" },
	{ number = 5, title = "fix: x", author = "bob", state = "draft", branch = "x", url = "https://example/pull/5" },
}

-- ---------------------------------------------------------------------------
-- Per-backend extractors: normalize each backend's native row into the shared
-- comparison shapes. Order-independent (callers sort / set-compare).
-- ---------------------------------------------------------------------------

-- (path, line) target list -----------------------------------------------------

local function snacks_targets(items)
	local out = {}
	for _, it in ipairs(items) do
		out[#out + 1] = { path = it.file, line = it.pos[1] }
	end
	return out
end

-- telescope entries carry the ABSOLUTE previewer path under `path`; compare on
-- the relative payload (`value.file`) so the target sets stay backend-neutral.
local function telescope_targets(items)
	local out = {}
	for _, e in ipairs(items) do
		out[#out + 1] = { path = e.value.file, line = e.lnum }
	end
	return out
end

-- fzf rows are bare "file:line:col:label" strings; parse with the same regex the
-- fzf confirms use (`^([^:]+):(%d+):`).
local function fzf_targets(lines)
	local out = {}
	for _, ln in ipairs(lines) do
		local file, line = ln:match("^([^:]+):(%d+):")
		out[#out + 1] = { path = file, line = tonumber(line) }
	end
	return out
end

-- Sorted "path:line" key set for order-independent equality.
local function target_keys(targets)
	local keys = {}
	for _, t in ipairs(targets) do
		keys[#keys + 1] = t.path .. ":" .. tostring(t.line)
	end
	table.sort(keys)
	return keys
end

-- PR identity set --------------------------------------------------------------

local function sorted_numbers(nums)
	local copy = {}
	for _, n in ipairs(nums) do
		copy[#copy + 1] = n
	end
	table.sort(copy)
	return copy
end

local function snacks_pr_numbers(items)
	local out = {}
	for _, it in ipairs(items) do
		out[#out + 1] = it.data.number
	end
	return out
end

local function telescope_pr_numbers(items)
	local out = {}
	for _, e in ipairs(items) do
		out[#out + 1] = e.value.number
	end
	return out
end

local function fzf_pr_numbers(built)
	local out = {}
	for _, ln in ipairs(built.lines) do
		out[#out + 1] = built.lookup[ln].number
	end
	return out
end

-- Rendered state glyph per (path:line) target ---------------------------------

-- Canonical glyph the whole system should render for each thread.
local function canonical_glyphs()
	local m = {}
	for file, threads in pairs(COMMENTS) do
		for _, thread in ipairs(threads) do
			local _, first = next(thread.comments)
			m[file .. ":" .. first.start_line] = (filter.state_glyph(thread))
		end
	end
	return m
end

-- snacks: filter.state_glyph(item.data) — the same call format_comments makes
-- (the formatter itself needs the Snacks runtime, unavailable in tests).
local function snacks_glyphs(items)
	local m = {}
	for _, it in ipairs(items) do
		m[it.file .. ":" .. it.pos[1]] = (filter.state_glyph(it.data))
	end
	return m
end

-- telescope: call the display function and read the leading glyph token off the
-- ACTUAL rendered string ("<glyph> <icon> <author> ..."). Keyed on the relative
-- payload (`value.file`), not the absolute previewer `path`.
local function telescope_glyphs(items)
	local m = {}
	for _, e in ipairs(items) do
		local rendered = e.display(e)
		m[e.value.file .. ":" .. e.lnum] = rendered:match("^(%S+)")
	end
	return m
end

-- fzf: read the glyph token straight out of the ACTUAL row string
-- ("file:line:col:<glyph> <author>: <body>").
local function fzf_glyphs(lines)
	local m = {}
	for _, ln in ipairs(lines) do
		local file, line, glyph = ln:match("^([^:]+):(%d+):%d+:(%S+)")
		m[file .. ":" .. line] = glyph
	end
	return m
end

-- Native-row finders for the dispatch tests -----------------------------------

local function find_snacks_by_target(items, path, line)
	for _, it in ipairs(items) do
		if it.file == path and it.pos[1] == line then
			return it
		end
	end
	error("snacks row not found for " .. path .. ":" .. line)
end

local function find_telescope_by_target(items, path, line)
	for _, e in ipairs(items) do
		if e.value.file == path and e.lnum == line then
			return e
		end
	end
	error("telescope row not found for " .. path .. ":" .. line)
end

local function find_fzf_line_by_target(lines, path, line)
	for _, ln in ipairs(lines) do
		local f, l = ln:match("^([^:]+):(%d+):")
		if f == path and tonumber(l) == line then
			return ln
		end
	end
	error("fzf row not found for " .. path .. ":" .. line)
end

local function find_snacks_pr(items, number)
	for _, it in ipairs(items) do
		if it.data.number == number then
			return it
		end
	end
	error("snacks PR row not found for #" .. number)
end

local function find_telescope_pr(items, number)
	for _, e in ipairs(items) do
		if e.value.number == number then
			return e
		end
	end
	error("telescope PR row not found for #" .. number)
end

local function find_fzf_pr_line(built, number)
	for _, ln in ipairs(built.lines) do
		if built.lookup[ln].number == number then
			return ln
		end
	end
	error("fzf PR row not found for #" .. number)
end

-- ---------------------------------------------------------------------------

describe("cross-backend picker item/dispatch equivalence", function()
	local fake_provider = { git_root = GIT_ROOT }
	local saved_provider, saved_util, saved_pr_list, saved_devicons
	local util_calls, checkout_calls

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
		-- telescope's display functions require nvim-web-devicons (absent in the
		-- test env); stub a deterministic icon so telescope_glyphs can render.
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
	-- Case 1: identical row counts per kind.
	-- ---------------------------------------------------------------------------

	describe("row counts", function()
		it("emit identical comment row counts (one per thread)", function()
			local s = #snacks._build_comment_items(COMMENTS, GIT_ROOT)
			local t = #telescope._build_comment_items(COMMENTS, GIT_ROOT)
			local f = #fzf._build_comment_items(COMMENTS, GIT_ROOT)
			assert.equals(3, s)
			assert.equals(s, t)
			assert.equals(s, f)
		end)

		it("emit identical hunk row counts (one per hunk)", function()
			local s = #snacks._build_hunk_items(HUNKS, GIT_ROOT)
			local t = #telescope._build_hunk_items(HUNKS, GIT_ROOT)
			local f = #fzf._build_hunk_items(HUNKS, GIT_ROOT)
			assert.equals(2, s)
			assert.equals(s, t)
			assert.equals(s, f)
		end)

		it("emit identical PR row counts (one per PR)", function()
			local s = #snacks._build_pr_items(PRS)
			local t = #telescope._build_pr_items(PRS)
			local f = #fzf._build_pr_items(PRS).lines
			assert.equals(2, s)
			assert.equals(s, t)
			assert.equals(s, f)
		end)
	end)

	-- ---------------------------------------------------------------------------
	-- Case 2: identical (path, line) target sets.
	-- ---------------------------------------------------------------------------

	describe("target sets (path, line)", function()
		it("comments target the same (path, line) across backends", function()
			local s = target_keys(snacks_targets(snacks._build_comment_items(COMMENTS, GIT_ROOT)))
			local t = target_keys(telescope_targets(telescope._build_comment_items(COMMENTS, GIT_ROOT)))
			local f = target_keys(fzf_targets(fzf._build_comment_items(COMMENTS, GIT_ROOT)))

			assert.same({ "lua/a.lua:10", "lua/a.lua:20", "lua/b.lua:7" }, s)
			assert.same(s, t)
			assert.same(s, f)
		end)

		it("hunks target the same (path, line) across backends", function()
			local s = target_keys(snacks_targets(snacks._build_hunk_items(HUNKS, GIT_ROOT)))
			local t = target_keys(telescope_targets(telescope._build_hunk_items(HUNKS, GIT_ROOT)))
			local f = target_keys(fzf_targets(fzf._build_hunk_items(HUNKS, GIT_ROOT)))

			assert.same({ "lua/a.lua:5", "lua/b.lua:30" }, s)
			assert.same(s, t)
			assert.same(s, f)
		end)
	end)

	-- ---------------------------------------------------------------------------
	-- Case 3: identical PR identity sets.
	-- ---------------------------------------------------------------------------

	describe("PR identity sets", function()
		it("reference the same PR numbers across backends", function()
			local s = sorted_numbers(snacks_pr_numbers(snacks._build_pr_items(PRS)))
			local t = sorted_numbers(telescope_pr_numbers(telescope._build_pr_items(PRS)))
			local f = sorted_numbers(fzf_pr_numbers(fzf._build_pr_items(PRS)))

			assert.same({ 5, 1234 }, s)
			assert.same(s, t)
			assert.same(s, f)
		end)
	end)

	-- ---------------------------------------------------------------------------
	-- Case 4: identical state glyph per thread.
	-- ---------------------------------------------------------------------------

	describe("state glyph per thread", function()
		it("render the same filter.state_glyph for each thread across backends", function()
			local canonical = canonical_glyphs()
			-- Fixture sanity: all three state classes are represented.
			assert.same({
				["lua/a.lua:10"] = "·",
				["lua/a.lua:20"] = "✓",
				["lua/b.lua:7"] = "~",
			}, canonical)

			local s = snacks_glyphs(snacks._build_comment_items(COMMENTS, GIT_ROOT))
			local t = telescope_glyphs(telescope._build_comment_items(COMMENTS, GIT_ROOT))
			local f = fzf_glyphs(fzf._build_comment_items(COMMENTS, GIT_ROOT))

			assert.same(canonical, s)
			assert.same(canonical, t)
			assert.same(canonical, f)
		end)
	end)

	-- ---------------------------------------------------------------------------
	-- Case 5/6: dispatch equivalence — drive each backend's confirm through its
	-- NATIVE argument shape and assert identical downstream effect.
	-- ---------------------------------------------------------------------------

	describe("comment confirm dispatch", function()
		it("all three open the same (abs, rel, line) for the same thread", function()
			local path, line = "lua/a.lua", 10

			util_calls = {}
			snacks._confirm_comment(find_snacks_by_target(snacks._build_comment_items(COMMENTS, GIT_ROOT), path, line))
			local s_call = util_calls[1]

			util_calls = {}
			telescope._confirm_comment(find_telescope_by_target(telescope._build_comment_items(COMMENTS, GIT_ROOT), path, line))
			local t_call = util_calls[1]

			util_calls = {}
			fzf._confirm_comment({ find_fzf_line_by_target(fzf._build_comment_items(COMMENTS, GIT_ROOT), path, line) })
			local f_call = util_calls[1]

			assert.same({ abs = "/repo/lua/a.lua", rel = "lua/a.lua", opts = { line = 10 } }, s_call)
			assert.same(s_call, t_call)
			assert.same(s_call, f_call)
		end)
	end)

	describe("hunk confirm dispatch", function()
		it("all three open the same (abs, rel, line) for the same hunk", function()
			local path, line = "lua/b.lua", 30

			util_calls = {}
			snacks._confirm_hunk(find_snacks_by_target(snacks._build_hunk_items(HUNKS, GIT_ROOT), path, line))
			local s_call = util_calls[1]

			util_calls = {}
			telescope._confirm_hunk(find_telescope_by_target(telescope._build_hunk_items(HUNKS, GIT_ROOT), path, line))
			local t_call = util_calls[1]

			util_calls = {}
			fzf._confirm_hunk({ find_fzf_line_by_target(fzf._build_hunk_items(HUNKS, GIT_ROOT), path, line) })
			local f_call = util_calls[1]

			assert.same({ abs = "/repo/lua/b.lua", rel = "lua/b.lua", opts = { line = 30 } }, s_call)
			assert.same(s_call, t_call)
			assert.same(s_call, f_call)
		end)
	end)

	describe("PR confirm dispatch", function()
		it("all three checkout the same PR number for the same row", function()
			local number = 1234

			checkout_calls = {}
			snacks._confirm_pr(find_snacks_pr(snacks._build_pr_items(PRS), number))
			local s_num = checkout_calls[1]

			checkout_calls = {}
			telescope._confirm_pr(find_telescope_pr(telescope._build_pr_items(PRS), number))
			local t_num = checkout_calls[1]

			checkout_calls = {}
			local built = fzf._build_pr_items(PRS)
			fzf._confirm_pr({ find_fzf_pr_line(built, number) }, built.lookup)
			local f_num = checkout_calls[1]

			assert.equals(1234, s_num)
			assert.equals(s_num, t_num)
			assert.equals(s_num, f_num)
		end)
	end)
end)
