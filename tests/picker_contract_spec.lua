-- Picker contract spec — mirrors tests/provider_contract_spec.lua.
--
-- The picker layer has three pluggable backends (snacks/telescope/fzf) resolved
-- by string lookup in lua/pr/picker.lua. They must all expose the same surface
-- so any picker-touching feature works regardless of which backend the user
-- configures. This spec enforces two layers of that contract:
--
--   1. Surface — every backend exposes the resolver-dispatched entry points
--      (pick_comments / pick_hunks / pick_prs) and the shared filter helpers
--      (unresolved / resolved / non_outdated / outdated) as functions.
--   2. Behavior — the four filter helpers are pure `(Comments) -> Comments`
--      functions in all three backends; feeding the same fixture through each
--      backend's helper must produce identical output. If a backend diverges
--      (e.g. someone adds a side-effect, drops a thread, or changes the
--      filtering rule), this test fires loudly.
--
-- The backend modules are safe to require even without their UI dependencies
-- installed: snacks.lua wraps its `require("snacks")` in pcall, and
-- telescope.lua / fzf.lua defer their UI requires to inside pick_comments etc.

local REQUIRED_METHODS = {
	-- Resolver-dispatched entry points.
	"pick_comments",
	"pick_hunks",
	"pick_prs",
	-- Shared filter helpers — pure (Comments) -> Comments. Used by init.lua
	-- bindings and the pickers themselves to honor the user's filter toggles.
	"unresolved",
	"resolved",
	"non_outdated",
	"outdated",
}

local pickers = {
	snacks = require("pr.pickers.snacks"),
	telescope = require("pr.pickers.telescope"),
	fzf = require("pr.pickers.fzf"),
}

-- ---------------------------------------------------------------------------
-- Fixture for the behavioral filter tests.
-- A Comments value: `table<relative_path, ReviewThread[]>`. Build one with a
-- mix of resolved/unresolved and outdated/current so every helper has both
-- "kept" and "dropped" entries to act on in each file.
-- ---------------------------------------------------------------------------

local function mk_thread(id, is_resolved, is_outdated)
	return {
		id = id,
		is_resolved = is_resolved,
		is_outdated = is_outdated,
		viewer_can_reply = true,
		comments = {
			{ database_id = id, author = "alice", body = "x", start_line = 1, end_line = 1 },
		},
	}
end

local FIXTURE = {
	["foo.lua"] = {
		mk_thread(1, false, false), -- open, current
		mk_thread(2, true, false), -- resolved, current
		mk_thread(3, false, true), -- open, outdated
		mk_thread(4, true, true), -- resolved, outdated
	},
	["bar.lua"] = {
		mk_thread(5, false, false), -- open, current
		mk_thread(6, true, false), -- resolved, current
	},
	-- A file that contains only filterable threads: when filtered out, the file
	-- key should disappear from the result map (every backend drops empty
	-- file entries — verified below).
	["only_resolved.lua"] = {
		mk_thread(7, true, false),
	},
}

---Extract the sorted set of thread IDs in the returned Comments value, so we
---can compare backend outputs by identity without caring about key ordering.
local function ids(result)
	local out = {}
	for _, threads in pairs(result) do
		for _, t in ipairs(threads) do
			table.insert(out, t.id)
		end
	end
	table.sort(out)
	return out
end

---Sorted set of file keys in the result, for the "empty files dropped" check.
local function files(result)
	local out = {}
	for f, _ in pairs(result) do
		table.insert(out, f)
	end
	table.sort(out)
	return out
end

-- ---------------------------------------------------------------------------
-- 1. Surface
-- ---------------------------------------------------------------------------

describe("picker contract: surface", function()
	for name, p in pairs(pickers) do
		describe(name, function()
			for _, method in ipairs(REQUIRED_METHODS) do
				it("exposes method `" .. method .. "`", function()
					assert.equals("function", type(p[method]), name .. " missing method: " .. method)
				end)
			end
		end)
	end
end)

