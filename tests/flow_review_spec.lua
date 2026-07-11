-- Tier 2 flow spec: drives :PRReview's real submit/discard keymaps over the fake
-- provider inside the headless ui_env harness. review.show mounts
-- ui.make_review_layout (which self-mounts) through a start_pending_review ->
-- list_review_comments -> make_review_layout chain, so every post-show assertion
-- is gated on a predicate wait rather than a fixed sleep.
--
-- Coverage: APPROVE/REQUEST_CHANGES/COMMENT submit (a/r/c), discard-with-confirm
-- plus declined-confirm (d), close-retaining-pending (q), and the empty-body
-- guard rejecting a content-less REQUEST_CHANGES.
if not pcall(require, "nui.popup") then
	return
end
local ui_env = require("helpers.ui_env")
local fake_provider = require("helpers.fake_provider")
local called = fake_provider.called

-- The review body editor is the modifiable markdown float; the sibling
-- pending-list popup is non-modifiable and carries no filetype.
local function find_body_win(env)
	for _, win in ipairs(env.floats()) do
		local buf = vim.api.nvim_win_get_buf(win)
		if vim.bo[buf].filetype == "markdown" then
			return win, buf
		end
	end
end

local function has_notification(env, needle)
	for _, n in ipairs(env.notifications) do
		if type(n.msg) == "string" and n.msg:find(needle, 1, true) then
			return true
		end
	end
	return false
end

local function submit_events(fake)
	local out = {}
	for _, c in ipairs(fake.calls) do
		if c.method == "submit_review" then
			table.insert(out, c.args[2])
		end
	end
	return out
end

describe("flow: :PRReview submit / discard", function()
	local env, fake, uninstall

	before_each(function()
		env = ui_env.setup()
		fake, uninstall = fake_provider.install("flow_review_fake", {
			pending = { review_id = 99, comments = {} },
		})
	end)

	after_each(function()
		-- Drain scheduled submit/discard callbacks while the popup buffers are
		-- still alive so teardown's buffer wipe can't race a late callback.
		env.drain()
		uninstall()
		env.teardown()
	end)

	-- Mount the review layout, focus the body editor, and return its win + buf.
	local function open_review()
		require("pr.review").show()
		env.wait_for(function()
			return find_body_win(env) ~= nil
		end, 2000, "review layout mounted")
		local win, buf = find_body_win(env)
		vim.api.nvim_set_current_win(win)
		return win, buf
	end

	it(":PRReview submits APPROVE with body via a", function()
		local _, buf = open_review()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "looks good to me" })
		env.feed("a")

		env.wait_for(function()
			return called(fake, "submit_review") ~= nil
		end, 2000, "submit_review call")

		local call = called(fake, "submit_review")
		-- submit_review(review_id, event, body, cb): the pending review id, the
		-- APPROVE event, and the joined body editor content.
		assert.equals(99, call.args[1])
		assert.equals("APPROVE", call.args[2])
		assert.matches("looks good to me", call.args[3])

		-- A successful submit tears the layout down and notifies.
		env.wait_for(function()
			return #env.floats() == 0
		end, 2000, "layout unmounted after submit")
		assert.is_true(has_notification(env, "Review submitted: APPROVE"))
	end)

	it("r submits REQUEST_CHANGES; c submits COMMENT", function()
		-- REQUEST_CHANGES with a body.
		local _, buf = open_review()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "please address the nits" })
		env.feed("r")
		env.wait_for(function()
			return #submit_events(fake) == 1
		end, 2000, "REQUEST_CHANGES submit")
		assert.equals("REQUEST_CHANGES", submit_events(fake)[1])

		-- The first submit unmounted the layout; re-open a fresh one and COMMENT.
		env.wait_for(function()
			return #env.floats() == 0
		end, 2000, "first layout gone")
		local _, buf2 = open_review()
		vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "just a thought" })
		env.feed("c")
		env.wait_for(function()
			return #submit_events(fake) == 2
		end, 2000, "COMMENT submit")

		assert.same({ "REQUEST_CHANGES", "COMMENT" }, submit_events(fake))
	end)

	it("d discards after confirm; declining confirm keeps the pending review", function()
		open_review()

		-- Decline first: confirm returns 2 (Cancel) -> no discard, layout retained.
		env.confirm_choice = 2
		env.feed("d")
		vim.wait(100, function()
			return false
		end)
		assert.is_nil(called(fake, "discard_pending_review"))
		assert.is_true(#env.floats() > 0)

		-- Accept: confirm returns 1 (Discard) -> discard_pending_review fires.
		env.confirm_choice = 1
		env.feed("d")
		env.wait_for(function()
			return called(fake, "discard_pending_review") ~= nil
		end, 2000, "discard call")
		assert.equals(99, called(fake, "discard_pending_review").args[1])
		env.wait_for(function()
			return #env.floats() == 0
		end, 2000, "layout unmounted after discard")
	end)

	it("q closes retaining pending comments (no submit/discard calls)", function()
		-- Seed pending comments so "retaining" is observable after close.
		fake.scenario.pending.comments = {
			{ id = 1, path = "lua/a.lua", start_line = 3, end_line = 3, body = "nit: rename" },
		}
		open_review()

		env.feed("q")
		env.wait_for(function()
			return #env.floats() == 0
		end, 2000, "layout closed")

		assert.is_nil(called(fake, "submit_review"))
		assert.is_nil(called(fake, "discard_pending_review"))
		-- The pending queue is untouched (neither submitted nor discarded).
		assert.equals(1, #fake.scenario.pending.comments)
	end)

	it("REQUEST_CHANGES with empty body is rejected with a notification and no submit call", function()
		-- Empty pending + empty body: a request-changes review has no content, so
		-- the on_submit guard must reject it before any submit_review call.
		open_review() -- body editor left empty

		env.feed("r")
		env.wait_for(function()
			return has_notification(env, "Body or pending comments required")
		end, 2000, "empty-body rejection notified")

		assert.is_nil(called(fake, "submit_review"))
		-- The layout stays open so the user can add content and retry.
		assert.is_true(#env.floats() > 0)
	end)
end)
