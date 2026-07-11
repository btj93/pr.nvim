local cli_shim = require("helpers.cli_shim")

describe("helpers.cli_shim", function()
	local shim

	after_each(function()
		if shim then
			shim.uninstall()
			shim = nil
		end
	end)

	local function run(cmd)
		local out = vim.fn.system(cmd)
		return out, vim.v.shell_error
	end

	it("first matching route wins and argv is logged", function()
		shim = cli_shim.new()
		shim.stub("gh", {
			{ match = { "pr", "view" }, stdout = "42\n" },
			{ match = { "pr" }, stdout = "SHOULD NOT WIN\n" },
		})
		shim.install()
		local out, code = run({ "gh", "pr", "view", "--json", "number" })
		assert.equals("42\n", out)
		assert.equals(0, code)
		local calls = shim.calls("gh")
		assert.equals(1, #calls)
		assert.same({ "pr", "view", "--json", "number" }, calls[1])
	end)

	it("subsequence match is ordered (substring within tokens allowed)", function()
		shim = cli_shim.new()
		shim.stub("gh", { { match = { "api", "user" }, stdout = "ok\n" } })
		shim.install()
		local _, code = run({ "gh", "user", "api" }) -- wrong order: no match
		assert.equals(99, code)
		local out2, code2 = run({ "gh", "api", "-q", ".login", "user" }) -- interleaved: matches
		assert.equals("ok\n", out2)
		assert.equals(0, code2)
	end)

	it("unknown argv exits 99 and still logs", function()
		shim = cli_shim.new()
		shim.stub("glab", { { match = { "mr", "view" }, stdout = "{}" } })
		shim.install()
		local _, code = run({ "glab", "unknown", "thing" })
		assert.equals(99, code)
		assert.equals(1, #shim.calls("glab"))
	end)

	it("stdout_file, nonzero exit, and stderr work", function()
		shim = cli_shim.new()
		local f = vim.fn.tempname()
		vim.fn.writefile({ '{"a":1}' }, f)
		shim.stub("curl", {
			{ match = { "/user" }, stdout_file = f },
			{ match = { "/boom" }, exit = 22, stderr = "The requested URL returned error: 401" },
		})
		shim.install()
		local out = run({ "curl", "-sS", "https://api/x/user" })
		assert.truthy(out:find('"a":1', 1, true))
		local _, code = run({ "curl", "https://api/x/boom" })
		assert.equals(22, code)
	end)

	it("uninstall restores PATH and real binaries resolve again", function()
		shim = cli_shim.new()
		shim.stub("git", { { match = { "--version" }, stdout = "shimmed!\n" } }) -- only in this meta-test
		shim.install()
		assert.truthy(run({ "git", "--version" }):find("shimmed"))
		shim.uninstall()
		assert.truthy(run({ "git", "--version" }):find("git version"))
		shim = nil
	end)
end)
