local config = require("pr.config")
local log = require("pr.log")

describe("pr.log", function()
	local saved_debug, saved_notify, notifications

	before_each(function()
		saved_debug = config.opts.debug
		saved_notify = vim.notify
		notifications = {}
		vim.notify = function(msg, level)
			table.insert(notifications, { msg = tostring(msg), level = level })
		end
	end)

	after_each(function()
		config.opts.debug = saved_debug
		vim.notify = saved_notify
	end)

	local function rendered()
		local out = {}
		for _, item in ipairs(notifications) do
			table.insert(out, item.msg)
		end
		return table.concat(out, "\n")
	end

	it("redact_argv removes credential flags, payload flags, sensitive fields, and URL userinfo without mutating input", function()
		local args = {
			"api",
			"-u",
			"alice:app-password",
			"-d",
			'{"content":{"raw":"draft text"}}',
			"-f",
			"body=draft text",
			"-f",
			"owner=acme",
			"https://bob:secret@example.com/path",
		}
		local original = vim.deepcopy(args)

		local got = log.redact_argv(args)

		assert.same(original, args)
		assert.equals("-u", got[2])
		assert.equals("<redacted>", got[3])
		assert.equals("-d", got[4])
		assert.equals("<redacted>", got[5])
		assert.equals("body=<redacted>", got[7])
		assert.equals("owner=acme", got[9])
		assert.equals("https://<redacted>@example.com/path", got[10])
	end)

	it("redact_text removes headers, inline secrets, and explicit pattern characters", function()
		local got = log.redact_text("Authorization: Basic abc\nCookie: session=xyz\ntoken=tok password=hunter2 explicit=a+b[1]", { "a+b[1]" })
		assert.is_nil(got:find("Basic abc", 1, true))
		assert.is_nil(got:find("session=xyz", 1, true))
		assert.is_nil(got:find("token=tok", 1, true))
		assert.is_nil(got:find("password=hunter2", 1, true))
		assert.is_nil(got:find("a+b[1]", 1, true))
		assert.truthy(got:find("<redacted>", 1, true))
	end)

	it("redact_text covers body/query fields, non-listed sensitive headers, and never crosses a line boundary", function()
		local got = log.redact_text({
			"PRIVATE-TOKEN: glpat-abcdef",
			"body=an unpublished review body with spaces",
			"query=query { reviewThreads { body } }",
			"Authorization:",
			"real diagnostic output",
		})
		assert.is_nil(got:find("glpat-abcdef", 1, true))
		assert.is_nil(got:find("unpublished review body", 1, true))
		assert.is_nil(got:find("reviewThreads", 1, true))
		assert.truthy(got:find("body=<redacted>", 1, true))
		assert.truthy(got:find("query=<redacted>", 1, true))
		-- `%s*` would have let the bare `Authorization:` swallow the next line.
		assert.truthy(got:find("real diagnostic output", 1, true))
	end)

	it("redact_text scrubs sensitive headers that are indented or quote-prefixed", function()
		local got = log.redact_text({ "> PRIVATE-TOKEN: glpat-DEADBEEF123", "    X-Auth-Token: sekrit-token-value" })
		assert.is_nil(got:find("glpat-DEADBEEF123", 1, true))
		assert.is_nil(got:find("sekrit-token-value", 1, true))
		-- The replacement rebuilds the line from the header name, so the `>` / indent prefix is dropped.
		assert.truthy(got:find("PRIVATE-TOKEN: <redacted>", 1, true))
		assert.truthy(got:find("X-Auth-Token: <redacted>", 1, true))
	end)

	it("redact_text scrubs Bearer tokens and secret= values", function()
		local got = log.redact_text({ "Bearer abc123deadbeef", "client_secret=s3cr3t-value" })
		assert.is_nil(got:find("abc123deadbeef", 1, true))
		assert.is_nil(got:find("s3cr3t-value", 1, true))
		assert.truthy(got:find("Bearer <redacted>", 1, true))
		assert.truthy(got:find("client_secret=<redacted>", 1, true))
	end)

	it("a short value derived from argv is redacted positionally but never used as a substring pattern", function()
		local got = log.redact_argv({ "api", "/repos/acme/widget/pulls/42/comments", "-f", "body=42" })
		assert.equals("/repos/acme/widget/pulls/42/comments", got[2])
		assert.equals("body=<redacted>", got[4])
	end)

	it("a secret passed explicitly by the provider is redacted at any length", function()
		assert.equals("logged in as <redacted>", log.redact_text("logged in as bob", { "bob" }))
	end)

	it("a secret containing a shorter secret is redacted whole, longest pattern first", function()
		-- Without the longest-first sort in collect_secrets, "alice" would run first
		-- and leave the tail behind as "<redacted>:app-secret here".
		assert.equals("<redacted> here", log.redact_text("alice:app-secret here", { "alice", "alice:app-secret" }))
	end)

	it("redact_argv redacts --user and --data-raw values by position and leaves the endpoint readable", function()
		local got = log.redact_argv({ "curl", "--user", "alice:pw", "--data-raw", '{"body":"draft"}', "--url", "https://example.com/x" })
		assert.equals("--user", got[2])
		assert.equals("<redacted>", got[3])
		assert.equals("--data-raw", got[4])
		assert.equals("<redacted>", got[5])
		assert.equals("--url", got[6])
		assert.equals("https://example.com/x", got[7])
	end)

	it("payload_secrets collects user-authored fields only", function()
		local got = log.payload_secrets({
			content = { raw = "unpublished review text" },
			inline = { path = "lua/pr/ui.lua", to = 42 },
			parent = { id = 1001 },
		})
		assert.same({ "unpublished review text" }, got)
	end)

	it("command_failed hides command detail in normal mode", function()
		config.opts.debug = false
		log.command_failed(
			"Bitbucket API request",
			"curl",
			{ "-u", "alice:app-secret", "-d", '{"body":"private draft"}' },
			{ "server echoed alice:app-secret and private draft" },
			{ hint = "Check Bitbucket authentication.", secrets = { "alice", "app-secret", "private draft" }, code = 22 }
		)

		assert.equals(1, #notifications)
		assert.equals(vim.log.levels.ERROR, notifications[1].level)
		assert.truthy(notifications[1].msg:find("Bitbucket API request failed", 1, true))
		assert.truthy(notifications[1].msg:find("Check Bitbucket authentication", 1, true))
		assert.is_nil(notifications[1].msg:find("alice", 1, true))
		assert.is_nil(notifications[1].msg:find("private draft", 1, true))
	end)

	it("command_failed emits only sanitized argv, exit code, and stderr in debug mode", function()
		config.opts.debug = true
		log.command_failed(
			"GitHub comment reply",
			"gh",
			{ "api", "-f", "body=private review", "https://user:s3cr3t-app-token@example.com" },
			{ "request rejected: private review; credential s3cr3t-app-token" },
			{ hint = "Is a gh cli installed?", secrets = { "private review", "s3cr3t-app-token" }, code = 1 }
		)

		local all = rendered()
		assert.equals(3, #notifications)
		assert.truthy(all:find("Is a gh cli installed?", 1, true))
		assert.truthy(all:find("(exit 1)", 1, true))
		assert.truthy(all:find("<redacted>", 1, true))
		assert.is_nil(all:find("private review", 1, true))
		assert.is_nil(all:find("user:s3cr3t-app-token", 1, true))
		assert.is_nil(all:find("credential s3cr3t-app-token", 1, true))
	end)

	it("command_failed tolerates absent argv and blank stderr", function()
		config.opts.debug = true
		log.command_failed("Git root lookup", "git", nil, { "", "" }, { hint = "Is a git cli installed?" })

		assert.equals(2, #notifications)
		assert.equals("Git root lookup failed. Is a git cli installed?", notifications[1].msg)
		assert.equals("git", notifications[2].msg)
	end)
end)
