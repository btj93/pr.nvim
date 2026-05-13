describe("provider.get_base_sha contract", function()
	for _, name in ipairs({ "github", "gitlab", "bitbucket" }) do
		it(name .. " exposes get_base_sha as a function", function()
			local p = require("pr.providers." .. name)
			assert.equals("function", type(p.get_base_sha))
		end)

		it(name .. " exposes M.base_sha field", function()
			local p = require("pr.providers." .. name)
			assert.is_not_nil(p.base_sha)
			assert.equals("string", type(p.base_sha))
		end)
	end
end)
