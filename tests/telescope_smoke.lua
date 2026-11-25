vim.opt.runtimepath:prepend(vim.fn.getcwd())

local root = vim.fn.tempname()
local function run()
    local plugins = vim.env.NEORG_TEST_PLUGINS or (vim.fn.stdpath("data") .. "/lazy")
    for _, name in ipairs({ "neorg", "lua-utils.nvim", "nvim-nio", "nui.nvim", "pathlib.nvim" }) do
        vim.opt.runtimepath:append(plugins .. "/" .. name)
    end
    local workspace = root .. "/workspace"
    vim.fn.mkdir(workspace .. "/nested", "p")
    vim.fn.mkdir(workspace .. "/generated/cats/deep", "p")
    vim.fn.mkdir(workspace .. "/generated/cats-extra", "p")
    vim.fn.writefile({ "indexmarker" }, workspace .. "/generated/main.norg")
    vim.fn.writefile({ "indexmarker" }, workspace .. "/generated/cats/deep/sub.norg")
    vim.fn.writefile({ "indexmarker" }, workspace .. "/generated/cats-extra/sub.norg")
    vim.fn.writefile({ "indexmarker" }, workspace .. "/nested/main.norg")
    vim.fn.writefile({ "match in body" }, workspace .. "/a-body.norg")
    local target = workspace .. "/nested/match-b.norg"
    local lines = {
        "@document.meta",
        "authors: [Ada Lovelace]",
        "created: 2025-04-01",
        "@end",
        "Match first body",
        "ignored branch",
        "",
        "  Next match body with full trailing text",
    }
    local function write_target()
        vim.fn.writefile(vim.tbl_map(function(line)
            return line .. "\r"
        end, lines), target)
    end
    write_target()
    vim.fn.writefile({ "old saved body" }, workspace .. "/match-c.norg")
    vim.fn.writefile({ "match outside workspace" }, root .. "/outside.norg")
    vim.cmd.cd(root)

    require("neorg").setup({
        load = {
            ["core.neorgcmd"] = {},
            ["core.dirman"] = { config = { workspaces = { notes = workspace } } },
            ["core.integrations.treesitter"] = { config = { configure_parsers = false } },
            ["external.indexer"] = {
                config = {
                    categories = {
                        index_on_change = false,
                        name = "./generated/cats/../main.norg",
                        dir = "generated//./cats/",
                    },
                    search = { search_content = false },
                },
            },
        },
    })
    local modules = require("neorg.core").modules
    local indexer = assert(modules.get_module("external.indexer"))
    local dirman = assert(modules.get_module("core.dirman"))
    local completions = vim.fn.getcompletion("Neorg ", "cmdline")
    assert(vim.tbl_contains(completions, "indexer"))
    assert(vim.tbl_contains(completions, "indexer-search"))
    assert(package.loaded["telescope.pickers"] == nil)

    local notified
    local notify = vim.notify
    vim.notify = function(message)
        notified = message
    end
    assert(indexer.search() == nil)
    vim.notify = notify
    assert(notified and notified:find("telescope.nvim", 1, true))

    vim.opt.runtimepath:append(plugins .. "/plenary.nvim")
    vim.opt.runtimepath:append(plugins .. "/telescope.nvim")
    require("telescope").setup({
        defaults = { initial_mode = "normal", layout_strategy = "vertical", layout_config = { preview_cutoff = 0 } },
    })
    assert(dirman.set_workspace("notes"))
    vim.cmd("Neorg indexer-search")
    local actions = require("telescope.actions")
    local state = require("telescope.actions.state")
    local picker
    assert(vim.wait(2000, function()
        local buf = vim.api.nvim_get_current_buf()
        if vim.bo[buf].filetype == "TelescopePrompt" then
            picker = state.get_current_picker(buf)
            return true
        end
    end), "Neorg command did not open Telescope")
    assert(picker.previewer, "default previewer missing")

    local function await_rows(prompt, expected)
        picker:set_prompt(prompt)
        assert(vim.wait(2000, function()
            if not picker.manager or picker.manager:num_results() ~= #expected then
                return false
            end
            for i, result in ipairs(expected) do
                local entry = picker.manager:get_entry(i)
                if not entry or entry.lnum ~= result[1] or entry.display(entry) ~= result[2] then
                    return false
                end
            end
            return true
        end), "unexpected results for " .. prompt)
    end

    local b = "nested/match-b.norg:"
    await_rows("", {})
    await_rows("match", { { nil, "match-c.norg:match-c" }, { nil, b .. "match-b" } })
    await_rows("content:outside", {})
    await_rows("author:ada", { { nil, b .. "[authors: Ada Lovelace]:match-b" } })
    await_rows("content:indexmarker", {
        { 1, "generated/cats-extra/sub.norg:1:indexmarker" },
        { 1, "nested/main.norg:1:indexmarker" },
    })
    -- Title-ranked notes first, then path order, with distinct body lines in file order.
    await_rows("match | content:match", {
        { nil, "match-c.norg:match-c" },
        { nil, b .. "match-b" },
        { 5, b .. "5:" .. lines[5] },
        { 8, b .. "8:" .. lines[8] },
        { 1, "a-body.norg:1:match in body" },
    })
    await_rows("match|", {})
    local meta = "[authors: Ada Lovelace]:[created: 2025-04-01]:"
    local first, last = lines[5], lines[8]
    lines[5] = "changed on disk"
    write_target()
    await_rows(
        "title:match | author:ada authors:love date:2025-04-01 content:first content:next"
            .. " | content:ignored missing | author:ada date:2025-04-01 content:body missing",
        {
            { nil, "match-c.norg:match-c" },
            { nil, b .. "match-b" },
            { 5, b .. meta .. "5:" .. first },
            { 8, b .. meta .. "8:" .. last },
        }
    )
    local hl = vim.api.nvim_get_namespaces().telescope_entry
    local matched = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(picker.results_bufnr, hl, 0, -1, { details = true })) do
        local row = vim.api.nvim_buf_get_lines(picker.results_bufnr, mark[2], mark[2] + 1, false)[1]
        matched[row:sub(mark[3] + 1, mark[4].end_col)] = true
    end
    assert(
        vim.deep_equal(matched, { match = true, Ada = true, Love = true, ["2025-04-01"] = true, first = true, Next = true }),
        vim.inspect(matched)
    )
    local preview = assert(picker.preview_win)
    picker:set_selection(3)
    assert(vim.wait(2000, function()
        local buf = vim.api.nvim_win_get_buf(preview)
        return vim.api.nvim_buf_get_lines(buf, 7, 8, false)[1] == last
    end), "Telescope did not load the selected file preview")
    -- The buffer is ready; exercise line navigation between rows of the same file.
    picker:set_selection(2)
    assert(vim.api.nvim_win_get_cursor(preview)[1] == 5)
    picker:set_selection(3)
    assert(state.get_selected_entry().lnum == 8 and vim.api.nvim_win_get_cursor(preview)[1] == 8,
        "Telescope did not preview the selected body line")
    actions.select_default(picker.prompt_bufnr)
    local opened = vim.api.nvim_buf_get_name(0)
    assert(opened ~= "" and vim.uv.fs_realpath(opened) == vim.uv.fs_realpath(target), opened)
    assert(vim.api.nvim_win_get_cursor(0)[1] == 8, "Telescope did not jump to the selected body line")

    modules.get_module_config("external.indexer").search.include_generated = true
    picker = assert(indexer.search({ previewer = false }))
    await_rows("content:indexmarker", {
        { 1, "generated/cats-extra/sub.norg:1:indexmarker" },
        { 1, "generated/cats/deep/sub.norg:1:indexmarker" },
        { 1, "generated/main.norg:1:indexmarker" },
        { 1, "nested/main.norg:1:indexmarker" },
    })
    actions.close(picker.prompt_bufnr)

    assert(dirman.set_workspace("default"))
    vim.cmd.cd(root)
    picker = assert(indexer.search({ previewer = false }))
    assert(not picker.previewer)
    await_rows("title:outside", { { nil, "outside.norg:outside" } })
    actions.close(picker.prompt_bufnr)

    -- A body row should also jump on the initial load of a cold preview buffer.
    assert(dirman.set_workspace("notes"))
    picker = assert(indexer.search())
    await_rows("content:next", { { 8, b .. "8:" .. last } })
    local cold_preview = assert(picker.preview_win)
    assert(vim.wait(2000, function()
        return vim.api.nvim_win_get_cursor(cold_preview)[1] == 8
    end), "Telescope did not jump on initial preview load")
    actions.close(picker.prompt_bufnr)
end

local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then
    io.stderr:write(err .. "\n")
    vim.cmd("cquit!")
end
print("Neorg + Telescope smoke passed")
vim.cmd("qa!")
