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
        "  笔记 Next match body with full trailing text",
    }
    local function write_target()
        vim.fn.writefile(vim.tbl_map(function(line)
            return line .. "\r"
        end, lines), target)
    end
    write_target()
    vim.fn.writefile({ "old saved body" }, workspace .. "/match-c.norg")
    -- Metadata filters read the generated indexes, not @document.meta.
    vim.fn.writefile({ "@document.meta", "authors: [Grace Hopper]", "@end" }, workspace .. "/unindexed.norg")
    vim.fn.mkdir(workspace .. "/index/authors", "p")
    vim.fn.mkdir(workspace .. "/index/created/2025/04", "p")
    vim.fn.writefile(
        { "* Ada Lovelace", "", "** {:$/nested/match-b:}[match-b]" },
        workspace .. "/index/authors/Ada Lovelace.norg"
    )
    vim.fn.writefile({ "* 2025", "", "** {:2025/04:}[2025-04]" }, workspace .. "/index/created/2025.norg")
    vim.fn.writefile(
        { "* 2025-04-01", "", "** {:$/nested/match-b:}[match-b]" },
        workspace .. "/index/created/2025/04/01.norg"
    )
    -- Generated index directories contain the marker file.
    for _, dir in ipairs({ "generated/cats", "index/authors", "index/created" }) do
        vim.fn.writefile({}, workspace .. "/" .. dir .. "/.neorg-indexer")
    end
    vim.fn.writefile({ "match outside workspace" }, root .. "/outside.norg")
    vim.cmd.cd(root)

    require("neorg").setup({
        load = {
            ["core.neorgcmd"] = {},
            ["core.dirman"] = { config = { workspaces = { notes = workspace } } },
            ["core.integrations.treesitter"] = { config = { configure_parsers = false } },
            ["external.indexer"] = {
                config = {
                    name = "./generated/cats/../main.norg",
                    index_on_change = false,
                    categories = { dir = "generated//./cats/" },
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
    local file_maker = require("telescope.previewers").buffer_previewer_maker
    local delay_target, finish_preview
    local target_reads = 0
    require("telescope").setup({
        defaults = {
            initial_mode = "normal",
            layout_strategy = "vertical",
            layout_config = { preview_cutoff = 0 },
            buffer_previewer_maker = function(path, buf, opts)
                if delay_target and path == target then
                    target_reads = target_reads + 1
                    local callback = opts.callback
                    opts.callback = function(preview_buf)
                        finish_preview = function()
                            callback(preview_buf)
                        end
                    end
                end
                file_maker(path, buf, opts)
            end,
        },
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
    await_rows("author:grace", {})
    await_rows("status:draft", {})
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
        "title:match | author:ada authors:love created:2025/04/01 content:first content:next content:笔记"
            .. " | content:ignored missing | author:ada created:2025-04-01 content:body missing",
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
        vim.deep_equal(matched, {
            match = true, Ada = true, Love = true, ["2025-04-01"] = true, first = true, Next = true, ["笔记"] = true,
        }),
        vim.inspect(matched)
    )
    local preview_ns = assert(vim.api.nvim_get_namespaces()["neorg-indexer.search-preview"])
    local function preview_marks(buf)
        local matches, full_line, line_priority = {}, nil, nil
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, preview_ns, 0, -1, { details = true })) do
            local row, col, details = mark[2], mark[3], mark[4]
            if details.line_hl_group then
                assert(details.line_hl_group == "TelescopePreviewLine" and col == 0 and not full_line)
                full_line, line_priority = row + 1, details.priority
            else
                assert(details.hl_group == "TelescopeMatching")
                matches[#matches + 1] = { row + 1, col, details.end_col, details.priority }
            end
        end
        for _, match in ipairs(matches) do
            assert(line_priority and match[4] > line_priority)
            match[4] = nil
        end
        return full_line, matches
    end

    local function await_preview(lnum, expected)
        local win = assert(picker.preview_win)
        assert(vim.wait(2000, function()
            local buf = vim.api.nvim_win_get_buf(win)
            local line, matches = preview_marks(buf)
            return vim.api.nvim_buf_get_lines(buf, 7, 8, false)[1] == last
                and line == lnum and vim.deep_equal(matches, expected)
                and (not lnum or vim.deep_equal(vim.api.nvim_win_get_cursor(win), { lnum, 0 }))
        end), "unexpected preview highlights or cursor for line " .. tostring(lnum))
    end

    local last_matches = { { 8, 2, 8 }, { 8, 9, 13 } } -- 笔记 takes six bytes.
    picker:set_selection(3)
    await_preview(8, last_matches)
    picker:set_selection(2)
    await_preview(5, {}) -- Disk contents no longer match the indexed byte offsets.
    picker:set_selection(1)
    await_preview(nil, {})
    await_rows("author:ada", { { nil, b .. "[authors: Ada Lovelace]:match-b" } })
    await_preview(nil, {})
    await_rows("content:next", { { 8, b .. "8:" .. last } })
    await_preview(8, { { 8, 9, 13 } })
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

    -- With a cold, in-flight preview, switch to another row of the same file
    -- before the maker completes. Only the current selection should be drawn.
    assert(dirman.set_workspace("notes"))
    lines[5] = first
    write_target()
    delay_target = true
    picker = assert(indexer.search())
    await_rows("content:first content:next content:笔记", { { 5, b .. "5:" .. first }, { 8, b .. "8:" .. last } })
    assert(vim.wait(2000, function()
        return finish_preview ~= nil
    end), "custom maker did not load the cold preview")
    assert(state.get_selected_entry().lnum == 5)
    picker:set_selection(1)
    finish_preview()
    await_preview(8, last_matches)
    assert(target_reads == 1, "same-file selection started a duplicate preview read")
    picker:set_selection(0)
    await_preview(5, { { 5, 6, 11 } })
    actions.close(picker.prompt_bufnr)
    delay_target = false

    -- Literatures: a PDF entry, resolved from the `file` field, follows the .bib entry. Its preview
    -- shows the .bib file, and selecting it opens the PDF with the system default application.
    local bibtex = require("neorg.modules.external.indexer.bibtex")
    bibtex.available = function()
        return true
    end
    bibtex.read = function(_, path)
        return {
            citekey = "lit2020",
            metadata = { title = "Smoke Literature" },
            pdf = bibtex.find_pdf(path, { file = "Paper:papers/lit2020.pdf:PDF" }),
        }
    end
    local bib = workspace .. "/lit/lit2020.bib"
    local pdf = workspace .. "/lit/papers/lit2020.pdf"
    vim.fn.mkdir(workspace .. "/lit/papers", "p")
    vim.fn.writefile({ "@article{lit2020,", "  title = {Smoke Literature},", "}" }, bib)
    local file = assert(io.open(pdf, "wb"))
    file:write("%PDF-1.4\n\0\255binary\n")
    file:close()
    local opened = {}
    local ui_open = vim.ui.open
    vim.ui.open = function(path)
        opened[#opened + 1] = path
    end
    picker = assert(indexer.search())
    local bib_row = "lit/lit2020.bib:[lit2020] Smoke Literature"
    local pdf_row = "lit/papers/lit2020.pdf:[PDF]:[lit2020] Smoke Literature"
    await_rows("title:lit2020", { { nil, bib_row }, { nil, pdf_row } })
    assert(picker.manager:get_entry(2).pdf == pdf)
    picker:set_selection(1)
    assert(vim.wait(2000, function()
        local buf = vim.api.nvim_win_get_buf(picker.preview_win)
        return vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], "@article{lit2020,")
    end), "the PDF entry does not preview its .bib file")
    local search_picker = require("neorg.modules.external.indexer.search_picker")
    search_picker.actions.open_pdf(picker.prompt_bufnr)
    picker:set_selection(0)
    search_picker.actions.open_pdf(picker.prompt_bufnr)
    picker:set_selection(1)
    actions.select_default(picker.prompt_bufnr)
    assert(vim.deep_equal(opened, { pdf, pdf, pdf }), vim.inspect(opened))
    assert(vim.api.nvim_buf_get_name(0) ~= pdf, "the PDF was loaded into a buffer")
    -- With image.nvim (stubbed here), the PDF entry previews the first page, converted in the
    -- background.
    local pdf_preview = require("neorg.modules.external.indexer.pdf_preview")
    local cache_dir, converter, system = pdf_preview.cache_dir, pdf_preview.converter, vim.system
    pdf_preview.cache_dir = function()
        return root .. "/cache"
    end
    pdf_preview.converter = function()
        return "magick"
    end
    local conversions = {}
    vim.system = function(cmd, _, on_exit)
        assert(cmd[4] == pdf .. "[0]", vim.inspect(cmd))
        conversions[#conversions + 1] = function(code)
            if code == 0 then
                vim.fn.writefile({ "png" }, cmd[#cmd]:sub(5))
            end
            on_exit({ code = code, stderr = "no Ghostscript" })
        end
        return {}
    end
    local images = {}
    package.loaded.image = {
        from_file = function(path, opts)
            local image = { path = path, opts = opts, rendered = 0, cleared = 0 }
            function image.render(self)
                self.rendered = self.rendered + 1
            end
            function image.clear(self)
                self.cleared = self.cleared + 1
            end
            images[#images + 1] = image
            return image
        end,
    }
    local function preview_lines(expected)
        assert(vim.wait(2000, function()
            local buf = vim.api.nvim_win_get_buf(picker.preview_win)
            return vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, #expected, false), expected)
        end), "preview does not show " .. vim.inspect(expected))
    end
    local bib_lines = { "@article{lit2020," }
    picker = assert(indexer.search())
    await_rows("title:lit2020", { { nil, bib_row }, { nil, pdf_row } })
    picker:set_selection(1)
    preview_lines({ vim.fn.fnamemodify(pdf, ":~"), "", "Rendering preview…" })
    assert(#conversions == 1)
    -- The conversion finishes after the selection moved: nothing is drawn.
    picker:set_selection(0)
    preview_lines(bib_lines)
    conversions[1](0)
    assert(vim.wait(2000, function()
        return #vim.fn.glob(root .. "/cache/*.png", false, true) == 1
    end))
    vim.wait(50)
    assert(#images == 0, "a stale conversion was drawn")
    -- The cached PNG is drawn, fitted into the preview window, over an empty buffer.
    picker:set_selection(1)
    assert(vim.wait(2000, function()
        return #images == 1 and images[1].rendered == 1
    end), "the PDF preview was not drawn")
    local win = picker.preview_win
    local preview_buf = vim.api.nvim_win_get_buf(win)
    assert(vim.deep_equal(images[1].opts, {
        window = win,
        buffer = preview_buf,
        x = 0,
        y = 0,
        width = vim.api.nvim_win_get_width(win),
        height = vim.api.nvim_win_get_height(win),
    }), vim.inspect(images[1].opts))
    assert(images[1].path:sub(1, #root) == root and #conversions == 1)
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false), { "" }))
    -- Other entries clear the image, and so does closing the picker.
    picker:set_selection(0)
    preview_lines(bib_lines)
    assert(images[1].cleared == 1)
    picker:set_selection(1)
    assert(vim.wait(2000, function()
        return #images == 2 and images[2].rendered == 1
    end))
    actions.close(picker.prompt_bufnr)
    assert(images[2].cleared == 1 and images[1].cleared == 1)
    -- A failed conversion falls back to the .bib file, with one warning.
    file = assert(io.open(pdf, "ab"))
    file:write("changed")
    file:close()
    local warnings = {}
    vim.notify = function(message, level)
        warnings[#warnings + 1] = { message, level }
    end
    picker = assert(indexer.search())
    await_rows("title:lit2020", { { nil, bib_row }, { nil, pdf_row } })
    picker:set_selection(1)
    assert(vim.wait(2000, function()
        return #conversions == 2
    end))
    conversions[2](1)
    preview_lines(bib_lines)
    picker:set_selection(0)
    picker:set_selection(1)
    preview_lines(bib_lines)
    vim.notify = notify
    assert(#warnings == 1 and warnings[1][1]:find("no Ghostscript", 1, true), vim.inspect(warnings))
    assert(#conversions == 2 and #images == 2)
    actions.close(picker.prompt_bufnr)
    -- Closing the picker forgets the failure: the next picker converts again and warns again.
    vim.notify = function(message, level)
        warnings[#warnings + 1] = { message, level }
    end
    picker = assert(indexer.search())
    await_rows("title:lit2020", { { nil, bib_row }, { nil, pdf_row } })
    picker:set_selection(1)
    assert(vim.wait(2000, function()
        return #conversions == 3
    end))
    conversions[3](1)
    preview_lines(bib_lines)
    vim.notify = notify
    assert(#warnings == 2 and warnings[2][1]:find("no Ghostscript", 1, true), vim.inspect(warnings))
    actions.close(picker.prompt_bufnr)
    vim.system, pdf_preview.converter, pdf_preview.cache_dir = system, converter, cache_dir
    package.loaded.image = nil
    pdf_preview.reset()
    -- Without a PDF, only the .bib entry is listed.
    vim.fn.delete(pdf)
    picker = assert(indexer.search({ previewer = false }))
    await_rows("title:lit2020", { { nil, bib_row } })
    actions.select_default(picker.prompt_bufnr)
    assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) == vim.uv.fs_realpath(bib))
    assert(#opened == 3)
    vim.ui.open = ui_open
end

local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then
    io.stderr:write(err .. "\n")
    vim.cmd("cquit!")
end
print("Neorg + Telescope smoke passed")
vim.cmd("qa!")
