-- Tests for lua/pr/hunk.lua's draw cycle: line-background extmarks for diff
-- hunks under a real headless buffer. Sibling of tests/comment_attach_spec.lua
-- — hunks and comments are the "two parallel feature modules" called out in
-- CLAUDE.md and share the same fake-provider + drift-stub scaffolding.
--
-- Differences from comment.lua worth covering here:
--   * hunks decorate via extmarks (line_hl_group) in `diff_ns_id`, not via signs
--   * hl_group is computed from the hunk.type field as "PRDiff" .. type, so the
--     test asserts the group string the renderer emits (not the colour itself)
--   * hunk.draw has no outdated/resolved gating and does not publish diagnostics
--   * an empty hunks list short-circuits BEFORE drift.get_for_buffer is called,
--     which is asserted directly below
--
-- We do not assert idempotence on repeated draw calls: hunk.draw doesn't set an
-- M.bufs guard, so a second call stacks extmarks. That's the current behaviour
-- and outside this spec's scope to change.

local config = require("pr.config")
config.opts = config.opts or {}

-- ---------------------------------------------------------------------------
-- Fake provider
-- ---------------------------------------------------------------------------

local FAKE_PROVIDER = "hunk_attach_fake"

---@type table
local fake
fake = {
	-- hunk.draw reads git.hunks indirectly via get_hunks(cb), where the cb
	-- receives the full Hunks map. We keep `hunks` as a mutable field the
	-- tests can rewrite per-case, and have get_hunks return it.
	hunks = {},
	comments = {},
	reaction_palette = {},
	get_git_user = function(_, cb)
		if cb then
			cb("tester")
		end
	end,
	get_git_root = function(cb)
		cb("/tmp/hunk_attach_fake_repo")
	end,
	get_hunks = function(cb)
		cb(fake.hunks)
	end,
	get_comments = function(cb)
		cb(fake.comments)
	end,
	clear = function() end,
	clear_hunks = function()
		fake.hunks = {}
	end,
}

package.loaded["pr.providers." .. FAKE_PROVIDER] = fake
config.opts.provider = FAKE_PROVIDER

-- ---------------------------------------------------------------------------
-- Drift stub
-- ---------------------------------------------------------------------------

local get_for_buffer_calls = {}
local next_drift_map = nil

local drift_stub = {
	get_for_buffer = function(bufnr, git_root, relative_path, callback)
		table.insert(get_for_buffer_calls, { bufnr = bufnr, git_root = git_root, relative_path = relative_path })
		callback(next_drift_map)
	end,
	invalidate = function() end,
	invalidate_all = function() end,
	commit_to_buffer = function(_drift_map, commit_line)
		return commit_line
	end,
	buffer_to_commit = function(_drift_map, buffer_line)
		return buffer_line
	end,
}

package.loaded["pr.drift"] = drift_stub

-- Require the module AFTER stubs are installed so its `local drift = require(...)`
-- closes over our stub.
local hunk = require("pr.hunk")

-- ---------------------------------------------------------------------------
-- Fixture helpers
-- ---------------------------------------------------------------------------

local FAKE_ROOT = "/tmp/hunk_attach_fake_repo"

local function make_buf_with_name(relative)
	local buf = vim.api.nvim_create_buf(false, false)
	vim.api.nvim_buf_set_name(buf, FAKE_ROOT .. "/" .. relative)
	-- Pad with content so line numbers in fixtures fall inside the buffer.
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"line1",
		"line2",
		"line3",
		"line4",
		"line5",
		"line6",
		"line7",
		"line8",
		"line9",
		"line10",
	})
	return buf
end

---@param opts? { hunk_start: integer, hunk_end: integer, type: string }
local function mk_hunk(opts)
	opts = opts or {}
	return {
		hunk_start = opts.hunk_start or 1,
		hunk_end = opts.hunk_end or opts.hunk_start or 1,
		-- Use "Add" by default; provider-emitted values are "Add" | "Del" | "Change".
		type = opts.type or "Add",
	}
end

---Return all extmarks in the diff_ns_id namespace as an array of
---`{ start_row, end_row, hl_group }` (1-indexed for readability), sorted by
---start_row.
local function extmarks_for_buf(buf)
	local marks = vim.api.nvim_buf_get_extmarks(buf, config.opts.highlights.diff_ns_id, 0, -1, { details = true })
	local out = {}
	for _, m in ipairs(marks) do
		-- m = { id, start_row, start_col, details }
		local details = m[4] or {}
		table.insert(out, {
			start_row = m[2] + 1, -- 1-indexed for readability
			end_row = (details.end_row or m[2]) + 1,
			hl_group = details.line_hl_group,
		})
	end
	table.sort(out, function(a, b)
		return a.start_row < b.start_row
	end)
	return out
