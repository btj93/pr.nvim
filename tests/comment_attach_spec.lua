-- Tests for lua/pr/comment.lua's attach/draw cycle: signs placed on the right
-- lines, resolved/outdated gating, drift translation, multi-line ranges, and
-- the clear/refresh paths. This is the biggest untested side-effect surface in
-- the plugin — extmark/sign emission for real buffers under a fake provider.
--
-- Strategy:
--   * Install a fake provider into package.loaded so the access-time proxy in
--     pr.provider routes through it (same approach as tests/ui_actions_spec).
--   * Replace pr.drift and pr.diagnostics in package.loaded BEFORE requiring
--     pr.comment, so the comment module captures the stubs rather than the
--     real modules (which shell out / publish vim.diagnostic entries we don't
--     want polluting other tests).
--   * Define the sign names the same way init.lua's setup() does, so
--     sign_place / sign_getplaced round-trip cleanly.

local config = require("pr.config")
config.opts = config.opts or {}

-- ---------------------------------------------------------------------------
-- Fake provider
-- ---------------------------------------------------------------------------

local FAKE_PROVIDER = "comment_attach_fake"

-- comment.lua reads `git.comments[relative_path]` synchronously inside the
-- get_comments callback chain in M.refresh, but M.draw reads it directly as
-- a field — see lua/pr/comment.lua:57. We keep `fake` as a forward-declared
-- local so the closures below can reference it without tripping luacheck's
-- undefined-variable rule for self-referential table literals.
---@type table
local fake
fake = {
	comments = {},
	reaction_palette = {},
	-- Synchronous stubs so the scheduled callbacks chain off `vim.wait` cleanly.
	get_git_user = function(_, cb)
		if cb then
			cb("tester")
		end
	end,
	get_git_root = function(cb)
		cb("/tmp/comment_attach_fake_repo")
	end,
	get_hunks = function(cb)
		cb({})
	end,
	get_comments = function(cb)
		cb(fake.comments)
	end,
	clear = function() end,
	clear_comments = function()
		fake.comments = {}
	end,
}

package.loaded["pr.providers." .. FAKE_PROVIDER] = fake
config.opts.provider = FAKE_PROVIDER

-- ---------------------------------------------------------------------------
-- Drift + diagnostics stubs
-- ---------------------------------------------------------------------------

-- Drift defaults to identity (drift_map = nil short-circuits commit_to_buffer
-- in comment.draw so start_line/end_line are used verbatim).
--
-- All entries below are *module function* signatures — comment.lua calls
-- `drift.get_for_buffer(buf, ...)` and `drift.commit_to_buffer(drift_map, line)`,
-- not `drift:get_for_buffer(...)`. Tracking state lives on the surrounding
-- locals (get_for_buffer_calls / next_drift_map) so the stubs are plain
-- functions without a `self` slot.
local get_for_buffer_calls = {}
local next_drift_map = nil

local drift_stub = {
	get_for_buffer = function(bufnr, git_root, relative_path, callback)
		table.insert(get_for_buffer_calls, { bufnr = bufnr, git_root = git_root, relative_path = relative_path })
		callback(next_drift_map)
	end,
	invalidate = function() end,
	invalidate_all = function() end,
	-- commit_to_buffer is called when a drift_map is supplied; for the
	-- identity-drift path (drift_map = nil) it isn't invoked. The drift_map
	-- branch test reassigns this in-place.
	commit_to_buffer = function(_drift_map, commit_line)
		return commit_line
	end,
	buffer_to_commit = function(_drift_map, buffer_line)
		return buffer_line
	end,
}

local publish_calls = {}
local diagnostics_stub = {
	publish = function(buf, comments, drift_map)
		table.insert(publish_calls, { buf = buf, comments = comments, drift_map = drift_map })
	end,
	clear = function() end,
	clear_all = function() end,
}

-- IMPORTANT: stubs must be installed BEFORE the require below so that
-- comment.lua's `local drift = require("pr.drift")` and the pcall'd require
-- inside M.draw resolve to our stubs.
package.loaded["pr.drift"] = drift_stub
package.loaded["pr.diagnostics"] = diagnostics_stub

-- Now require the module under test.
local comment = require("pr.comment")

