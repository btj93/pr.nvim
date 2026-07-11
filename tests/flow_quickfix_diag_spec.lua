-- Tier 2 flow spec: the quickfix `dump` wiring and the diagnostics
-- publish/clear surface. The pure `quickfix._build_entries` filtering is already
-- covered in tests/quickfix_spec.lua; this spec exercises the async path around
-- it — get_comments over the fake provider, the `file` kind's current-buffer
-- path derivation, and setqflist — plus diagnostics.publish's buftype guard and
-- clear_all's namespace reset across buffers.
--
-- Fixture: one real file (foo.lua) with threads at lines 2 (unresolved),
-- 5 (resolved), 9 (outdated); plus data-only threads on a second path
-- (other.lua) to prove the `file` kind restricts to the current buffer.
local ui_env = require("helpers.ui_env")
local fake_provider = require("helpers.fake_provider")
local git_repo = require("helpers.git_repo")

--- One thread carrying a single comment.
local function mk(id, line, author, body, opts)
	opts = opts or {}
	return {
		id = id,
		is_resolved = opts.is_resolved or false,
		is_outdated = opts.is_outdated or false,
		viewer_can_reply = true,
		comments = {
			{
				database_id = opts.database_id or 0,
				author = author,
				body = body,
				start_line = line,
				end_line = line,
			},
		},
	}
end

describe("flow: quickfix dump", function()
	local env, uninstall, repo, rel

	before_each(function()
		env = ui_env.setup()
		repo = git_repo.create({
			files = { ["foo.lua"] = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" } },
		})
		vim.cmd("edit " .. vim.fn.fnameescape(repo.root .. "/foo.lua"))
		local bufname = vim.api.nvim_buf_get_name(0)
		local git_root = vim.fn.fnamemodify(bufname, ":h")
		rel = vim.fn.fnamemodify(bufname, ":t")

		uninstall = select(
			2,
			fake_provider.install("flow_qf_fake", {
				git_root = git_root,
				comments = {
					[rel] = {
						mk("T2", 2, "alice", "alpha body two", { database_id = 2 }),
						mk("T5", 5, "bob", "beta body five", { is_resolved = true, database_id = 5 }),
						mk("T9", 9, "carol", "gamma body nine", { is_outdated = true, database_id = 9 }),
					},
					["other.lua"] = {
						mk("TB", 3, "dave", "delta body bar", { database_id = 3 }),
					},
				},
			})
		)
	end)

	after_each(function()
		env.drain(30)
		if uninstall then
			uninstall()
		end
		if env then
			env.teardown()
		end
		if repo then
			repo.cleanup()
			repo = nil
		end
	end)

	--- Run dump for `kind`, wait for its completion notification, return the qflist.
	local function run_dump(kind)
		local before = #env.notifications
		require("pr.quickfix").dump({ kind = kind })
		env.wait_for(function()
			return #env.notifications > before
		end, 2000, "dump notify for " .. kind)
		return vim.fn.getqflist()
	end

	it("quickfix.dump('unresolved'|'outdated'|'all'|'file') sets qflist entries matching the fixture", function()
		-- unresolved drops the resolved T5; keeps T2, T9 (foo) + TB (other) = 3.
		assert.equals(3, #run_dump("unresolved"))

		-- outdated keeps only T9.
		local outdated = run_dump("outdated")
		assert.equals(1, #outdated)
		assert.equals(9, outdated[1].lnum)
		assert.matches("carol", outdated[1].text)
		assert.matches("gamma body nine", outdated[1].text)

		-- all keeps every thread across both files = 4.
		assert.equals(4, #run_dump("all"))

		-- file restricts to the current buffer (foo.lua) AND drops resolved:
		-- T2, T9 = 2.
		assert.equals(2, #run_dump("file"))
	end)

	it("dump('file') restricts to the current buffer's path", function()
		local entries = run_dump("file")
		assert.equals(2, #entries)

		local joined = {}
		for _, e in ipairs(entries) do
			joined[#joined + 1] = e.text
		end
		joined = table.concat(joined, "\n")

		-- foo.lua's unresolved threads are present...
		assert.matches("alpha body two", joined)
		assert.matches("gamma body nine", joined)
		-- ...but the other-file thread and the resolved thread are not.
		assert.is_nil(joined:find("delta body bar", 1, true))
		assert.is_nil(joined:find("beta body five", 1, true))
	end)
end)

describe("flow: diagnostics publish/clear", function()
	local diag = require("pr.diagnostics")
	local made_bufs

	before_each(function()
		made_bufs = {}
	end)

	after_each(function()
		for _, b in ipairs(made_bufs) do
			if vim.api.nvim_buf_is_valid(b) then
				pcall(vim.diagnostic.reset, diag.namespace, b)
				pcall(vim.api.nvim_buf_delete, b, { force = true })
			end
		end
		made_bufs = {}
	end)

	--- Create a buffer (scratch => buftype "nofile"), track it for cleanup, and
	--- pad it with lines so anchored diagnostics fall inside it.
	local function new_buf(scratch)
		local b = vim.api.nvim_create_buf(true, scratch or false)
		vim.api.nvim_buf_set_lines(b, 0, -1, false, { "a", "b", "c", "d" })
		table.insert(made_bufs, b)
		return b
	end

	local function threads()
		return {
			{
				is_resolved = false,
				is_outdated = false,
				comments = { { author = "alice", body = "risky change", start_line = 2, end_line = 2 } },
			},
		}
	end

	local function count(buf)
		return #vim.diagnostic.get(buf, { namespace = diag.namespace })
	end

	it("diagnostics.publish skips buffers with buftype ~= ''", function()
		-- Control: a normal buffer (buftype "") receives the diagnostic.
		local normal = new_buf(false)
		assert.equals("", vim.bo[normal].buftype)
		diag.publish(normal, threads(), nil)
		assert.equals(1, count(normal))

		-- A scratch buffer (buftype "nofile") is skipped entirely.
		local scratch = new_buf(true)
		assert.equals("nofile", vim.bo[scratch].buftype)
		diag.publish(scratch, threads(), nil)
		assert.equals(0, count(scratch))
	end)

	it("diagnostics.clear_all empties the pr_threads namespace on all buffers", function()
		local b1 = new_buf(false)
		local b2 = new_buf(false)
		diag.publish(b1, threads(), nil)
		diag.publish(b2, threads(), nil)
		assert.equals(1, count(b1))
		assert.equals(1, count(b2))

		diag.clear_all()

		assert.equals(0, count(b1))
		assert.equals(0, count(b2))
	end)
end)
