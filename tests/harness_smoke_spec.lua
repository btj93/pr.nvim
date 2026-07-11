-- Smoke test for the test harness itself: nui must be on rtp (cloned by
-- minimal_init) and tests/helpers/ must be requireable via package.path.
describe("test harness environment", function()
	it("can require nui popup", function()
		local ok = pcall(require, "nui.popup")
		assert.is_true(ok)
	end)

	it("resolves helpers via package.path", function()
		-- Any file under tests/helpers/<x>.lua must load as helpers.<x>.
		local ok, err = pcall(require, "helpers.fake_provider")
		assert.is_true(ok, tostring(err))
		assert.equals("function", type(require("helpers.fake_provider").install))
	end)
end)
