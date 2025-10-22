local M = {}

function M.get_provider(opts)
	opts = opts or {}
	local provider = opts.provider or "github"
	return require("pr.providers." .. provider)
end

return M