-- ---------------------------------------------------------------------------
-- 2. Behavior — filter helpers
-- ---------------------------------------------------------------------------

describe("picker contract: filter helpers behave identically across backends", function()
	-- Compute the expected output from the fixture once. We use the snacks
	-- backend as the reference and assert telescope/fzf match it; if snacks
	-- ever drifts, the per-helper "expected IDs" sub-tests below catch it
	-- against an absolute expectation independent of any backend.
	local helpers = { "unresolved", "resolved", "non_outdated", "outdated" }

	for _, helper in ipairs(helpers) do
		it(helper .. " returns identical thread IDs across snacks/telescope/fzf", function()
			local snacks_out = pickers.snacks[helper](FIXTURE)
			local telescope_out = pickers.telescope[helper](FIXTURE)
			local fzf_out = pickers.fzf[helper](FIXTURE)

			assert.are.same(ids(snacks_out), ids(telescope_out), helper .. ": telescope diverges from snacks")
			assert.are.same(ids(snacks_out), ids(fzf_out), helper .. ": fzf diverges from snacks")
			-- Files dropped when their thread list becomes empty post-filter:
			-- every backend must agree on the surviving file keys too.
			assert.are.same(files(snacks_out), files(telescope_out), helper .. ": telescope file keys diverge")
			assert.are.same(files(snacks_out), files(fzf_out), helper .. ": fzf file keys diverge")
		end)
	end

	-- Absolute expectations — these guarantee that the cross-backend equality
	-- above isn't accidentally satisfied by all three returning the wrong
	-- answer in the same way (e.g. all returning {} or all returning the
	-- input unchanged).
	it("unresolved keeps only is_resolved == false threads", function()
		local expected = { 1, 3, 5 }
		for name, p in pairs(pickers) do
			assert.are.same(expected, ids(p.unresolved(FIXTURE)), name)
		end
	end)

	it("resolved keeps only is_resolved == true threads", function()
		local expected = { 2, 4, 6, 7 }
		for name, p in pairs(pickers) do
			assert.are.same(expected, ids(p.resolved(FIXTURE)), name)
		end
	end)

	it("non_outdated keeps only is_outdated == false threads", function()
		local expected = { 1, 2, 5, 6, 7 }
		for name, p in pairs(pickers) do
			assert.are.same(expected, ids(p.non_outdated(FIXTURE)), name)
		end
	end)

	it("outdated keeps only is_outdated == true threads", function()
		local expected = { 3, 4 }
		for name, p in pairs(pickers) do
			assert.are.same(expected, ids(p.outdated(FIXTURE)), name)
		end
	end)

	it("drops files whose thread list becomes empty after filtering", function()
		-- only_resolved.lua has one resolved thread; after `unresolved`, that
		-- file should disappear from the result map entirely.
		for name, p in pairs(pickers) do
			local out = p.unresolved(FIXTURE)
			assert.is_nil(out["only_resolved.lua"], name .. " kept an empty file entry")
		end
	end)

	it("returns an empty table when input is empty (no nil maps)", function()
		for name, p in pairs(pickers) do
			for _, helper in ipairs(helpers) do
				local out = p[helper]({})
				assert.equals("table", type(out), name .. "." .. helper .. " returned non-table for empty input")
				assert.are.equal(0, vim.tbl_count(out), name .. "." .. helper .. " returned non-empty for empty input")
			end
		end
	end)

	it("does not mutate the input Comments table", function()
		-- Filter helpers are pure: build a deep copy of the fixture, run every
		-- helper against the original, and assert the original is byte-for-byte
		-- equal to the snapshot afterward. (vim.deep_equal handles nested
		-- comparison.)
		local snapshot = vim.deepcopy(FIXTURE)
		for _, p in pairs(pickers) do
			for _, helper in ipairs(helpers) do
				p[helper](FIXTURE)
			end
		end
		assert.is_true(vim.deep_equal(snapshot, FIXTURE), "a backend mutated the input Comments table")
	end)
end)
