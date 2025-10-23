local config = require("pr.config")

local M = {}

---
---@param provider? string
---@return table
function M.get_provider(provider)
	provider = provider or config.opts.provider
	return require("pr.providers." .. provider)
end

return M
