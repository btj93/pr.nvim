-- Tier 2 flow spec: locks pr_list.checkout's success/failure branches over the
-- fake provider. On success it must proactively re-check the branch (via
-- pr._check_branch_and_refresh) and reload changed buffers (checktime); on a
-- failed checkout it must NOT refresh. checkout_pr's callback is
-- schedule_wrapped, so assertions are predicate-gated rather than timed.
local ui_env = require("helpers.ui_env")
local fake_provider = require("helpers.fake_provider")
local called = fake_provider.called

local function has_notification(env, needle)
	for _, n in ipairs(env.notifications) do
		if type(n.msg) == "string" and n.msg:find(needle, 1, true) then
			return true
		end
	end
	return false
end

describe("flow: pr_list.checkout", function()
	local env, fake, uninstall, pr, saved_recheck, recheck_calls

	before_each(function()
		env = ui_env.setup()
		fake, uninstall = fake_provider.install("flow_pr_list_fake", {})
		-- checkout success proactively drives the branch-change refresh; spy on it
		-- so the flow can assert the refresh ran (or didn't) without shelling out.
		pr = require("pr")
		saved_recheck = pr._check_branch_and_refresh
		recheck_calls = 0
		pr._check_branch_and_refresh = function()
			recheck_calls = recheck_calls + 1
		end
	end)

	after_each(function()
		pr._check_branch_and_refresh = saved_recheck
		env.drain(50)
		uninstall()
		env.teardown()
	end)

	it("pr_list.checkout calls checkout_pr and, on success, checktime + branch re-check", function()
		require("pr.pr_list").checkout(123)

		env.wait_for(function()
			return recheck_calls > 0
		end, 2000, "branch re-check ran")

		local call = called(fake, "checkout_pr")
		assert.is_not_nil(call)
		assert.equals(123, call.args[1])
		-- The success branch runs the re-check exactly once (checktime follows it
		-- in the same callback; a no-op in headless with no modified buffers).
		assert.equals(1, recheck_calls)
	end)

	it("checkout failure notifies the error and does not refresh", function()
		-- Real providers notify on a failed checkout; pr_list.checkout relies on
		-- that and must itself avoid the branch-change refresh. Override
		-- checkout_pr to notify + report failure through its schedule_wrapped cb.
		fake.checkout_pr = function(pr_number, cb)
			table.insert(fake.calls, { method = "checkout_pr", args = { pr_number } })
			vim.notify("checkout failed: dirty working tree", vim.log.levels.ERROR)
			cb(false, "dirty working tree")
		end

		require("pr.pr_list").checkout(456)

		env.wait_for(function()
			return has_notification(env, "checkout failed")
		end, 2000, "failure notified")

		-- Give any (erroneous) scheduled refresh a chance to run, then assert none did.
		vim.wait(100, function()
			return recheck_calls > 0
		end)
		assert.equals(0, recheck_calls)
		assert.equals(456, called(fake, "checkout_pr").args[1])
	end)
end)