end

local function reset_state(buf_to_clear)
	if buf_to_clear and vim.api.nvim_buf_is_valid(buf_to_clear) then
		pcall(vim.api.nvim_buf_clear_namespace, buf_to_clear, config.opts.highlights.diff_ns_id, 0, -1)
	end
	hunk.bufs = {}
	hunk.wins = {}
	hunk.generations = {}
	next_drift_map = nil
	get_for_buffer_calls = {}
	fake.hunks = {}
	drift_stub.commit_to_buffer = function(_drift_map, commit_line)
		return commit_line
	end
end

---Drive M.draw to completion. hunk.draw schedules through vim.schedule_wrap;
---poll until the supplied predicate flips (or the timeout elapses).
local function draw_and_wait(buf, predicate, timeout_ms)
	hunk.draw(buf)
	local deadline = (vim.uv or vim.loop).hrtime() + (timeout_ms or 300) * 1e6
	while (vim.uv or vim.loop).hrtime() < deadline do
		if predicate() then
			return true
		end
		vim.wait(10, function()
			return false
		end)
	end
	return predicate()
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("pr.hunk.draw — extmark placement", function()
	local buf
	before_each(function()
		reset_state(buf)
		buf = make_buf_with_name("foo.lua")
	end)
	after_each(function()
		reset_state(buf)
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end)

	it("places a single-line extmark with PRDiffAdd for a 1-line Add hunk", function()
		fake.hunks = {
			["foo.lua"] = { mk_hunk({ hunk_start = 3, hunk_end = 3, type = "Add" }) },
		}
		assert.is_true(draw_and_wait(buf, function()
			return #extmarks_for_buf(buf) > 0
		end))
		local marks = extmarks_for_buf(buf)
		assert.are.equal(1, #marks)
		assert.are.equal(3, marks[1].start_row)
		assert.are.equal(3, marks[1].end_row)
		assert.are.equal("PRDiffAdd", marks[1].hl_group)
	end)

	it("places a multi-line extmark spanning hunk_start..hunk_end", function()
		fake.hunks = {
			["foo.lua"] = { mk_hunk({ hunk_start = 2, hunk_end = 5, type = "Add" }) },
		}
		assert.is_true(draw_and_wait(buf, function()
			return #extmarks_for_buf(buf) > 0
		end))
		local marks = extmarks_for_buf(buf)
		assert.are.equal(1, #marks)
		assert.are.equal(2, marks[1].start_row)
		assert.are.equal(5, marks[1].end_row)
	end)

	it("emits one extmark per hunk for a file with multiple hunks", function()
		fake.hunks = {
			["foo.lua"] = {
				mk_hunk({ hunk_start = 1, hunk_end = 1, type = "Add" }),
				mk_hunk({ hunk_start = 4, hunk_end = 4, type = "Del" }),
				mk_hunk({ hunk_start = 7, hunk_end = 8, type = "Change" }),
			},
		}
		assert.is_true(draw_and_wait(buf, function()
			return #extmarks_for_buf(buf) >= 3
		end))
		local marks = extmarks_for_buf(buf)
		assert.are.equal(3, #marks)
		assert.are.equal(1, marks[1].start_row)
		assert.are.equal(4, marks[2].start_row)
		assert.are.equal(7, marks[3].start_row)
	end)

	it("uses hl_group = 'PRDiff' .. hunk.type for every variant", function()
		fake.hunks = {
			["foo.lua"] = {
				mk_hunk({ hunk_start = 1, hunk_end = 1, type = "Add" }),
				mk_hunk({ hunk_start = 3, hunk_end = 3, type = "Del" }),
				mk_hunk({ hunk_start = 5, hunk_end = 5, type = "Change" }),
			},
		}
		assert.is_true(draw_and_wait(buf, function()
			return #extmarks_for_buf(buf) >= 3
		end))
		local marks = extmarks_for_buf(buf)
		assert.are.equal("PRDiffAdd", marks[1].hl_group)
		assert.are.equal("PRDiffDel", marks[2].hl_group)
		assert.are.equal("PRDiffChange", marks[3].hl_group)
	end)
end)

describe("pr.hunk.draw — empty / missing hunks short-circuit", function()
	local buf
	before_each(function()
		reset_state(buf)
		buf = make_buf_with_name("foo.lua")
	end)
	after_each(function()
		reset_state(buf)
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end)

	it("places no extmarks and does not call drift when no hunks exist for the file", function()
		fake.hunks = { ["bar.lua"] = { mk_hunk() } } -- nothing for foo.lua
		hunk.draw(buf)
		-- Give the scheduler a chance to run the get_hunks callback.
		vim.wait(50, function()
			return false
		end)
		assert.are.equal(0, #extmarks_for_buf(buf))
		assert.are.equal(0, #get_for_buffer_calls, "drift should not be consulted when there are no hunks")
	end)

	it("places no extmarks when the hunks list is empty entirely", function()
		fake.hunks = {}
		hunk.draw(buf)
		vim.wait(50, function()
			return false
		end)
		assert.are.equal(0, #extmarks_for_buf(buf))
		assert.are.equal(0, #get_for_buffer_calls)
	end)
end)

describe("pr.hunk.draw — drift translation", function()
	local buf
	before_each(function()
		reset_state(buf)
		buf = make_buf_with_name("foo.lua")
	end)
	after_each(function()
		reset_state(buf)
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end)

	it("relocates extmarks via drift.commit_to_buffer when a drift_map is present", function()
		next_drift_map = { hunks = {} }
		-- Shift commit lines by +2: simulates two prepended buffer-only lines.
		drift_stub.commit_to_buffer = function(_drift_map, commit_line)
			return commit_line + 2
		end

		fake.hunks = {
			["foo.lua"] = { mk_hunk({ hunk_start = 3, hunk_end = 4, type = "Add" }) },
		}
		assert.is_true(draw_and_wait(buf, function()
			return #extmarks_for_buf(buf) > 0
		end))
		local marks = extmarks_for_buf(buf)
		assert.are.equal(1, #marks)
		assert.are.equal(5, marks[1].start_row)
		assert.are.equal(6, marks[1].end_row)
	end)

	it("drops a hunk when either drift-translated end-point is nil", function()
		next_drift_map = { hunks = {} }
		-- Pretend commit-line 3 was deleted in the working tree.
		drift_stub.commit_to_buffer = function(_drift_map, commit_line)
			if commit_line == 3 then
				return nil
			end
			return commit_line
		end

		fake.hunks = {
			["foo.lua"] = {
				-- start was deleted -> the whole hunk drops
				mk_hunk({ hunk_start = 3, hunk_end = 4, type = "Add" }),
				-- end was deleted -> also drops
				mk_hunk({ hunk_start = 2, hunk_end = 3, type = "Add" }),
				-- neither endpoint deleted -> survives
				mk_hunk({ hunk_start = 5, hunk_end = 5, type = "Change" }),
			},
		}
		assert.is_true(draw_and_wait(buf, function()
			return #extmarks_for_buf(buf) > 0
		end))
		local marks = extmarks_for_buf(buf)
		assert.are.equal(1, #marks, "only the un-deleted hunk should be marked")
		assert.are.equal(5, marks[1].start_row)
		assert.are.equal("PRDiffChange", marks[1].hl_group)
	end)
end)

describe("pr.hunk.draw — generation guard", function()
	-- M.generations[buf] is bumped on BufWritePost (see lua/pr/hunk.lua:212).
	-- If the generation moves between scheduling and the drift callback firing,
	-- the late callback must NOT decorate the buffer (otherwise stale hunks
	-- paint over a freshly-written buffer). We exercise that branch by
	-- bumping the generation between hunk.draw() and the drift callback.
	local buf
	before_each(function()
		reset_state(buf)
		buf = make_buf_with_name("foo.lua")
	end)
	after_each(function()
		reset_state(buf)
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end)

	it("skips decoration when the buffer generation has been bumped since draw was called", function()
		-- Replace drift.get_for_buffer so the test can interleave a generation
		-- bump between the get_hunks callback running and the drift callback
		-- firing. The original stub calls callback() inline; here we capture
		-- and call it manually after mutating generations.
		local original = drift_stub.get_for_buffer
		local captured_cb
		drift_stub.get_for_buffer = function(_, _, _, cb)
			captured_cb = cb
		end

		fake.hunks = {
			["foo.lua"] = { mk_hunk({ hunk_start = 1, hunk_end = 1, type = "Add" }) },
		}
		hunk.draw(buf)
		-- Wait for get_hunks to schedule and drift.get_for_buffer to be invoked.
		assert.is_true(vim.wait(200, function()
			return captured_cb ~= nil
		end))

		-- Bump the generation before the drift callback runs.
		hunk.generations[buf] = (hunk.generations[buf] or 0) + 1
		captured_cb(nil)

		assert.are.equal(0, #extmarks_for_buf(buf), "stale draw should not decorate the buffer")

		-- Restore for subsequent tests.
		drift_stub.get_for_buffer = original
	end)
end)
