describe("completion.omnifunc", function()
	local c
	before_each(function()
		package.loaded["pr.completion"] = nil
		package.loaded["pr.config"] = nil
		c = require("pr.completion")
		require("pr.config").setup({})
		c._set_collaborators({
			{ login = "alice", name = "Alice S" },
			{ login = "alex", name = "Alex K" },
			{ login = "bob" },
		})
		c._set_issues({
			{ number = 42, title = "bug" },
			{ number = 17, title = "feat" },
			{ number = 421, title = "another" },
		})
	end)

	describe("findstart", function()
		it("returns column of @ when cursor is right after @prefix", function()
			c._test_set_line("hello @ali", 10)
			assert.equals(6, c.omnifunc(1, ""))
		end)

		it("returns column of # when cursor is right after #prefix", function()
			c._test_set_line("see #4", 6)
			assert.equals(4, c.omnifunc(1, ""))
		end)

		it("returns cursor column when no trigger found", function()
			c._test_set_line("plain text", 10)
			assert.equals(10, c.omnifunc(1, ""))
		end)

		it("walks back across alphanumeric prefix but stops at whitespace", function()
			c._test_set_line("foo @al bar", 7)
			assert.equals(4, c.omnifunc(1, ""))
		end)
	end)

	describe("@ completion", function()
		it("returns all collaborators for bare @", function()
			c._test_set_line("@", 1)
			local items = c.omnifunc(0, "@")
			assert.equals(3, #items)
		end)

		it("filters by case-insensitive prefix", function()
			c._test_set_line("@al", 3)
			local items = c.omnifunc(0, "@al")
			local logins = {}
			for _, i in ipairs(items) do
				logins[i.word:gsub("^@", "")] = true
			end
			assert.is_true(logins.alice)
			assert.is_true(logins.alex)
			assert.is_nil(logins.bob)
		end)

		it("includes name in menu when present", function()
			c._test_set_line("@alice", 6)
			local items = c.omnifunc(0, "@alice")
			assert.equals(1, #items)
			assert.equals("@alice", items[1].word)
			assert.equals("Alice S", items[1].menu)
		end)
	end)

	describe("# completion", function()
		it("returns all issues for bare #", function()
			c._test_set_line("#", 1)
			local items = c.omnifunc(0, "#")
			assert.equals(3, #items)
		end)

		it("filters by number prefix", function()
			c._test_set_line("#4", 2)
			local items = c.omnifunc(0, "#4")
			assert.equals(2, #items)
			local numbers = {}
			for _, i in ipairs(items) do
				numbers[i.word] = true
			end
			assert.is_true(numbers["#42"])
			assert.is_true(numbers["#421"])
			assert.is_nil(numbers["#17"])
		end)

		it("populates menu with issue title", function()
			c._test_set_line("#42", 3)
			local items = c.omnifunc(0, "#42")
			assert.equals(1, #items)
			assert.equals("#42", items[1].word)
			assert.equals("bug", items[1].menu)
		end)
	end)

	describe("disabled", function()
		it("returns empty list when completion.enabled = false", function()
			require("pr.config").setup({ completion = { enabled = false } })
			c._test_set_line("@al", 3)
			assert.equals(0, #c.omnifunc(0, "@al"))
		end)
	end)
end)
