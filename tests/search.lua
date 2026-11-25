vim.opt.runtimepath:prepend(vim.fn.getcwd())

local notes = require("neorg.modules.external.indexer.search_notes")
local query = require("neorg.modules.external.indexer.search_query")

local function run()
    local note = notes.parse("/workspace/topic.norg", "topic.norg", ([=[
@document.meta
    title: Release Plan (v2)
    authors: [
        Ada Lovelace
        Grace Hopper
    ]
    categories: dev/research
    project: [New Website]
    effort: 42
    created: 2024-02-29T21:14:00+0200
    updated: 2025-03-01
    hidden: do not match me
    object: {
        list: [
            nested
        ]
        secret: not a top level key
    }
@end
@code norg
@document.meta
literal markup example
@end
draft: next steps | "quoted"; café; mixed É and [brackets].
]=]):gsub("\n", "\r\n"))

    local function match(prompt, implicit)
        return query.match(note, assert(query.parse(prompt), prompt), implicit ~= false)
    end

    local rows, title = match([[title:"Release Plan" content:"next steps" created:2024/02/29 content:literal]])
    assert(title and #rows == 2)
    assert(rows[1].lnum == 22 and rows[1].text == "literal markup example")
    assert(rows[2].lnum == 24 and rows[2].text == [[draft: next steps | "quoted"; café; mixed É and [brackets].]])
    local hits = rows[2].hits
    assert(hits[1].text:sub(hits[1].first, hits[1].last) == "Release Plan")
    assert(hits[2].label == "created" and hits[2].text:sub(hits[2].first, hits[2].last) == "2024-02-29")
    assert(hits[3].text:sub(hits[3].first, hits[3].last) == "next steps")
    rows = match("content:literal missing | release | content:draft | content:steps")
    assert(#rows == 2 and rows[1].lnum == nil and rows[2].lnum == 24)
    assert(rows[1].text == "Release Plan (v2)")
    rows = match("authors:ada")
    assert(#rows == 1 and rows[1].lnum == nil and rows[1].hits[1].label == "authors")
    rows = match("content:missing | content:draft", false)
    assert(#rows == 1 and rows[1].lnum == 24)
    rows = match("release")
    assert(#rows == 1 and rows[1].lnum == nil)
    local preference = notes.parse("/workspace/preference.norg", "preference.norg", "preference")
    rows = query.match(preference, query.parse("preference"), true)
    assert(#rows == 1 and rows[1].lnum == nil)
    rows = query.match(preference, query.parse("preference | content:preference"), true)
    assert(#rows == 2 and rows[1].lnum == nil and rows[2].lnum == 1)
    assert(match([[draft missing|title:"release plan"]]))
    assert(not match([[missing|draft missing]]))
    assert(match([["steps | \"quoted\""]]))
    assert(match("CAFÉ [brackets]"))
    assert(match([[author:"ada lovelace" authors:hopper category:research categories:dev]]))
    assert(match([[project:"new website" effort:42 hidden:"do not match me"]]))
    assert(not match("secret:top"))
    assert(not match([["do not match me"]]))
    assert(not match([[content:"do not match me"]]))
    assert(match([[content:"literal markup example"]]))
    assert(not match("draft", false))
    assert(match("content:draft", false))
    assert(match("release", false))
    assert(match("created:2024 created:2024/02 updated:2025/03/01"))
    assert(match("created:21:14 updated:2025-03"))
    assert(not match("created:2025|updated:2025/04"))
    assert(not match("year:2024|month:02|date:2024-02-29"))
    assert(match("category:dev/research"))
    assert(not match("category:dev-research"))
    local slash_date = notes.parse("/workspace/slash.norg", "slash.norg", table.concat({
        "@document.meta", "updated: 2025/03/01", "@end",
    }, "\n"))
    local slash_rows = query.match(slash_date, query.parse("updated:2025-03-01"), true)
    local slash_hit = slash_rows[1].hits[1]
    assert(slash_hit.text:sub(slash_hit.first, slash_hit.last) == "2025/03/01")
    assert(not match("release -draft"))
    assert(match("release -draft", false))
    assert(not match("release -content:draft", false))
    assert(not match([[release -"next steps"]]))
    assert(not match([[-author:"Grace Hopper"]]))
    assert(not match("-created:2024/02"))
    rows, title = match("-created:2025 -status:archived")
    assert(#rows == 1 and not title and rows[1].lnum == nil and #rows[1].hits == 0)
    rows, title = match("release -draft | content:literal -category:archived")
    assert(#rows == 1 and not title and rows[1].lnum == 22 and #rows[1].hits == 1)
    local literal_dash = notes.parse("/workspace/dash.norg", "dash.norg", "-draft pre-release")
    assert(query.match(literal_dash, query.parse([["-draft" pre-release]]), true))
    local invalid = {
        "-", "release -", "- draft", "-title:", "-updated:",
        "", "title:", "title: release", "one|", "|one", "one||two",
        "\"unfinished", "\"\"", "\"foo\"bar", "created:",
    }
    for _, prompt in ipairs(invalid) do
        assert(not query.parse(prompt), prompt)
    end

    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/nested", "p")
    vim.fn.mkdir(root .. "/generated/categories/deep", "p")
    vim.fn.mkdir(root .. "/generated/categories-extra", "p")
    vim.fn.writefile({ "generator" }, root .. "/generated/main.norg")
    vim.fn.writefile({ "generator" }, root .. "/generated/categories/deep/sub.norg")
    vim.fn.writefile({ "ordinary" }, root .. "/generated/categories-extra/main.norg")
    vim.fn.writefile({ "ordinary" }, root .. "/nested/main.norg")
    vim.fn.writefile({ "ordinary" }, root .. "/index.norg")
    vim.fn.writefile({ "savedonly" }, root .. "/nested/fallback.norg")
    vim.fn.writefile({ "ignored" }, root .. "/ignore.txt")
    assert(vim.uv.fs_symlink("nested", root .. "/link"))
    assert(vim.uv.fs_symlink("nested/fallback.norg", root .. "/linked.norg"))
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, root .. "/nested/fallback.norg")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsavedonly" })
    local before = #vim.api.nvim_list_bufs()
    local function scan(categories)
        local snapshot
        notes.scan(root, categories, function()
            return true
        end, function(results)
            snapshot = results
        end)
        assert(vim.wait(2000, function()
            return snapshot ~= nil
        end), "scan timed out")
        return snapshot
    end
    local scanned = {}
    local scandir = vim.uv.fs_scandir
    vim.uv.fs_scandir = function(path, ...)
        scanned[path] = true
        return scandir(path, ...)
    end
    local snapshot = scan({ name = "./generated/categories/../main.norg", dir = "generated//./categories/" })
    vim.uv.fs_scandir = scandir
    assert(not scanned[root .. "/generated/categories"], "generated subtree was traversed")
    assert(vim.deep_equal(vim.tbl_map(function(item)
        return item.relative
    end, snapshot), { "generated/categories-extra/main.norg", "index.norg", "nested/fallback.norg", "nested/main.norg" }))
    local included = scan()
    vim.fn.delete(root, "rf")
    assert(#vim.api.nvim_list_bufs() == before)
    assert(#included == 6 and included[2].relative == "generated/categories/deep/sub.norg")
    assert(included[3].relative == "generated/main.norg")
    local fallback = snapshot[3]
    assert(fallback.title.value == "fallback")
    assert(query.match(fallback, query.parse("savedonly title:fallback"), true))
    assert(not query.match(fallback, query.parse("unsavedonly"), true))
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
    io.stderr:write(err .. "\n")
    vim.cmd("cquit")
end
print("search regression tests passed")
vim.cmd("qa!")
