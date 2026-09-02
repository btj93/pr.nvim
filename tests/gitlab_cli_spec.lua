-- Exercises the real gitlab provider (pr.providers.gitlab) end-to-end against
-- the cli_shim fake `glab` + a real temp git repo. The provider's async getter
-- chains (plenary.job) are driven by predicate waits over vim.wait; git is
-- never shimmed, so `git remote get-url origin` parses group/proj from the
-- fabricated remote (git@gitlab.com:group/proj.git).
local cli_shim = require("helpers.cli_shim")
local git_repo = require("helpers.git_repo")

-- Resolve the fixture dir from this file's own path so it survives the cwd
-- changing into the temp repo mid-test. `:p` is resolved at module-load time
-- (cwd is still the project root here), so FIXTURES is absolute.
local this_file = debug.getinfo(1, "S").source:sub(2)
local FIXTURES = vim.fn.fnamemodify(this_file, ":p:h") .. "/fixtures/gitlab"

describe("gitlab provider through real CLI plumbing", function()
	local shim, repo, glab, saved_cwd, saved_notify, notifications, saved_debug

	-- Shared route: `glab mr view --json iid` resolves the MR number (iid) for
	-- every chain that needs it (get_pr_number decodes the JSON `.iid`).
	local MR_VIEW_IID = { match = { "mr", "view", "--json", "iid" }, stdout = '{"iid":7}\n' }
	-- get_comments front-loads get_git_user (`glab api /user --jq .username`).
	local API_USER = { match = { "api", "/user" }, stdout = "testuser\n" }
	-- The discussions GraphQL response. gitlab.get_comments joins ALL stdout
	-- lines with "\n" before vim.json.decode (unlike github, which decodes only
	-- the first line), so a multi-line fixture would also parse; we keep it
	-- single-line for parity with the github fixtures.
	local API_GRAPHQL = { match = { "api", "graphql" }, stdout_file = FIXTURES .. "/discussions.json" }

	before_each(function()
		saved_cwd = vim.fn.getcwd()
		saved_debug = require("pr.config").opts.debug
		require("pr.config").opts.debug = false
		notifications = {}
		saved_notify = vim.notify
		vim.notify = function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end
		package.loaded["pr.providers.gitlab"] = nil
		glab = require("pr.providers.gitlab")
		repo = git_repo.create({
			origin = "git@gitlab.com:group/proj.git",
			files = { ["src/foo.lua"] = { "line 1", "line 2", "line 3" } },
		})
		vim.cmd.cd(repo.root)
		shim = cli_shim.new()
		shim.install()
	end)

	after_each(function()
		pcall(vim.cmd.cd, saved_cwd)
		require("pr.config").opts.debug = saved_debug
		vim.notify = saved_notify
		pcall(function()
			shim.uninstall()
		end)
		pcall(function()
			repo.cleanup()
		end)
		package.loaded["pr.providers.gitlab"] = nil
	end)

	local function wait_for(pred, label)
		assert(vim.wait(4000, pred, 10), "timeout: " .. label)
	end

	-- Every argv logged for `name` that contains `needle` as an exact token.
	local function calls_with(name, needle)
		local out = {}
		for _, argv in ipairs(shim.calls(name)) do
			if vim.tbl_contains(argv, needle) then
				table.insert(out, argv)
			end
		end
		return out
	end

	-- Assert that `value` appears in argv immediately preceded by `flag`
	-- (i.e. `-f fullPath=group/proj` is logged as two adjacent argv entries).
	local function assert_flag_pair(argv, flag, value)
		for i, v in ipairs(argv) do
			if v == value then
				assert.equals(flag, argv[i - 1], value .. " should be preceded by " .. flag)
				return
			end
		end
		assert(false, "value not found in argv: " .. value)
	end

	-- Join argv with the field separator so endpoint substrings can be probed
	-- with plain `find`; no argv token carries a \31 byte.
	local function join(argv)
		return table.concat(argv, "\31")
	end

	-- Every notification message emitted so far, one per capture.
	local function notify_msgs()
		local out = {}
		for _, n in ipairs(notifications) do
			out[#out + 1] = n.msg
		end
		return out
	end

	it("get_pr_number resolves via glab mr view --json iid and caches", function()
		shim.stub("glab", { MR_VIEW_IID })

		local n1
		glab.get_pr_number(function(n)
			n1 = n
		end)
		wait_for(function()
			return n1 ~= nil
		end, "first get_pr_number")

		local n2
		glab.get_pr_number(function(n)
			n2 = n
		end)
		wait_for(function()
			return n2 ~= nil
		end, "second get_pr_number")

		assert.equals(7, n1)
		assert.equals(7, n2)
		-- fetch-once: the second call short-circuits on the cached iid, so only a
		-- single `glab` invocation ever happened.
		assert.equals(1, #shim.calls("glab"))
	end)

	it("get_comments runs the full chain, normalizes, and captures diff_refs", function()
		shim.stub("glab", { MR_VIEW_IID, API_USER, API_GRAPHQL })

		local comments
		glab.get_comments(function(c)
			comments = c
		end)
		wait_for(function()
			return comments ~= nil
		end, "get_comments")

		-- Comments keyed by relative path with two normalized threads.
		assert.is_not_nil(comments["src/foo.lua"])
		local threads = comments["src/foo.lua"]
		assert.equals(2, #threads)

		-- Discussion ids come from _parse_discussion_id (hex hash), notes carry
		-- the numeric database_id parsed from the Note gid.
		assert.equals("abc123", threads[1].id)
		assert.equals("alice", threads[1].comments[1].author)
		assert.equals(100, threads[1].comments[1].database_id)
		assert.equals(5, threads[1].comments[1].start_line)
		assert.equals(5, threads[1].comments[1].end_line)

		assert.equals("def456", threads[2].id)
		assert.equals("bob", threads[2].comments[1].author)
		assert.equals(200, threads[2].comments[1].database_id)
		assert.equals(12, threads[2].comments[1].start_line)

		-- diff_refs captured as a get_comments side-effect (same GraphQL query).
		assert.same({ base_sha = "basefix111", head_sha = "head222", start_sha = "start333" }, glab.diff_refs)

		-- The graphql argv carries -f fullPath/iid pairs: fullPath is the project
		-- path parsed from the fabricated remote (group/proj), iid from MR 7.
		local gql = calls_with("glab", "graphql")
		assert.equals(1, #gql)
		local argv = gql[1]
		assert_flag_pair(argv, "-f", "fullPath=group/proj")
		assert_flag_pair(argv, "-f", "iid=7")
	end)

	it("get_base_sha fetches via glab api --jq when cold", function()
		shim.stub("glab", {
			MR_VIEW_IID,
			{ match = { "api", ".diff_refs.base_sha" }, stdout = "coldbase999\n" },
		})

		local got
		glab.get_base_sha(function(s)
			got = s
		end)
		wait_for(function()
			return got ~= nil and got ~= ""
		end, "get_base_sha cold")

		assert.equals("coldbase999", got)

		-- The REST route addresses the url-encoded project + MR and extracts
		-- .diff_refs.base_sha with --jq.
		local api = calls_with("glab", ".diff_refs.base_sha")
		assert.equals(1, #api)
		local argv = api[1]
		assert.truthy(join(argv):find("/projects/group%2Fproj/merge_requests/7", 1, true))
		assert_flag_pair(argv, "--jq", ".diff_refs.base_sha")
	end)

	it("get_base_sha short-circuits from diff_refs after get_comments (no new glab call)", function()
		shim.stub("glab", { MR_VIEW_IID, API_USER, API_GRAPHQL })

		local comments
		glab.get_comments(function(c)
			comments = c
		end)
		wait_for(function()
			return comments ~= nil
		end, "warm get_comments")
		-- get_git_user + get_pr_number + get_comments graphql = 3 glab calls.
		local warm_count = #shim.calls("glab")
		assert.equals(3, warm_count)

		local got
		glab.get_base_sha(function(s)
			got = s
		end)
		wait_for(function()
			return got ~= nil and got ~= ""
		end, "get_base_sha warm")

		-- The base sha is served straight off the cached diff_refs; no REST call.
		assert.equals("basefix111", got)
		assert.equals(warm_count, #shim.calls("glab"))
	end)

	it("reply resolves the discussion id from the warm cache and POSTs to it", function()
		shim.stub("glab", {
			MR_VIEW_IID,
			API_USER,
			API_GRAPHQL,
			{ match = { "api", "--method", "POST" }, stdout = "{}" },
		})

		-- Warm the comments cache so reply can map note 100 -> discussion abc123.
		local comments
		glab.get_comments(function(c)
			comments = c
		end)
		wait_for(function()
			return comments ~= nil
		end, "warm get_comments")

		local done = false
		glab.reply(100, "hello", function()
			done = true
		end)
		wait_for(function()
			return done
		end, "reply cb")

		local posts = calls_with("glab", "POST")
		assert.equals(1, #posts)
		local argv = posts[1]
		local joined = join(argv)
		-- The DID (abc123) from the fixture anchors the reply endpoint.
		assert.truthy(joined:find("/discussions/abc123/notes", 1, true))
		assert.truthy(joined:find("/projects/group%2Fproj/merge_requests/7", 1, true))
		assert_flag_pair(argv, "-f", "body=hello")
	end)

	it("failed reply diagnostics do not expose the review body or raw argv", function()
		local private_body = "GITLAB PRIVATE REVIEW BODY"

		local function run_failed_reply()
			glab.repo_info = { owner = "group", repo = "proj", project_path = "group/proj" }
			glab.pr_number = 7
			glab.comments = {
				["src/foo.lua"] = {
					{ id = "abc123", comments = { { database_id = 100 } } },
				},
			}
			shim.stub("glab", {
				{ match = { "api", "--method", "POST" }, exit = 1, stderr = "request rejected: " .. private_body },
			})
			local done
			glab.reply(100, private_body, function(ok)
				done = ok
			end)
			wait_for(function()
				return done ~= nil
			end, "failed reply cb")
			assert.is_false(done)
			return table.concat(notify_msgs(), "\n")
		end

		local normal = run_failed_reply()
		assert.truthy(normal:find("Is a glab cli installed?", 1, true))
		assert.is_nil(normal:find(private_body, 1, true))
		assert.is_nil(normal:find("body=", 1, true))

		notifications = {}
		require("pr.config").opts.debug = true
		local debugged = run_failed_reply()
		assert.truthy(debugged:find("Is a glab cli installed?", 1, true))
		assert.truthy(debugged:find("body=<redacted>", 1, true))
		assert.is_nil(debugged:find(private_body, 1, true))
	end)

	it("a failed discussion fetch exposes neither the GraphQL document nor the response body", function()
		require("pr.config").opts.debug = true
		-- Seed the front-loaded context (git_user / repo_info / iid) so the chain
		-- goes straight to the graphql job; the argv it assembles carries the
		-- whole DISCUSSIONS_QUERY under `-f query=...`.
		glab.git_user = "testuser"
		glab.repo_info = { owner = "group", repo = "proj", project_path = "group/proj" }
		glab.pr_number = 7
		shim.stub("glab", {
			{
				match = { "api", "graphql" },
				exit = 1,
				stdout = '{"data":{"project":{"mergeRequest":{"discussions":{"nodes":[{"notes":{"nodes":[{"body":"LEAKED NOTE BODY"}]}}]}}}}}',
				stderr = "GraphQL: 429 Too Many Requests",
			},
		})

		-- The redaction contract is what this pins, so wait on the notification
		-- rather than the (now settled) callback.
		glab.get_comments(function() end)
		wait_for(function()
			for _, m in ipairs(notify_msgs()) do
				if tostring(m):find("Is a glab cli installed?", 1, true) then
					return true
				end
			end
			return false
		end, "discussion fetch failure notification")

		local out = table.concat(notify_msgs(), "\n")
		assert.truthy(out:find("query=<redacted>", 1, true))
		assert.is_nil(out:find("LEAKED NOTE BODY", 1, true))
		-- A distinctive token of the GraphQL document; the operation name
		-- ("GitLab discussion fetch") deliberately shares no substring with it.
		assert.is_nil(out:find("mergeRequest", 1, true))
	end)

	it("run_glab surfaces the install hint on a non-zero exit", function()
		-- ensure_context resolves the project (real git) + iid (mr view), then
		-- resolve_thread's PUT exits 1: run_glab reports the install hint.
		shim.stub("glab", {
			MR_VIEW_IID,
			{ match = { "api", "--method", "PUT" }, exit = 1 },
		})

		local done = false
		glab.resolve_thread("abc123", function()
			done = true
		end)
		wait_for(function()
			return done
		end, "resolve_thread cb")

		-- run_glab's failure branch routes through pr.log, which emits one
		-- sanitized notification carrying the stable "Is a glab cli installed?"
		-- hint -- never the raw args or the command's result.
		local found = false
		for _, m in ipairs(notify_msgs()) do
			if tostring(m):find("Is a glab cli installed?", 1, true) then
				found = true
			end
		end
		assert.is_true(found, "expected the glab install hint in a notification")
	end)

	it("resolve_thread PUTs resolved=true to the discussion endpoint on success", function()
		-- ensure_context resolves the project (real git) + iid (mr view), then the
		-- PUT exits 0 so the callback receives success = true.
		shim.stub("glab", {
			MR_VIEW_IID,
			{ match = { "api", "--method", "PUT" }, stdout = "{}" },
		})

		local ok
		glab.resolve_thread("abc123", function(success)
			ok = success
		end)
		wait_for(function()
			return ok ~= nil
		end, "resolve_thread cb")

		assert.is_true(ok)
		local puts = calls_with("glab", "PUT")
		assert.equals(1, #puts)
		local argv = puts[1]
		local joined = join(argv)
		-- The discussion id anchors the endpoint under the url-encoded project + MR.
		assert.truthy(joined:find("/projects/group%2Fproj/merge_requests/7/discussions/abc123", 1, true))
		assert_flag_pair(argv, "-F", "resolved=true")
	end)

	it("clear_comments forces the next get_comments to re-run the graphql query", function()
		shim.stub("glab", { MR_VIEW_IID, API_USER, API_GRAPHQL })

		local c1
		glab.get_comments(function(c)
			c1 = c
		end)
		wait_for(function()
			return c1 ~= nil
		end, "first get_comments")
		assert.equals(1, #calls_with("glab", "graphql"))

		glab.clear_comments()

		local c2
		glab.get_comments(function(c)
			c2 = c
		end)
		wait_for(function()
			return c2 ~= nil
		end, "second get_comments after clear")
		-- git_user + iid stay cached, so only the graphql query re-fires: 1 -> 2.
		assert.equals(2, #calls_with("glab", "graphql"))
	end)

	-- Lifecycle: gitlab's read getters short-circuited on `next(M.comments)` /
	-- `next(M.hunks)`, so an MR with no discussions and an MR with an empty diff
	-- both refetched on every call, concurrent callers each started their own
	-- subprocess chain, and a failed fetch never settled its caller at all.
	local EMPTY_GRAPHQL = {
		match = { "api", "graphql" },
		stdout = '{"data":{"project":{"mergeRequest":{"discussions":{"nodes":[]}}}}}',
	}

	it("caches an empty comments result instead of refetching", function()
		shim.stub("glab", { MR_VIEW_IID, API_USER, EMPTY_GRAPHQL })

		local first, second
		glab.get_comments(function(c)
			first = c
		end)
		wait_for(function()
			return first ~= nil
		end, "first get_comments")
		glab.get_comments(function(c)
			second = c
		end)
		wait_for(function()
			return second ~= nil
		end, "second get_comments")

		assert.same({}, first)
		assert.same({}, second)
		-- Cached: an empty result that refetched would issue a second graphql call.
		assert.equals(1, #calls_with("glab", "graphql"))

		-- ...and invalidation makes the NEXT call fetch again.
		glab.clear_comments()
		local third
		glab.get_comments(function(c)
			third = c
		end)
		wait_for(function()
			return third ~= nil
		end, "get_comments after clear_comments")
		assert.same({}, third)
		assert.equals(2, #calls_with("glab", "graphql"))
	end)

	it("caches an empty hunks result and refetches after invalidation", function()
		-- An exit-0 `glab mr diff` with no output is an MR whose diff is empty,
		-- not a failure.
		shim.stub("glab", { MR_VIEW_IID, { match = { "mr", "diff" }, stdout = "" } })

		local first, second
		glab.get_hunks(function(h)
			first = h
		end)
		wait_for(function()
			return first ~= nil
		end, "first get_hunks")
		glab.get_hunks(function(h)
			second = h
		end)
		wait_for(function()
			return second ~= nil
		end, "second get_hunks")

		assert.same({}, first)
		assert.same({}, second)
		assert.equals(1, #calls_with("glab", "diff"))

		glab.clear_hunks()
		local third
		glab.get_hunks(function(h)
			third = h
		end)
		wait_for(function()
			return third ~= nil
		end, "get_hunks after clear_hunks")
		assert.same({}, third)
		assert.equals(2, #calls_with("glab", "diff"))
	end)

	it("coalesces two callers arriving before the fetch completes", function()
		shim.stub("glab", { MR_VIEW_IID, API_USER, API_GRAPHQL })

		local a, b
		glab.get_comments(function(c)
			a = c
		end)
		glab.get_comments(function(c)
			b = c
		end)
		wait_for(function()
			return a ~= nil and b ~= nil
		end, "both callers settled")

		assert.is_not_nil(a["src/foo.lua"])
		assert.is_not_nil(b["src/foo.lua"])
		-- One chain, not two: the second caller joined the first fetch.
		assert.equals(1, #calls_with("glab", "graphql"))
	end)

	it("settles the caller with an error instead of hanging when the fetch fails", function()
		shim.stub("glab", {
			MR_VIEW_IID,
			API_USER,
			{ match = { "api", "graphql" }, exit = 1, stderr = "GraphQL: 429 Too Many Requests" },
		})

		local value, err, called = nil, nil, false
		glab.get_comments(function(v, e)
			value, err, called = v, e, true
		end)
		wait_for(function()
			return called
		end, "failed get_comments settles its caller")

		assert.same({}, value)
		assert.is_not_nil(err)
		-- The failure must NOT be cached as a successful empty result.
		assert.same({}, glab.comments)
		assert.equals("error", glab._fetch:status("comments"))
	end)

	it("clear() returns the fetch coordinator to cold so the next get_comments refetches", function()
		shim.stub("glab", { MR_VIEW_IID, API_USER, EMPTY_GRAPHQL })

		local first
		glab.get_comments(function(c)
			first = c
		end)
		wait_for(function()
			return first ~= nil
		end, "first get_comments")

		-- clear() resets the cache fields inline rather than delegating to
		-- clear_comments/clear_hunks, so it has to invalidate the coordinator
		-- itself or the emptied cache stays "loaded" forever.
		glab.clear()

		local second
		glab.get_comments(function(c)
			second = c
		end)
		wait_for(function()
			return second ~= nil
		end, "get_comments after clear()")
		assert.equals(2, #calls_with("glab", "graphql"))
	end)

	-- Each reject and owns site gets its own pin. `glab mr view` exiting
	-- non-zero and a missing origin remote are the two ways the prelude getters
	-- fail; before they settled their own callbacks the resource stayed
	-- "loading" forever and every later caller joined a waiter list nothing
	-- would drain.
	local MR_DIFF = { match = { "mr", "diff" }, stdout = [[
diff --git a/src/foo.lua b/src/foo.lua
@@ -1,2 +1,3 @@
 line 1
+added
 line 2
]] }

	it("get_comments settles and stays retryable when glab mr view fails", function()
		shim.stub("glab", { API_USER, { match = { "mr", "view" }, exit = 1 } })

		local value, err, called
		glab.get_comments(function(v, e)
			value, err, called = v, e, true
		end)
		wait_for(function()
			return called
		end, "get_comments settles on a failed glab mr view")

		assert.same({}, value)
		assert.is_not_nil(err)
		assert.equals("error", glab._fetch:status("comments"))
		assert.equals(0, #calls_with("glab", "graphql"))

		-- Retryable, not wedged: once the MR resolves, the next caller fetches.
		shim.stub("glab", { MR_VIEW_IID, API_USER, EMPTY_GRAPHQL })
		local second
		glab.get_comments(function(c)
			second = c
		end)
		wait_for(function()
			return second ~= nil
		end, "get_comments after the failure")
		assert.same({}, second)
		assert.equals(1, #calls_with("glab", "graphql"))
	end)

	it("get_comments settles when the origin remote is gone", function()
		repo.git("remote", "remove", "origin")
		shim.stub("glab", { MR_VIEW_IID, API_USER, EMPTY_GRAPHQL })

		local value, err, called
		glab.get_comments(function(v, e)
			value, err, called = v, e, true
		end)
		wait_for(function()
			return called
		end, "get_comments settles without repo info")

		assert.same({}, value)
		assert.is_not_nil(err)
		assert.equals(0, #calls_with("glab", "graphql"))
	end)

	it("get_comments settles on an undecodable graphql response", function()
		shim.stub("glab", {
			MR_VIEW_IID,
			API_USER,
			{ match = { "api", "graphql" }, stdout = "<html>502 Bad Gateway</html>\n" },
		})

		local value, err, called
		glab.get_comments(function(v, e)
			value, err, called = v, e, true
		end)
		wait_for(function()
			return called
		end, "get_comments settles on an undecodable response")

		assert.same({}, value)
		assert.is_not_nil(err)
		assert.equals("error", glab._fetch:status("comments"))
	end)

	it("get_comments settles on an unexpected graphql structure", function()
		shim.stub("glab", {
			MR_VIEW_IID,
			API_USER,
			{ match = { "api", "graphql" }, stdout = '{"data":{}}' },
		})

		local value, err, called
		glab.get_comments(function(v, e)
			value, err, called = v, e, true
		end)
		wait_for(function()
			return called
		end, "get_comments settles on an unexpected structure")

		assert.same({}, value)
		assert.is_not_nil(err)
		assert.equals("error", glab._fetch:status("comments"))
	end)

	it("get_hunks settles with an error when glab mr diff fails", function()
		shim.stub("glab", { MR_VIEW_IID, { match = { "mr", "diff" }, exit = 1 } })

		local value, err, called
		glab.get_hunks(function(v, e)
			value, err, called = v, e, true
		end)
		wait_for(function()
			return called
		end, "failed get_hunks settles its caller")

		assert.same({}, value)
		assert.is_not_nil(err)
		assert.same({}, glab.hunks)
		assert.equals("error", glab._fetch:status("hunks"))

		-- A failure is not cached as success: the next caller runs `glab mr diff`
		-- again instead of replaying an empty result.
		shim.stub("glab", { MR_VIEW_IID, MR_DIFF })
		local second
		glab.get_hunks(function(h)
			second = h
		end)
		wait_for(function()
			return second ~= nil and next(second) ~= nil
		end, "get_hunks after the failure")
		assert.equals(2, #calls_with("glab", "diff"))
	end)

	it("get_hunks settles when glab mr view fails", function()
		shim.stub("glab", { { match = { "mr", "view" }, exit = 1 }, MR_DIFF })

		local value, err, called
		glab.get_hunks(function(v, e)
			value, err, called = v, e, true
		end)
		wait_for(function()
			return called
		end, "get_hunks settles on a failed glab mr view")

		assert.same({}, value)
		assert.is_not_nil(err)
		assert.equals(0, #calls_with("glab", "diff"))
	end)

	it("get_hunks settles when the origin remote is gone", function()
		repo.git("remote", "remove", "origin")
		shim.stub("glab", { MR_VIEW_IID, MR_DIFF })

		local value, err, called
		glab.get_hunks(function(v, e)
			value, err, called = v, e, true
		end)
		wait_for(function()
			return called
		end, "get_hunks settles without repo info")

		assert.same({}, value)
		assert.is_not_nil(err)
		assert.equals(0, #calls_with("glab", "diff"))
	end)

	it("a comments fetch invalidated mid-flight never publishes into the cache", function()
		shim.stub("glab", { MR_VIEW_IID, API_USER, API_GRAPHQL })

		local err, called
		glab.get_comments(function(_, e)
			err, called = e, true
		end)
		-- The chain is still on its first subprocess here, so this retires the
		-- token the in-flight completion is holding.
		glab.clear_comments()
		assert.is_true(called, "invalidate settles the waiting caller")
		assert.is_not_nil(err)

		wait_for(function()
			return #calls_with("glab", "graphql") == 1
		end, "the retired fetch still ran to completion")
		vim.wait(500, function()
			return false
		end)

		-- The completion lost its token, so the fixture's threads (and the
		-- diff_refs it carries) must not have landed in a just-emptied cache.
		assert.same({}, glab.comments)
		assert.is_nil(glab.diff_refs)
		assert.equals("cold", glab._fetch:status("comments"))
	end)

	it("a hunks fetch invalidated mid-flight never publishes into the cache", function()
		shim.stub("glab", { MR_VIEW_IID, MR_DIFF })

		local err, called
		glab.get_hunks(function(_, e)
			err, called = e, true
		end)
		glab.clear_hunks()
		assert.is_true(called, "invalidate settles the waiting caller")
		assert.is_not_nil(err)

		wait_for(function()
			return #calls_with("glab", "diff") == 1
		end, "the retired fetch still ran to completion")
		vim.wait(500, function()
			return false
		end)

		assert.same({}, glab.hunks)
		assert.equals("cold", glab._fetch:status("hunks"))
	end)

	it("get_comments settles when the glab user lookup fails", function()
		-- gitlab is the one provider whose get_comments front-loads get_git_user,
		-- so an unauthenticated `glab` wedged the whole chain before that failure
		-- branch settled its callback.
		shim.stub("glab", { MR_VIEW_IID, { match = { "api", "/user" }, exit = 1 }, EMPTY_GRAPHQL })

		local value, err, called
		glab.get_comments(function(v, e)
			value, err, called = v, e, true
		end)
		wait_for(function()
			return called
		end, "get_comments settles on a failed user lookup")

		-- A user lookup is not load-bearing for the fetch itself: it only feeds
		-- viewer_did_author. So the chain runs on and resolves, it just resolves
		-- with an unknown viewer.
		assert.same({}, value)
		assert.is_nil(err)
		assert.equals("", glab.git_user)
		assert.equals("loaded", glab._fetch:status("comments"))
		assert.equals(1, #calls_with("glab", "graphql"))
	end)
end)
