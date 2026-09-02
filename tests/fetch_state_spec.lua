local fetch_state = require("pr.fetch_state")

describe("pr.fetch_state", function()
	local co

	before_each(function()
		co = fetch_state.new()
	end)

	it("cold start hands the first caller the fetch and settles it on resolve", function()
		local got
		local action, token = co:begin("comments", function(v)
			got = v
		end)

		assert.equals("start", action)
		assert.is_not_nil(token)
		assert.equals("loading", co:status("comments"))

		assert.is_true(co:resolve("comments", token, { a = 1 }))
		assert.same({ a = 1 }, got)
		assert.equals("loaded", co:status("comments"))
	end)

	it("reports loaded without queuing a waiter once a fetch has settled", function()
		local _, token = co:begin("comments", function() end)
		co:resolve("comments", token, { a = 1 })

		local called = false
		local action, token2 = co:begin("comments", function()
			called = true
		end)

		assert.equals("loaded", action)
		assert.is_nil(token2)
		-- The provider replays its own cached value on this path, so the
		-- coordinator must NOT have invoked the callback itself.
		assert.is_false(called)
	end)

	it("caches a successful EMPTY result as loaded instead of refetching", function()
		local _, token = co:begin("comments", function() end)
		co:resolve("comments", token, {})

		assert.equals("loaded", co:status("comments"))
		assert.equals("loaded", (co:begin("comments", function() end)))
	end)

	it("coalesces concurrent callers into one fetch and settles both", function()
		local first, second
		local action1, token = co:begin("hunks", function(v)
			first = v
		end)
		local action2, token2 = co:begin("hunks", function(v)
			second = v
		end)

		assert.equals("start", action1)
		assert.equals("joined", action2)
		assert.is_nil(token2)

		co:resolve("hunks", token, { h = true })
		assert.same({ h = true }, first)
		assert.same({ h = true }, second)
	end)

	it("settles waiters with the fallback and error on reject, then allows a retry", function()
		local value, err
		local _, token = co:begin("comments", function(v, e)
			value, err = v, e
		end)

		assert.is_true(co:reject("comments", token, {}, "boom"))
		assert.same({}, value)
		assert.equals("boom", err)
		assert.equals("error", co:status("comments"))
		assert.equals("boom", co:error("comments"))

		-- A failure is not cached as a successful empty result: the next
		-- caller owns a fresh attempt.
		local action, token2 = co:begin("comments", function() end)
		assert.equals("start", action)
		assert.is_not_nil(token2)
		assert.is_nil(co:error("comments"))
	end)

	it("bumps the generation on reject so the failed fetch cannot settle the retry", function()
		local _, first = co:begin("comments", function() end)
		assert.is_true(co:reject("comments", first, {}, "network down"))

		local retry_value
		local action, second = co:begin("comments", function(v)
			retry_value = v
		end)
		assert.equals("start", action)

		-- The rejected fetch's token is spent: it neither owns the retry nor
		-- can deliver its stale value into the retry's waiter.
		assert.is_false(co:owns("comments", first))
		assert.is_false(co:resolve("comments", first, "STALE"))
		assert.is_false(co:reject("comments", first, {}, "stale boom"))
		assert.is_nil(retry_value)

		assert.is_true(co:resolve("comments", second, { fresh = true }))
		assert.same({ fresh = true }, retry_value)
	end)

	it("scopes a token to the resource it was minted for", function()
		-- Both resources sit at generation 0, so the generation alone cannot
		-- tell these tokens apart. One provider's get_comments calls get_hunks
		-- internally, putting exactly this pair in one closure.
		local _, comments_token = co:begin("comments", function() end)
		local hunks_value
		co:begin("hunks", function(v)
			hunks_value = v
		end)

		assert.is_true(co:owns("comments", comments_token))
		assert.is_false(co:owns("hunks", comments_token))
		assert.is_false(co:resolve("hunks", comments_token, "COMMENTS DATA"))
		assert.is_false(co:reject("hunks", comments_token, {}, "boom"))
		assert.is_nil(hunks_value)
		assert.equals("loading", co:status("hunks"))
	end)

	it("isolates a raising waiter so the callers queued behind it still settle", function()
		local notified = {}
		local original_notify = vim.notify
		vim.notify = function(msg, level)
			notified[#notified + 1] = { msg = msg, level = level }
		end

		local second, third
		local _, token = co:begin("comments", function()
			error("waiter one blew up")
		end)
		co:begin("comments", function(v)
			second = v
		end)
		co:begin("comments", function(v)
			third = v
		end)

		local ok = pcall(co.resolve, co, "comments", token, { a = 1 })
		vim.notify = original_notify

		assert.is_true(ok)
		assert.same({ a = 1 }, second)
		assert.same({ a = 1 }, third)
		assert.equals(1, #notified)
		assert.equals(vim.log.levels.ERROR, notified[1].level)
		assert.is_not_nil(notified[1].msg:find("waiter one blew up", 1, true))
	end)

	it("settles in-flight waiters when the resource is invalidated mid-fetch", function()
		local value, err
		local _, token = co:begin("comments", function(v, e)
			value, err = v, e
		end)

		co:invalidate("comments", {}, "cleared")

		assert.same({}, value)
		assert.equals("cleared", err)
		assert.equals("cold", co:status("comments"))
		-- The abandoned fetch can no longer settle anything.
		assert.is_false(co:resolve("comments", token, { late = true }))
		assert.equals("cold", co:status("comments"))
	end)

	it("ignores a stale completion from before an invalidation", function()
		local _, stale = co:begin("comments", function() end)
		co:invalidate("comments", {})

		local fresh_value
		local action, fresh = co:begin("comments", function(v)
			fresh_value = v
		end)
		assert.equals("start", action)

		assert.is_false(co:resolve("comments", stale, { old = true }))
		assert.is_false(co:reject("comments", stale, {}, "old"))

		assert.is_true(co:resolve("comments", fresh, { new = true }))
		assert.same({ new = true }, fresh_value)
	end)

	it("delivers to each waiter exactly once", function()
		local counts = { 0, 0, 0 }
		local _, token = co:begin("comments", function()
			counts[1] = counts[1] + 1
		end)
		co:begin("comments", function()
			counts[2] = counts[2] + 1
		end)
		co:begin("comments", function()
			counts[3] = counts[3] + 1
		end)

		co:resolve("comments", token, {})
		-- A second settle attempt with the same token must be a no-op.
		assert.is_false(co:resolve("comments", token, {}))
		co:invalidate("comments", {})

		assert.same({ 1, 1, 1 }, counts)
	end)

	it("delivers to a waiter that registers a new fetch during the drain", function()
		-- The drain swaps the waiter list out before iterating, so a waiter
		-- that re-enters begin() queues onto the NEXT cycle rather than being
		-- settled by the drain it is running inside.
		local late_value, second_token
		co:begin("comments", function()
			local _, t = co:begin("comments", function(v)
				late_value = v
			end)
			second_token = t
		end)

		co:invalidate("comments", {}, "cleared")

		assert.equals("loading", co:status("comments"))
		assert.is_not_nil(second_token)
		assert.is_nil(late_value)

		assert.is_true(co:resolve("comments", second_token, { fresh = true }))
		assert.same({ fresh = true }, late_value)
	end)

	it("keeps resources independent", function()
		local _, ct = co:begin("comments", function() end)
		local _, ht = co:begin("hunks", function() end)
		co:resolve("comments", ct, {})
		co:resolve("hunks", ht, {})

		co:invalidate("comments", {})
		assert.equals("cold", co:status("comments"))
		assert.equals("loaded", co:status("hunks"))
	end)

	it("invalidate_all clears every resource, not just one", function()
		-- Every resource is left loaded, so each assertion below carries its
		-- own signal about the resource it names.
		local _, ct = co:begin("comments", function() end)
		local _, ht = co:begin("hunks", function() end)
		local _, pt = co:begin("pr_number", function() end)
		co:resolve("comments", ct, {})
		co:resolve("hunks", ht, {})
		co:resolve("pr_number", pt, {})

		co:invalidate_all({}, "refresh")

		assert.equals("cold", co:status("comments"))
		assert.equals("cold", co:status("hunks"))
		assert.equals("cold", co:status("pr_number"))
	end)

	it("invalidate_all leaves a resource a drained waiter created mid-sweep alone", function()
		co:begin("comments", function()
			co:begin("hunks", function() end)
		end)

		co:invalidate_all({}, "refresh")

		assert.equals("cold", co:status("comments"))
		-- "hunks" was born after the sweep's key snapshot, so its fresh fetch
		-- survives instead of being swept back to cold.
		assert.equals("loading", co:status("hunks"))
	end)

	it("owns() gates cache publication and goes false on invalidation", function()
		local _, token = co:begin("comments", function() end)
		assert.is_true(co:owns("comments", token))
		-- Loading is the only state in which the nil-token guard does any
		-- work; cold, loaded and error all fail on the status conjunct first.
		assert.is_false(co:owns("comments", nil))

		co:invalidate("comments", {})
		assert.is_false(co:owns("comments", token))

		local _, fresh = co:begin("comments", function() end)
		assert.is_true(co:owns("comments", fresh))
		co:resolve("comments", fresh, {})
		-- Settled fetches are no longer owned by anyone.
		assert.is_false(co:owns("comments", fresh))
	end)

	it("tolerates a begin with no callback and still coalesces later joiners", function()
		local action, token = co:begin("comments")
		assert.equals("start", action)
		assert.equals("loading", co:status("comments"))

		local joined
		local action2 = co:begin("comments", function(v)
			joined = v
		end)
		assert.equals("joined", action2)

		assert.is_true(co:resolve("comments", token, { ok = true }))
		assert.same({ ok = true }, joined)
	end)
end)
