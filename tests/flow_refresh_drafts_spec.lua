-- Tier 2 flow spec for the drafts sweep at the tail of `comment.refresh`.
--
-- Unlike tests/flow_refresh_spec.lua, which stubs `pr.drafts` to spy on the
-- wiring, this spec drives the REAL drafts module against a tempfile so the
-- assertions are about bytes on disk. The case that matters is a refetch that
-- settles with `(fallback, err)`: the fallback is empty, the cache was already
-- emptied by `clear_comments`, and an ungated sweep would therefore treat every
-- draft the user is writing as an orphan and delete it.

local config = require("pr.config")
config.opts = config.opts or {}

package.loaded["pr.drift"] = {
	get_for_buffer = function(_bufnr, _root, _rel, cb)
		cb(nil)
	end,
	invalidate = function() end,
	invalidate_all = function() end,
	commit_to_buffer = function(_m, line)
		return line
	end,
	buffer_to_commit = function(_m, line)
		return line
	end,
}

package.loaded["pr.diagnostics"] = {
	namespace = vim.api.nvim_create_namespace("pr_threads_flow_refresh_drafts"),
	publish = function() end,
	clear = function() end,
	clear_all = function() end,
}

local fake_provider = require("helpers.fake_provider")
local drafts = require("pr.drafts")
local comment = require("pr.comment")

local FAKE = "flow_refresh_drafts_fake"

local function mk_thread(id, line, db)
	return {
		id = id,
		is_resolved = false,
		is_outdated = false,
		viewer_can_reply = true,
		comments = {
			{
				database_id = db or 1001,
				author = "alice",
				body = "hi",
				updated_at = "2026-01-01T00:00:00Z",
				start_line = line,
				end_line = line,
			},
		},
	}
end

describe("flow: refresh drafts sweep", function()
	local fake, uninstall, saved_notify, refreshed, grp

	local function seed_drafts()
		drafts._set_path(vim.fn.tempname())
		drafts.save_edit(1001, { body = "half-written edit", updated_at = "2026-01-01T00:00:00Z" })
		drafts.save_reply("T1", { body = "half-written reply" })
		drafts.save_new("foo.lua:1:1", { body = "half-written new comment" })
		drafts.flush()
	end

	local function surviving()
		drafts._reload()
		return {
			edit = drafts.get_edit(1001) and drafts.get_edit(1001).body or nil,
			reply = drafts.get_reply("T1") and drafts.get_reply("T1").body or nil,
			new = drafts.get_new("foo.lua:1:1") and drafts.get_new("foo.lua:1:1").body or nil,
		}
	end

	before_each(function()
		comment.enabled = false
		comment.wins = {}
		comment.bufs = {}
		comment.generations = {}

		saved_notify = vim.notify
		vim.notify = function() end

		refreshed = 0
		grp = vim.api.nvim_create_augroup("PRFlowRefreshDrafts", { clear = true })
		vim.api.nvim_create_autocmd("User", {
			group = grp,
			pattern = "PRCommentsRefreshed",
			callback = function()
				refreshed = refreshed + 1
			end,
		})

		fake, uninstall = fake_provider.install(FAKE, { comments = {}, hunks = {} })
	end)

	after_each(function()
		vim.wait(100, function()
			return false
		end)
		comment.enabled = false
		comment.wins = {}
		comment.bufs = {}
		vim.notify = saved_notify
		pcall(vim.api.nvim_del_augroup_by_id, grp)
		if uninstall then
			uninstall()
		end
	end)

	it("a rejected refetch leaves every persisted draft on disk", function()
		fake.scenario.comments = { ["foo.lua"] = { mk_thread("T1", 1, 1001) } }
		fake.comments = fake.scenario.comments
		comment.enabled = true
		seed_drafts()

		fake.get_comments = function(cb)
			table.insert(fake.calls, { method = "get_comments", args = {} })
			cb({}, "review-thread fetch failed")
		end

		comment.refresh()
		assert.is_true(
			vim.wait(1000, function()
				return refreshed >= 1
			end),
			"rejected refresh completed"
		)

		local kept = surviving()
		assert.equals("half-written edit", kept.edit)
		assert.equals("half-written reply", kept.reply)
		assert.equals("half-written new comment", kept.new)
	end)

	it("a successful refetch still drops drafts whose target is gone", function()
		fake.scenario.comments = {}
		fake.comments = {}
		comment.enabled = true
		seed_drafts()

		comment.refresh()
		assert.is_true(
			vim.wait(1000, function()
				return refreshed >= 1
			end),
			"successful refresh completed"
		)

		local kept = surviving()
		assert.is_nil(kept.edit)
		assert.is_nil(kept.reply)
		assert.is_nil(kept.new)
	end)
end)
