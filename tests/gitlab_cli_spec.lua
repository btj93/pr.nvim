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
	local shim, repo, glab, saved_cwd, saved_notify, notifications

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

		-- run_glab's failure branch echoes the args + result, then the literal
		-- "Error running glab command. Is a glab cli installed?" hint.
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
end)
