local REQUIRED_METHODS = {
	"get_repo_info",
	"get_pr_number",
	"get_commit_hash",
	"get_base_sha",
	"get_comments",
	"get_hunks",
	"get_git_root",
	"get_git_user",
	"add_reaction",
	"remove_reaction",
	"reply",
	"comment",
	"edit_comment",
	"resolve_thread",
	"unresolve_thread",
	"delete_comment",
	"thread_url",
	-- S1a — PR explorer + checkout
	"list_prs",
	"checkout_pr",
	-- S1b — PR info popup
	"get_pr_metadata",
	"update_pr_metadata",
	"get_checks",
	-- S1c — submit review
	"start_pending_review",
	"add_review_comment",
	"list_review_comments",
	"submit_review",
	"discard_pending_review",
	-- S2b — conflict-aware edits
	"refetch_comment",
	-- S3b — completion
	"list_collaborators",
	"list_issues",
	-- clears
	"clear",
	"clear_comments",
	"clear_hunks",
	"clear_pr_number",
	"clear_pr_list",
	"clear_pr_metadata",
	"clear_checks",
	"clear_pending_review",
	"clear_collaborators",
	"clear_issues",
}

local REQUIRED_FIELDS = {
	"comments",
	"hunks",
	"repo_info",
	"pr_number",
	"git_root",
	"git_user",
	"base_sha",
	"reaction_palette",
}

local providers = {
	github = require("pr.providers.github"),
	gitlab = require("pr.providers.gitlab"),
	bitbucket = require("pr.providers.bitbucket"),
}

describe("provider contract", function()
	for name, p in pairs(providers) do
		describe(name, function()
			for _, method in ipairs(REQUIRED_METHODS) do
				it("exposes method `" .. method .. "`", function()
					assert.equals("function", type(p[method]), name .. " missing method: " .. method)
				end)
			end

			for _, field in ipairs(REQUIRED_FIELDS) do
				it("exposes module field `" .. field .. "`", function()
					assert.is_not_nil(p[field], name .. " missing field: " .. field)
				end)
			end

			it("reaction_palette is a list of { content, glyph } entries", function()
				assert.equals("table", type(p.reaction_palette))
				for i, entry in ipairs(p.reaction_palette) do
					assert.equals("string", type(entry.content), name .. " palette[" .. i .. "].content not a string")
					assert.equals(entry.content, string.upper(entry.content), name .. " palette[" .. i .. "].content not uppercase")
					assert.equals("string", type(entry.glyph), name .. " palette[" .. i .. "].glyph not a string")
					assert.is_true(#entry.glyph > 0, name .. " palette[" .. i .. "].glyph is empty")
				end
			end)
		end)
	end

	it("fake provider (tests/helpers) implements the full contract", function()
		local fake = require("helpers.fake_provider").new({})
		for _, method in ipairs(REQUIRED_METHODS) do
			assert.equals("function", type(fake[method]), "fake provider missing method: " .. method)
		end
		for _, field in ipairs(REQUIRED_FIELDS) do
			assert.is_not_nil(fake[field], "fake provider missing field: " .. field)
		end
	end)
end)
