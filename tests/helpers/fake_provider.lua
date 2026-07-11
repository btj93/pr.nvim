-- Full-contract fake provider for flow specs. Synchronous by default;
-- set fake.deferred[method] = true to capture the callback and fire it
-- later with fake.fire(method). Every call is appended to fake.calls.
--
-- The fake is locked to tests/provider_contract_spec.lua: it implements every
-- name in REQUIRED_METHODS + REQUIRED_FIELDS. `scenario` is the mutable source
-- of truth; getters copy the matching field into the exposed cache field
-- (fake.comments, fake.hunks, ...) and every mutator updates `scenario` so a
-- subsequent get_* observes the change. clear_* reset only the cache fields
-- (not scenario), mirroring the real "invalidate-then-refetch" semantics.
local M = {}

local function find_thread(scenario, thread_id)
	for _, threads in pairs(scenario.comments or {}) do
		for _, t in ipairs(threads) do
			if t.id == thread_id then
				return t
			end
		end
	end
end

local function find_comment(scenario, comment_id)
	for _, threads in pairs(scenario.comments or {}) do
		for _, t in ipairs(threads) do
			for i, c in ipairs(t.comments) do
				if c.database_id == comment_id then
					return t, c, i
				end
			end
		end
	end
end

function M.new(scenario)
	scenario = vim.tbl_deep_extend("keep", scenario or {}, {
		git_root = vim.fn.tempname(),
		git_user = "tester",
		pr_number = 42,
		base_sha = ("a"):rep(40),
		commit_hash = ("b"):rep(40),
		comments = {},
		hunks = {},
		checks = {},
		prs = {},
		pending = { review_id = 99, comments = {} },
		collaborators = {},
		issues = {},
		reaction_palette = { { content = "THUMBS_UP", glyph = "👍" }, { content = "HEART", glyph = "❤️" } },
		repo_info = { owner = "owner", repo = "repo" },
	})

	local fake = { calls = {}, scenario = scenario, deferred = {}, _captured = {} }

	-- Monotonic id source for synthesized comments/reactions.
	local next_id = 9000

	-- Contract fields consumers read directly (cache fields). Getters repopulate
	-- these from `scenario`; clear_* reset them.
	fake.comments = scenario.comments
	fake.hunks = scenario.hunks
	fake.git_root = scenario.git_root
	fake.git_user = scenario.git_user
	fake.pr_number = scenario.pr_number
	fake.base_sha = scenario.base_sha
	fake.repo_info = scenario.repo_info
	fake.reaction_palette = scenario.reaction_palette
	fake.pr_list = {}
	fake.pr_metadata = scenario.pr_metadata
	fake.checks = scenario.checks
	fake.pending_review_id = nil
	fake.collaborators = scenario.collaborators
	fake.issues = scenario.issues

	local function record(method, ...)
		table.insert(fake.calls, { method = method, args = { ... } })
	end

	-- def(name, handler): register a method that logs, then either fires
	-- handler(...) synchronously or captures it when fake.deferred[name].
	local function def(name, handler)
		fake[name] = function(...)
			record(name, ...)
			local args = { ... }
			local run = function()
				handler(unpack(args))
			end
			if fake.deferred[name] then
				table.insert(fake._captured, { name = name, run = run })
			else
				run()
			end
		end
	end

	function fake.fire(name)
		for i, cap in ipairs(fake._captured) do
			if cap.name == name then
				table.remove(fake._captured, i)
				cap.run()
				return
			end
		end
		error("no captured call for " .. name)
	end

	-- ---------------------------------------------------------------------
	-- Identity / repo getters
	-- ---------------------------------------------------------------------
	def("get_repo_info", function(cb)
		fake.repo_info = scenario.repo_info
		if cb then
			cb(scenario.repo_info.owner, scenario.repo_info.repo)
		end
	end)
	def("get_pr_number", function(cb)
		fake.pr_number = scenario.pr_number
		if cb then
			cb(scenario.pr_number)
		end
	end)
	def("get_commit_hash", function(cb)
		if cb then
			cb(scenario.commit_hash)
		end
	end)
	def("get_base_sha", function(cb)
		fake.base_sha = scenario.base_sha
		if cb then
			cb(scenario.base_sha)
		end
	end)
	def("get_git_root", function(cb)
		fake.git_root = scenario.git_root
		if cb then
			cb(scenario.git_root)
		end
	end)
	-- Real callers use get_git_user(callback) (comment.lua/hunk.lua), while some
	-- specs use the two-arg get_git_user(_, callback) form. Tolerate both by
	-- treating whichever argument is a function as the callback.
	def("get_git_user", function(a, b)
		fake.git_user = scenario.git_user
		local cb = type(b) == "function" and b or a
		if type(cb) == "function" then
			cb(scenario.git_user)
		end
	end)

	-- ---------------------------------------------------------------------
	-- Comments / hunks getters
	-- ---------------------------------------------------------------------
	def("get_comments", function(cb)
		fake.comments = scenario.comments
		if cb then
			cb(scenario.comments)
		end
	end)
	def("get_hunks", function(cb)
		fake.hunks = scenario.hunks
		if cb then
			cb(scenario.hunks)
		end
	end)

	-- ---------------------------------------------------------------------
	-- Comment mutations
	-- ---------------------------------------------------------------------
	-- Real callers key reply two ways: ui.lua's reply path passes the FIRST
	-- COMMENT's database_id, while some flow specs pass the thread id. Accept
	-- both; fail loudly on no match (a silent cb(true) would hand future flow
	-- specs a false green).
	def("reply", function(id, body, cb)
		local t = find_thread(scenario, id) or (find_comment(scenario, id))
		if not t then
			error("fake reply: no thread or comment with id " .. tostring(id))
		end
		next_id = next_id + 1
		local anchor = t.comments[1] or {}
		table.insert(t.comments, {
			database_id = next_id,
			author = scenario.git_user,
			body = body,
			updated_at = "2026-07-11T00:00:00Z",
			viewer_can_update = true,
			viewer_can_delete = true,
			viewer_can_react = true,
			start_line = anchor.start_line,
			end_line = anchor.end_line,
		})
		if cb then
			cb(true)
		end
	end)
	def("comment", function(relative_path, start_line, end_line, body, cb)
		scenario.comments[relative_path] = scenario.comments[relative_path] or {}
		next_id = next_id + 1
		local thread_id = "fake-thread-" .. next_id
		next_id = next_id + 1
		table.insert(scenario.comments[relative_path], {
			id = thread_id,
			is_resolved = false,
			is_outdated = false,
			is_collapsed = false,
			viewer_can_reply = true,
			viewer_can_resolve = true,
			viewer_can_unresolve = true,
			comments = {
				{
					database_id = next_id,
					author = scenario.git_user,
					body = body,
					updated_at = "2026-07-11T00:00:00Z",
					viewer_can_update = true,
					viewer_can_delete = true,
					viewer_can_react = true,
					start_line = start_line,
					end_line = end_line,
				},
			},
		})
		if cb then
			cb(true)
		end
	end)
	def("edit_comment", function(comment_id, body, cb)
		local _, c = find_comment(scenario, comment_id)
		if c then
			c.body = body
			c.updated_at = "2026-07-11T00:00:00Z"
		end
		if cb then
			cb(true)
		end
	end)
	def("delete_comment", function(comment_id, cb)
		local t, _, i = find_comment(scenario, comment_id)
		if t and i then
			table.remove(t.comments, i)
		end
		if cb then
			cb(true)
		end
	end)
	def("resolve_thread", function(thread_id, cb)
		local t = find_thread(scenario, thread_id)
		if t then
			t.is_resolved = true
		end
		if cb then
			cb(true)
		end
	end)
	def("unresolve_thread", function(thread_id, cb)
		local t = find_thread(scenario, thread_id)
		if t then
			t.is_resolved = false
		end
		if cb then
			cb(true)
		end
	end)
	def("refetch_comment", function(comment_id, cb)
		local _, c = find_comment(scenario, comment_id)
		if not cb then
			return
		end
		if c then
			cb({ database_id = c.database_id, body = c.body, updated_at = c.updated_at })
		else
			cb(nil)
		end
	end)

	-- ---------------------------------------------------------------------
	-- Reactions
	-- ---------------------------------------------------------------------
	def("add_reaction", function(comment_id, reaction_key, cb)
		local _, c = find_comment(scenario, comment_id)
		if c then
			c.reaction_groups = c.reaction_groups or {}
			local group
			for _, g in ipairs(c.reaction_groups) do
				if g.content == reaction_key then
					group = g
				end
			end
			if not group then
				group = { content = reaction_key, viewerHasReacted = false, reactors = { totalCount = 0, nodes = {} } }
				table.insert(c.reaction_groups, group)
			end
			group.viewerHasReacted = true
			next_id = next_id + 1
			table.insert(group.reactors.nodes, { database_id = next_id, content = reaction_key, user = scenario.git_user })
			group.reactors.totalCount = #group.reactors.nodes
		end
		if cb then
			cb(true)
		end
	end)
	def("remove_reaction", function(comment_id, reaction_id, cb)
		local _, c = find_comment(scenario, comment_id)
		if c and c.reaction_groups then
			for gi = #c.reaction_groups, 1, -1 do
				local group = c.reaction_groups[gi]
				local nodes = group.reactors and group.reactors.nodes or {}
				for ni = #nodes, 1, -1 do
					if nodes[ni].database_id == reaction_id then
						table.remove(nodes, ni)
					end
				end
				group.reactors.totalCount = #nodes
				if #nodes == 0 then
					group.viewerHasReacted = false
					table.remove(c.reaction_groups, gi)
				end
			end
		end
		if cb then
			cb(true)
		end
	end)

	-- ---------------------------------------------------------------------
	-- PR explorer + checkout (S1a)
	-- ---------------------------------------------------------------------
	def("list_prs", function(filter, cb)
		local prs = scenario.prs[filter] or {}
		fake.pr_list[filter] = prs
		if cb then
			cb(prs)
		end
	end)
	def("checkout_pr", function(_pr_number, cb)
		if cb then
			cb(true)
		end
	end)

	-- ---------------------------------------------------------------------
	-- PR info popup (S1b)
	-- ---------------------------------------------------------------------
	def("get_pr_metadata", function(cb)
		fake.pr_metadata = scenario.pr_metadata
		if cb then
			cb(scenario.pr_metadata)
		end
	end)
	def("update_pr_metadata", function(fields, cb)
		scenario.pr_metadata = vim.tbl_extend("force", scenario.pr_metadata or {}, fields or {})
		scenario.pr_metadata.updated_at = "2026-07-11T00:00:00Z"
		fake.pr_metadata = scenario.pr_metadata
		if cb then
			cb(true)
		end
	end)
	def("get_checks", function(cb)
		fake.checks = scenario.checks
		if cb then
			cb(scenario.checks)
		end
	end)

	-- ---------------------------------------------------------------------
	-- Submit review (S1c)
	-- ---------------------------------------------------------------------
	def("start_pending_review", function(cb)
		fake.pending_review_id = scenario.pending.review_id
		if cb then
			cb(scenario.pending.review_id)
		end
	end)
	def("add_review_comment", function(_review_id, path, start_line, end_line, body, cb)
		next_id = next_id + 1
		table.insert(scenario.pending.comments, {
			id = next_id,
			path = path,
			start_line = start_line,
			end_line = end_line,
			body = body,
		})
		if cb then
			cb(true)
		end
	end)
	def("list_review_comments", function(_review_id, cb)
		if cb then
			cb(scenario.pending.comments)
		end
	end)
	def("submit_review", function(_review_id, _event, _body, cb)
		scenario.pending.comments = {}
		fake.pending_review_id = nil
		if cb then
			cb(true)
		end
	end)
	def("discard_pending_review", function(_review_id, cb)
		scenario.pending.comments = {}
		fake.pending_review_id = nil
		if cb then
			cb(true)
		end
	end)

	-- ---------------------------------------------------------------------
	-- Completion (S3b)
	-- ---------------------------------------------------------------------
	def("list_collaborators", function(cb)
		fake.collaborators = scenario.collaborators
		if cb then
			cb(scenario.collaborators)
		end
	end)
	def("list_issues", function(cb)
		fake.issues = scenario.issues
		if cb then
			cb(scenario.issues)
		end
	end)

	-- ---------------------------------------------------------------------
	-- Cache invalidation. These reset only the exposed cache fields; the
	-- scenario source of truth is untouched so a follow-up get_* repopulates.
	-- ---------------------------------------------------------------------
	def("clear", function()
		fake.comments = {}
		fake.hunks = {}
		fake.repo_info = {}
		fake.pr_number = 0
		fake.git_root = ""
		fake.git_user = ""
		fake.base_sha = ""
		fake.pr_list = {}
		fake.pr_metadata = nil
		fake.checks = nil
		fake.pending_review_id = nil
		fake.collaborators = nil
		fake.issues = nil
	end)
	def("clear_comments", function()
		fake.comments = {}
	end)
	def("clear_hunks", function()
		fake.hunks = {}
	end)
	def("clear_pr_number", function()
		fake.pr_number = 0
	end)
	def("clear_pr_list", function()
		fake.pr_list = {}
	end)
	def("clear_pr_metadata", function()
		fake.pr_metadata = nil
	end)
	def("clear_checks", function()
		fake.checks = nil
	end)
	def("clear_pending_review", function()
		fake.pending_review_id = nil
	end)
	def("clear_collaborators", function()
		fake.collaborators = nil
	end)
	def("clear_issues", function()
		fake.issues = nil
	end)

	-- Synchronous URL formatter. Logged like every other method, but returns a
	-- value directly rather than firing a callback (never deferred).
	fake.thread_url = function(thread, comment)
		record("thread_url", thread, comment)
		return "https://fake.example/" .. tostring(thread.id)
	end

	return fake
end

--- Returns the first logged call for `method`, or nil. Pre-declared by the
--- plan's Task 5; provided here so the helper interface is complete.
---@param fake table
---@param method string
---@return { method: string, args: table }|nil
function M.called(fake, method)
	for _, call in ipairs(fake.calls) do
		if call.method == method then
			return call
		end
	end
	return nil
end

--- Install the fake as the active provider under `pr.providers.<name>`, flip
--- config.opts.provider to it, and return an uninstaller restoring both.
---@param name string
---@param scenario table?
---@return table fake, fun() uninstall
function M.install(name, scenario)
	local config = require("pr.config")
	local fake = M.new(scenario)
	local prev_provider = config.opts.provider
	local prev_module = package.loaded["pr.providers." .. name]
	package.loaded["pr.providers." .. name] = fake
	config.opts.provider = name
	return fake, function()
		package.loaded["pr.providers." .. name] = prev_module
		config.opts.provider = prev_provider
	end
end

return M
