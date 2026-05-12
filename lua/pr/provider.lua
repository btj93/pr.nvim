local config = require("pr.config")

local M = {}

local function resolve(name)
	local mod = require("pr.providers." .. name)
	return mod
end

-- Proxy that resolves the configured provider on each access, so callers
-- can safely bind `local git = require("pr.provider").get_provider()` at
-- module load time before `setup()` runs.
local proxy = setmetatable({}, {
	__index = function(_, k)
		return resolve(config.opts.provider)[k]
	end,
})

---
---@param provider? string
---@return table
function M.get_provider(provider)
	if provider then
		return resolve(provider)
	end
	return proxy
end

return M
