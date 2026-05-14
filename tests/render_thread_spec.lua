local ui = require("pr.ui")
local render = ui._render_thread

local function mk_comment(opts)
	opts = opts or {}
	return {
		database_id = opts.database_id or 1,
		author = opts.author or "alice",
		viewer_did_author = opts.viewer_did_author or false,
		body = opts.body or "hello",
		reaction_groups = opts.reaction_groups or {},
	}
end

local function mk_thread(comments, opts)
	opts = opts or {}
	return {
		id = opts.id or "T_1",
		is_resolved = opts.is_resolved or false,
		viewer_can_reply = opts.viewer_can_reply ~= false,
		viewer_can_resolve = opts.viewer_can_resolve ~= false,
		comments = comments,
	}
end

describe("render_thread", function()
	it("emits a header rule + body + footer for a single comment, no trailing gap", function()
		local result = render(mk_thread({ mk_comment({ author = "alice", body = "first line\nsecond line" }) }))
		-- Expect: header rule, body line 1, body line 2 (footer is the body_end since no reactions)
		assert.are.equal(3, #result.lines)
		assert.is_truthy(result.lines[1]:find("alice", 1, true))
		assert.are.equal("first line", result.lines[2])
		assert.are.equal("second line", result.lines[3])
		assert.are.same({ [1] = 1, [2] = 1, [3] = 1 }, result.line_to_comment)
	end)

	it("appends ' (you)' to the author when viewer_did_author is true", function()
		local result = render(mk_thread({ mk_comment({ author = "alice", viewer_did_author = true }) }))
		assert.is_truthy(result.lines[1]:find("alice (you)", 1, true))
	end)

	it("populates comment_meta.body_start / body_end / footer_line correctly", function()
		local result = render(mk_thread({ mk_comment({ body = "a\nb\nc" }) }))
		local meta = result.comment_meta[1]
		assert.are.equal(1, meta.header_line)
		assert.are.equal(2, meta.body_start)
		assert.are.equal(4, meta.body_end)
		assert.are.equal(4, meta.footer_line) -- no reactions => footer = body_end
	end)

	it("inserts a blank gap line between consecutive comments, mapped to the preceding comment", function()
		local result = render(mk_thread({
			mk_comment({ author = "alice", body = "a" }),
			mk_comment({ author = "bob", body = "b" }),
		}))
		-- alice header, alice body, gap, bob header, bob body
		assert.are.equal(5, #result.lines)
		assert.are.equal("", result.lines[3]) -- gap
		assert.are.equal(1, result.line_to_comment[3]) -- gap mapped to comment 1
		assert.are.equal(2, result.line_to_comment[4]) -- bob's header
		assert.are.equal(2, result.line_to_comment[5]) -- bob's body
	end)

	it("does NOT append a gap line after the last comment", function()
		local result = render(mk_thread({ mk_comment(), mk_comment({ author = "bob" }) }))
		-- 5 lines total = 2*(header+body) + 1 gap; no trailing empty line
		assert.are.equal(5, #result.lines)
		assert.are_not.equal("", result.lines[#result.lines])
	end)

	it("emits a blank line + emoji row when at least one reaction has totalCount > 0", function()
		local result = render(mk_thread({
			mk_comment({
				body = "hello",
				reaction_groups = {
					{ content = "THUMBS_UP", viewerHasReacted = false, reactors = { totalCount = 3 } },
				},
			}),
		}))
		-- header, body, "", emoji row
		assert.are.equal(4, #result.lines)
		assert.are.equal("", result.lines[3])
		assert.is_truthy(result.lines[4]:find("👍", 1, true))
		assert.is_truthy(result.lines[4]:find("3", 1, true))
		assert.are.equal(4, result.comment_meta[1].footer_line) -- footer = emoji row
		assert.are.equal(2, result.comment_meta[1].body_end) -- body_end stays at body, not emoji
	end)

	it("omits the emoji row when all reactions have totalCount = 0", function()
		local result = render(mk_thread({
			mk_comment({
				body = "hello",
				reaction_groups = {
					{ content = "THUMBS_UP", viewerHasReacted = false, reactors = { totalCount = 0 } },
				},
			}),
		}))
		assert.are.equal(2, #result.lines) -- header + body only
	end)

	it("does not crash on an empty body", function()
		local result = render(mk_thread({ mk_comment({ body = "" }) }))
		-- header + 1 body line (the single empty body line)
		assert.are.equal(2, #result.lines)
		assert.are.equal("", result.lines[2])
		assert.are.equal(2, result.comment_meta[1].body_start)
		assert.are.equal(2, result.comment_meta[1].body_end)
	end)

	it("normalizes \\r\\n line endings before splitting the body", function()
		local result = render(mk_thread({ mk_comment({ body = "a\r\nb" }) }))
		-- header + "a" + "b" (the \r is stripped before split on \n)
		assert.are.equal(3, #result.lines)
		assert.are.equal("a", result.lines[2])
		assert.are.equal("b", result.lines[3])
	end)

	it("every emitted line has an entry in line_to_comment pointing to a valid comment index", function()
		local result = render(mk_thread({
			mk_comment({ body = "a" }),
			mk_comment({ body = "b\nc", reaction_groups = { { content = "HEART", viewerHasReacted = false, reactors = { totalCount = 1 } } } }),
		}))
		for i = 1, #result.lines do
			local idx = result.line_to_comment[i]
			assert.is_truthy(idx, "no mapping for line " .. i)
			assert.is_truthy(idx == 1 or idx == 2, "unexpected comment index " .. tostring(idx) .. " at line " .. i)
		end
	end)
end)

describe("render_thread with suggestion blocks", function()
	it("emits a visual box for a comment containing a suggestion fence", function()
		local result = render(mk_thread({
			mk_comment({
				body = "Could we?\n```suggestion\nlocal x = 1\nreturn x\n```\n",
			}),
		}))
		local body = table.concat(result.lines, "\n")
		assert.matches("suggestion", body)
		assert.matches("║ %+ local x = 1", body)
		assert.matches("║ %+ return x", body)
		assert.matches("Could we%?", body)
		-- The raw fence text must not appear verbatim in the rendered output.
		for _, line in ipairs(result.lines) do
			assert.is_falsy(line:match("^```suggestion%s*$"), "raw opening fence leaked into render")
			assert.is_falsy(line:match("^```%s*$"), "raw closing fence leaked into render")
		end
	end)

	it("renders multiple suggestion blocks within a single comment", function()
		local body = table.concat({
			"first",
			"```suggestion",
			"a = 1",
			"```",
			"middle",
			"```suggestion",
			"b = 2",
			"```",
			"end",
		}, "\n")
		local result = render(mk_thread({ mk_comment({ body = body }) }))
		local joined = table.concat(result.lines, "\n")
		assert.matches("║ %+ a = 1", joined)
		assert.matches("║ %+ b = 2", joined)
		assert.matches("first", joined)
		assert.matches("middle", joined)
		assert.matches("end", joined)
	end)

	it("includes suggestion box lines in the body range so navigation lands on them", function()
		local result = render(mk_thread({
			mk_comment({ body = "pre\n```suggestion\nx\n```\npost" }),
		}))
		local meta = result.comment_meta[1]
		-- body_start..body_end should span every emitted body line including
		-- the header rule, content line(s), and footer rule of the box.
		local body_line_count = meta.body_end - meta.body_start + 1
		-- Expected body lines: "pre", "╔═ suggestion …", "║ + x", "╚…", "post" => 5
		assert.are.equal(5, body_line_count)
		for ln = meta.body_start, meta.body_end do
			assert.are.equal(1, result.line_to_comment[ln])
		end
	end)

	it("falls back to plain rendering when the fence is unclosed", function()
		local result = render(mk_thread({
			mk_comment({ body = "before\n```suggestion\nno close here" }),
		}))
		-- No complete suggestion => extract returns nothing => raw lines pass through.
		local joined = table.concat(result.lines, "\n")
		assert.matches("```suggestion", joined)
		assert.matches("no close here", joined)
	end)
end)
