describe("suggestion.extract_suggestions", function()
	local s
	before_each(function()
		package.loaded["pr.suggestion"] = nil
		s = require("pr.suggestion")
	end)

	it("returns empty for body with no suggestion fence", function()
		assert.equals(0, #s.extract_suggestions("plain comment"))
		assert.equals(0, #s.extract_suggestions(""))
		assert.equals(0, #s.extract_suggestions(nil))
	end)

	it("extracts one suggestion block", function()
		local body = "Could we?\n```suggestion\nlocal x = 1\nreturn x\n```\n"
		local out = s.extract_suggestions(body)
		assert.equals(1, #out)
		assert.equals(2, #out[1].content_lines)
		assert.equals("local x = 1", out[1].content_lines[1])
		assert.equals("return x", out[1].content_lines[2])
	end)

	it("extracts multiple suggestion blocks", function()
		local body = "a\n```suggestion\nx\n```\nb\n```suggestion\ny\nz\n```\n"
		local out = s.extract_suggestions(body)
		assert.equals(2, #out)
		assert.equals(1, #out[1].content_lines)
		assert.equals(2, #out[2].content_lines)
	end)

	it("treats unclosed fence as no-op (no half-extracted result)", function()
		local body = "```suggestion\nlocal x = 1\n" -- no closing fence
		assert.equals(0, #s.extract_suggestions(body))
	end)

	it("preserves empty inner lines", function()
		local body = "```suggestion\nfirst\n\nthird\n```"
		local out = s.extract_suggestions(body)
		assert.equals(1, #out)
		assert.equals(3, #out[1].content_lines)
		assert.equals("", out[1].content_lines[2])
	end)

	it("ignores ```other-fence blocks", function()
		assert.equals(0, #s.extract_suggestions("```lua\nlocal x = 1\n```"))
		assert.equals(0, #s.extract_suggestions("```\nplain code\n```"))
	end)
end)

describe("suggestion.wrap_as_suggestion and unwrap_suggestion", function()
	local s
	before_each(function()
		package.loaded["pr.suggestion"] = nil
		s = require("pr.suggestion")
	end)

	it("wrap_as_suggestion produces fence + content + close", function()
		local out = s.wrap_as_suggestion({ "hello", "world" })
		assert.matches("^```suggestion\n", out)
		assert.matches("\n```$", out)
		assert.matches("hello", out)
		assert.matches("world", out)
	end)

	it("wrap_as_suggestion handles empty input", function()
		local out = s.wrap_as_suggestion({})
		-- Even an empty wrap should produce a valid (if useless) fence
		assert.matches("^```suggestion\n", out)
		assert.matches("\n```$", out)
	end)

	it("unwrap_suggestion extracts inner lines from a complete fence", function()
		local lines = s.unwrap_suggestion("```suggestion\na\nb\n```")
		assert.is_not_nil(lines)
		assert.equals(2, #lines)
		assert.equals("a", lines[1])
		assert.equals("b", lines[2])
	end)

	it("unwrap_suggestion returns nil for non-fenced text", function()
		assert.is_nil(s.unwrap_suggestion("plain"))
		assert.is_nil(s.unwrap_suggestion("```lua\nx\n```"))
	end)

	it("wrap/unwrap round-trip preserves content", function()
		local inputs = {
			{ "a" },
			{ "a", "b", "c" },
			{ "first", "", "third" },
			{ "  indented", "    deeper" },
		}
		for _, input in ipairs(inputs) do
			local wrapped = s.wrap_as_suggestion(input)
			local unwrapped = s.unwrap_suggestion(wrapped)
			assert.is_not_nil(unwrapped)
			assert.equals(#input, #unwrapped)
			for i, line in ipairs(input) do
				assert.equals(line, unwrapped[i])
			end
		end
	end)
end)
