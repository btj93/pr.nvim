local M = {}

local git = require("pr.provider").get_provider()

---Open the review-submission layout. Fetches (or creates) the pending review,
---lists its queued comments, and mounts the review layout.
function M.show()
	if type(git.start_pending_review) ~= "function" then
		vim.notify("submit-review not available for this provider")
		return
	end
	git.start_pending_review(vim.schedule_wrap(function(review_id, err)
		if not review_id then
			vim.notify(err or "Could not start review", vim.log.levels.ERROR)
			return
		end
		if type(git.list_review_comments) ~= "function" then
			vim.notify("submit-review not available for this provider")
			return
		end
		git.list_review_comments(
			review_id,
			vim.schedule_wrap(function(pending)
				local ui = require("pr.ui")
				ui.make_review_layout(pending or {}, {
					on_submit = function(event, body, unmount)
						-- GitHub permits a bare APPROVE (no body, no pending comments);
						-- only COMMENT and REQUEST_CHANGES need content.
						if (event == "COMMENT" or event == "REQUEST_CHANGES") and body == "" and #(pending or {}) == 0 then
							vim.notify("Body or pending comments required", vim.log.levels.ERROR)
							-- keep the layout open so the user can add content and retry
							return
						end
						if type(git.submit_review) ~= "function" then
							vim.notify("submit-review not available for this provider")
							return
						end
						git.submit_review(
							review_id,
							event,
							body,
							vim.schedule_wrap(function(ok, submit_err)
								if ok then
									vim.notify("Review submitted: " .. event)
									unmount()
								else
									vim.notify("Submit failed: " .. (submit_err or "unknown"), vim.log.levels.ERROR)
									-- keep the layout open so the user can retry without losing their body
								end
							end)
						)
					end,
					on_discard = function()
						if type(git.discard_pending_review) ~= "function" then
							vim.notify("submit-review not available for this provider")
							return
						end
						git.discard_pending_review(
							review_id,
							vim.schedule_wrap(function(ok)
								if ok then
									vim.notify("Pending review discarded")
								end
							end)
						)
					end,
				})
			end)
		)
	end))
end

---Discard the current pending review without opening the layout.
function M._discard()
	if type(git.start_pending_review) ~= "function" then
		vim.notify("submit-review not available for this provider")
		return
	end
	git.start_pending_review(vim.schedule_wrap(function(review_id, err)
		if not review_id then
			vim.notify(err or "Could not find pending review", vim.log.levels.ERROR)
			return
		end
		if type(git.discard_pending_review) ~= "function" then
			vim.notify("submit-review not available for this provider")
			return
		end
		git.discard_pending_review(
			review_id,
			vim.schedule_wrap(function(ok)
				if ok then
					vim.notify("Pending review discarded")
				else
					vim.notify("Discard failed", vim.log.levels.ERROR)
				end
			end)
		)
	end))
end

return M
