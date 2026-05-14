describe("filter.pr_list state", function()
	local filter
	before_each(function()
		package.loaded["pr.pickers.filter"] = nil
		filter = require("pr.pickers.filter")
	end)

	it("defaults to mine", function()
		assert.equals("mine", filter.state.pr_list_filter)
	end)

	it("cycles through filters", function()
		filter.cycle_pr_filter()
		assert.equals("assigned", filter.state.pr_list_filter)
		filter.cycle_pr_filter()
		assert.equals("review-requested", filter.state.pr_list_filter)
		filter.cycle_pr_filter()
		assert.equals("all", filter.state.pr_list_filter)
		filter.cycle_pr_filter()
		assert.equals("mine", filter.state.pr_list_filter)
	end)

	it("pr_list_label wraps the current filter", function()
		assert.equals("[mine] ", filter.pr_list_label())
	end)

	it("reset returns pr_list_filter to mine", function()
		filter.cycle_pr_filter()
		filter.cycle_pr_filter()
		assert.equals("review-requested", filter.state.pr_list_filter)
		filter.reset()
		assert.equals("mine", filter.state.pr_list_filter)
	end)
end)