-- ---------------------------------------------------------------------------
-- Sign definitions (mirrors what lua/pr/init.lua's setup() does)
-- ---------------------------------------------------------------------------

local function define_signs()
	local h = config.opts.highlights
	pcall(vim.fn.sign_define, h.sign_comment, { text = "║", texthl = "PRSignComment" })
	pcall(vim.fn.sign_define, h.sign_comment_multi_line_start, { text = "┌", texthl = "PRSignComment" })
	pcall(vim.fn.sign_define, h.sign_comment_multi_line_connector, { text = "│", texthl = "PRSignComment" })
	pcall(vim.fn.sign_define, h.sign_comment_multi_line_end, { text = "└", texthl = "PRSignComment" })
end

define_signs()

-- ---------------------------------------------------------------------------
-- Fixture helpers
-- ---------------------------------------------------------------------------

local FAKE_ROOT = "/tmp/comment_attach_fake_repo"

local function make_buf_with_name(relative)
	local buf = vim.api.nvim_create_buf(false, false)
	vim.api.nvim_buf_set_name(buf, FAKE_ROOT .. "/" .. relative)
	-- Add enough lines that line numbers in fixtures fall inside the buffer.
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line1", "line2", "line3", "line4", "line5", "line6", "line7", "line8" })
	return buf
end

local function mk_thread(opts)
	opts = opts or {}
	return {
		id = opts.id or ("T_" .. tostring(math.random(1, 1e6))),
		is_resolved = opts.is_resolved or false,
		is_outdated = opts.is_outdated or false,
		viewer_can_reply = true,
		viewer_can_resolve = true,
		viewer_can_unresolve = true,
		comments = {
			{
				database_id = opts.database_id or 1,
				author = "alice",
				body = "hi",
				start_line = opts.start_line or 1,
				end_line = opts.end_line or 1,
			},
		},
	}
end

local function signs_for_buf(buf)
	local out = {}
	local placed = vim.fn.sign_getplaced(buf, { group = config.opts.highlights.sign_group })
	for _, group in ipairs(placed or {}) do
		for _, s in ipairs(group.signs or {}) do
			table.insert(out, { lnum = s.lnum, name = s.name })
		end
	end
	table.sort(out, function(a, b)
		return a.lnum < b.lnum
	end)
	return out
end

local function reset_state(buf_to_clear)
	-- Per-test cleanup: drop any leftover signs, reset module state, and clear
	-- captured calls so each test starts from a clean slate.
	if buf_to_clear and vim.api.nvim_buf_is_valid(buf_to_clear) then
		pcall(vim.fn.sign_unplace, config.opts.highlights.sign_group, { buffer = buf_to_clear })
	end
	pcall(vim.fn.sign_unplace, config.opts.highlights.sign_group)
	comment.bufs = {}
	comment.wins = {}
	comment.generations = {}
	next_drift_map = nil
	get_for_buffer_calls = {}
	publish_calls = {}
	-- Reset commit_to_buffer to identity so per-test overrides don't leak
	-- (the drift-translation tests reassign this and we want a clean slate
	-- before/after each case).
	drift_stub.commit_to_buffer = function(_drift_map, commit_line)
		return commit_line
	end
	fake.comments = {}
	-- Reset show-resolved/show-outdated to defaults.
	config.opts.show_resolved_inline = false
	config.opts.show_outdated_inline = false
end

-- Helper that drives M.draw to completion. comment.draw spawns work through
-- vim.schedule_wrap; we wait until the signs we expect (or expect-not) settle.
local function draw_and_wait(buf, predicate, timeout_ms)
	comment.draw(buf)
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

describe("pr.comment.draw — sign placement", function()
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

	it("places a single sign for a single-line open thread", function()
		fake.comments = {
			["foo.lua"] = { mk_thread({ start_line = 3, end_line = 3 }) },
		}
		assert.is_true(draw_and_wait(buf, function()
			return #signs_for_buf(buf) > 0
		end))
		local signs = signs_for_buf(buf)
		assert.are.equal(1, #signs)
		assert.are.equal(3, signs[1].lnum)
		assert.are.equal(config.opts.highlights.sign_comment, signs[1].name)
	end)

	it("places start/connector/end signs for a multi-line thread", function()
		fake.comments = {
			["foo.lua"] = { mk_thread({ start_line = 2, end_line = 5 }) },
		}
		assert.is_true(draw_and_wait(buf, function()
			return #signs_for_buf(buf) >= 4
		end))
		local signs = signs_for_buf(buf)
		-- Expect: start@2, connector@3, connector@4, end@5
		assert.are.equal(4, #signs)
		assert.are.equal(2, signs[1].lnum)
		assert.are.equal(config.opts.highlights.sign_comment_multi_line_start, signs[1].name)
		assert.are.equal(3, signs[2].lnum)
		assert.are.equal(config.opts.highlights.sign_comment_multi_line_connector, signs[2].name)
		assert.are.equal(4, signs[3].lnum)
		assert.are.equal(config.opts.highlights.sign_comment_multi_line_connector, signs[3].name)
		assert.are.equal(5, signs[4].lnum)
		assert.are.equal(config.opts.highlights.sign_comment_multi_line_end, signs[4].name)
	end)

	it("places no signs when no threads exist for the file", function()
		fake.comments = {} -- nothing for foo.lua
		comment.draw(buf)
		-- Without comments draw early-exits before scheduling; nothing to wait for.
		vim.wait(50, function()
			return false
		end)
		assert.are.equal(0, #signs_for_buf(buf))
	end)
end)

describe("pr.comment.draw — resolved/outdated gating", function()
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

	it("skips resolved threads by default", function()
		fake.comments = {
			["foo.lua"] = {
				mk_thread({ start_line = 1, end_line = 1, is_resolved = true, id = "resolved" }),
				mk_thread({ start_line = 2, end_line = 2, is_resolved = false, id = "open" }),
			},
		}
		assert.is_true(draw_and_wait(buf, function()
			return #signs_for_buf(buf) >= 1
		end))
		local signs = signs_for_buf(buf)
		assert.are.equal(1, #signs, "only the open thread should be signed")
		assert.are.equal(2, signs[1].lnum)
	end)

	it("includes resolved threads when show_resolved_inline = true", function()
		config.opts.show_resolved_inline = true
		fake.comments = {
			["foo.lua"] = {
				mk_thread({ start_line = 1, end_line = 1, is_resolved = true }),
				mk_thread({ start_line = 2, end_line = 2, is_resolved = false }),
			},
		}
		assert.is_true(draw_and_wait(buf, function()
			return #signs_for_buf(buf) >= 2
		end))
		assert.are.equal(2, #signs_for_buf(buf))
	end)

	it("skips outdated threads by default", function()
		fake.comments = {
			["foo.lua"] = {
				mk_thread({ start_line = 1, end_line = 1, is_outdated = true, id = "old" }),
				mk_thread({ start_line = 2, end_line = 2, is_outdated = false, id = "new" }),
			},
		}
		assert.is_true(draw_and_wait(buf, function()
			return #signs_for_buf(buf) >= 1
		end))
		local signs = signs_for_buf(buf)
		assert.are.equal(1, #signs, "only the current thread should be signed")
		assert.are.equal(2, signs[1].lnum)
	end)

	it("includes outdated threads when show_outdated_inline = true", function()
		config.opts.show_outdated_inline = true
		fake.comments = {
			["foo.lua"] = {
				mk_thread({ start_line = 1, end_line = 1, is_outdated = true }),
				mk_thread({ start_line = 2, end_line = 2, is_outdated = false }),
			},
		}
		assert.is_true(draw_and_wait(buf, function()
			return #signs_for_buf(buf) >= 2
		end))
		assert.are.equal(2, #signs_for_buf(buf))
	end)
end)

describe("pr.comment.draw — drift translation", function()
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

	it("uses drift.commit_to_buffer to relocate signs when a drift_map is present", function()
		-- Stub drift to shift commit lines by +2 (simulating two prepended
		-- buffer-only lines). A thread anchored to commit-line 3 should now
		-- render at buffer-line 5.
		next_drift_map = { hunks = {} }
		drift_stub.commit_to_buffer = function(_drift_map, commit_line)
			return commit_line + 2
		end

		fake.comments = {
			["foo.lua"] = { mk_thread({ start_line = 3, end_line = 3 }) },
		}
		assert.is_true(draw_and_wait(buf, function()
			return #signs_for_buf(buf) > 0
		end))
		local signs = signs_for_buf(buf)
		assert.are.equal(1, #signs)
		assert.are.equal(5, signs[1].lnum)
	end)

	it("drops threads whose drift-translated line is nil (line removed in buffer)", function()
		next_drift_map = { hunks = {} }
		drift_stub.commit_to_buffer = function(_drift_map, commit_line)
			-- Pretend commit-line 3 has been removed from the working tree.
			if commit_line == 3 then
				return nil
			end
			return commit_line
		end

		fake.comments = {
			["foo.lua"] = {
				mk_thread({ start_line = 3, end_line = 3, id = "deleted" }),
				mk_thread({ start_line = 4, end_line = 4, id = "kept" }),
			},
		}
		assert.is_true(draw_and_wait(buf, function()
			return #signs_for_buf(buf) >= 1
		end))
		local signs = signs_for_buf(buf)
		assert.are.equal(1, #signs)
		assert.are.equal(4, signs[1].lnum)
	end)
end)

describe("pr.comment.draw — idempotence + diagnostics publish", function()
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

	it("short-circuits when called twice in a row (M.bufs flag set)", function()
		fake.comments = {
			["foo.lua"] = { mk_thread({ start_line = 1, end_line = 1 }) },
		}
		assert.is_true(draw_and_wait(buf, function()
			return #signs_for_buf(buf) >= 1
		end))
		local first = #get_for_buffer_calls
		-- Second draw should be a no-op: comment.bufs[buf] is already true so
		-- the function returns before scheduling any work.
		comment.draw(buf)
		vim.wait(30, function()
			return false
		end)
		assert.are.equal(first, #get_for_buffer_calls)
	end)

	it("publishes diagnostics for the buffer's threads", function()
		fake.comments = {
			["foo.lua"] = { mk_thread({ start_line = 1, end_line = 1 }) },
		}
		assert.is_true(draw_and_wait(buf, function()
			return #publish_calls > 0
		end))
		local call = publish_calls[1]
		assert.are.equal(buf, call.buf)
		-- publish receives the full thread list (drift gating is per-thread).
		assert.are.equal(1, #call.comments)
	end)
end)
