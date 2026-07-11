local fake_provider = require("helpers.fake_provider")

local function thread(id, opts)
	opts = opts or {}
	return {
		id = id,
		is_resolved = opts.is_resolved or false,
		is_outdated = opts.is_outdated or false,
		viewer_can_reply = true,
		comments = opts.comments or {
			{
				database_id = 1000 + (opts.n or 1),
				author = "alice",
				body = "hello",
				updated_at = "2026-01-01T00:00:00Z",
				viewer_can_update = false,
				viewer_can_delete = false,
				viewer_can_react = true,
				start_line = 3,
				end_line = 3,
			},
		},
	}
end

describe("helpers.fake_provider", function()
	it("logs every call with args", function()
		local fake = fake_provider.new({})
		fake.get_comments(function() end)
		fake.reply("t1", "body", function() end)
		assert.equals("get_comments", fake.calls[1].method)
		assert.equals("reply", fake.calls[2].method)
		assert.same({ "t1", "body" }, { fake.calls[2].args[1], fake.calls[2].args[2] })
	end)

	it("reply mutates the scenario so refetch sees the new comment", function()
		local fake = fake_provider.new({ comments = { ["a.lua"] = { thread("t1") } } })
		fake.reply("t1", "a reply", function(ok)
			assert.is_true(ok)
		end)
		local got
		fake.get_comments(function(c)
			got = c
		end)
		assert.equals(2, #got["a.lua"][1].comments)
		assert.equals("a reply", got["a.lua"][1].comments[2].body)
	end)

	it("resolve/unresolve flip is_resolved", function()
		local fake = fake_provider.new({ comments = { ["a.lua"] = { thread("t1") } } })
		fake.resolve_thread("t1", function() end)
		assert.is_true(fake.scenario.comments["a.lua"][1].is_resolved)
		fake.unresolve_thread("t1", function() end)
		assert.is_false(fake.scenario.comments["a.lua"][1].is_resolved)
	end)

	it("deferred methods capture and fire manually", function()
		local fake = fake_provider.new({})
		fake.deferred.get_comments = true
		local got
		fake.get_comments(function(c)
			got = c
		end)
		assert.is_nil(got)
		fake.fire("get_comments")
		assert.is_not_nil(got)
	end)

	it("install flips provider and uninstall restores it", function()
		local config = require("pr.config")
		local before = config.opts.provider
		local fake, uninstall = fake_provider.install("contract_fake_x", {})
		assert.equals("contract_fake_x", config.opts.provider)
		assert.equals(fake.get_comments, require("pr.provider").get_provider().get_comments)
		uninstall()
		assert.equals(before, config.opts.provider)
	end)
end)
