local notes = require("neorg.modules.external.indexer.search_notes")
local pdf_preview = require("neorg.modules.external.indexer.pdf_preview")
local query = require("neorg.modules.external.indexer.search_query")

local M = {}

--- Picker actions. Each takes the prompt buffer number, like Telescope actions.
M.actions = {}

--- Open the PDF of the selected literature, or the selected PDF, with the system default
--- application.
--- @param prompt_bufnr integer
function M.actions.open_pdf(prompt_bufnr)
    local entry = require("telescope.actions.state").get_selected_entry(prompt_bufnr)
    -- A PDF entry's value is its literature.
    local item = entry and entry.value
    if not item then
        return
    end
    if item.kind ~= "literature" then
        vim.notify("Neorg indexer: " .. item.relative .. " is not a literature", vim.log.levels.WARN)
        return
    end
    if not item.pdf or vim.fn.filereadable(item.pdf) ~= 1 then
        vim.notify("Neorg indexer: no PDF found for " .. item.relative, vim.log.levels.WARN)
        return
    end
    vim.ui.open(item.pdf)
end

--- Keys of the open_pdf mapping per mode.
--- @param value any `search.mappings.open_pdf`: a key for insert and normal mode, a table
--- `{ i = key, n = key }`, or `false` to disable the mapping
--- @return table map of mode -> key
function M.mapping_keys(value)
    if value == nil then
        value = "<C-o>"
    end
    if type(value) == "string" then
        return { i = value, n = value }
    end
    if type(value) == "table" then
        local keys = {}
        for _, mode in ipairs({ "i", "n" }) do
            if type(value[mode]) == "string" then
                keys[mode] = value[mode]
            end
        end
        return keys
    end
    return {}
end

local function oneline(value)
    -- Keep tabs; replace other control bytes without changing match offsets.
    return (value:gsub("%c", function(char)
        return char == "\t" and char or " "
    end))
end

local function display(entry)
    local row = entry.label .. ":"
    local highlights, ranges, metadata = {}, {}, {}

    local function highlight(offset, hit)
        local first, last = offset + hit.first - 1, offset + hit.last
        local key = first .. ":" .. last
        if not ranges[key] then
            highlights[#highlights + 1] = { { first, last }, "TelescopeMatching" }
            ranges[key] = true
        end
    end

    for _, hit in ipairs(entry.result.hits) do
        if hit.kind == "metadata" then
            local label = hit.label .. ": "
            local key = label .. hit.text
            local offset = metadata[key]
            if not offset then
                offset = #row + 1 + #label
                row = row .. "[" .. key .. "]:"
                metadata[key] = offset
            end
            highlight(offset, hit)
        end
    end
    if entry.lnum then
        row = row .. entry.lnum .. ":"
    end
    local kind = entry.lnum and "content" or "title"
    for _, hit in ipairs(entry.result.hits) do
        if hit.kind == kind then
            highlight(#row, hit)
        end
    end
    return oneline(row .. entry.result.text), highlights
end

--- Label of a PDF entry: the path of the PDF relative to the workspace root, or its absolute path
--- (with `~` for the home directory) when it is outside the workspace, followed by `:[PDF]`.
local function pdf_label(root, pdf)
    local path = pdf:sub(1, #root + 1) == root .. "/" and pdf:sub(#root + 2) or vim.fn.fnamemodify(pdf, ":~")
    return path .. ":[PDF]"
end

--- The PDF entry of a literature, listed right after the literature's rows. It shows the
--- literature's title with the title and metadata hits of all its rows; its path is the .bib file,
--- which the previewer shows.
local function pdf_entry(root, note, rows)
    local hits = {}
    for _, row in ipairs(rows) do
        for _, hit in ipairs(row.hits) do
            if hit.kind ~= "content" then
                hits[#hits + 1] = hit
            end
        end
    end
    local label = pdf_label(root, note.pdf)
    return {
        value = note,
        pdf = note.pdf,
        filename = note.path,
        path = note.path,
        label = label,
        ordinal = label .. " " .. note.title.value,
        display = display,
        result = { text = note.title.value, hits = hits },
    }
end

--- Picker entries of the notes that match a query: notes with title matches first, each note's
--- rows in order, and a literature's PDF entry right after its rows when it has a PDF.
--- @param root string normalized workspace root
--- @param snapshot table[] scanned notes and literatures, see search_notes.scan
--- @param groups table[]|nil parsed query, see search_query.parse
--- @param search_content boolean whether plain terms also match body text
--- @return table[] entries
function M.entries(root, snapshot, groups, search_content)
    local title_results, other_results = {}, {}
    for _, note in ipairs(groups and snapshot or {}) do
        local rows, title_hit = query.match(note, groups, search_content)
        local results = title_hit and title_results or other_results
        for _, result in ipairs(rows or {}) do
            results[#results + 1] = {
                value = note,
                filename = note.path,
                path = note.path,
                label = note.relative,
                ordinal = note.relative,
                display = display,
                result = result,
                lnum = result.lnum,
            }
        end
        if rows and note.kind == "literature" and note.pdf then
            results[#results + 1] = pdf_entry(root, note, rows)
        end
    end
    return vim.list_extend(title_results, other_results)
end

--- @param pdf_options table|nil image previews of PDF entries, see pdf_preview.options
local function previewer(config, opts, pdf_options)
    if opts.previewer == false or opts.preview == false or (config.preview == false and not opts.preview) then
        return false
    end
    local api = vim.api
    local ns = api.nvim_create_namespace("neorg-indexer.search-preview")
    opts.preview = vim.tbl_extend(
        "force",
        type(config.preview) == "table" and config.preview or {},
        type(opts.preview) == "table" and opts.preview or {}
    )

    local function clear(state)
        local buf = state.highlight_buf
        if buf and api.nvim_buf_is_valid(buf) then
            api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        end
        state.highlight_buf = nil
        if state.image then
            pcall(state.image.clear, state.image)
            state.image = nil
        end
    end

    local function set_lines(buf, lines)
        vim.bo[buf].modifiable = true
        api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end

    local function render(state, buf)
        local selection = state.selection
        if not selection or selection.buf ~= buf then
            return
        end
        local win, entry = selection.win, selection.entry
        if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= buf or not entry.lnum then
            return
        end
        local row = entry.lnum - 1
        local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
        if not line then
            return
        end

        state.highlight_buf = buf
        api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = "TelescopePreviewLine", priority = 200 })
        -- The file may have changed since indexing, or the maker may transform it.
        if line == entry.result.text then
            local seen = {}
            for _, hit in ipairs(entry.result.hits) do
                if hit.kind == "content" then
                    local key = hit.first .. ":" .. hit.last
                    if not seen[key] then
                        seen[key] = true
                        api.nvim_buf_set_extmark(buf, ns, row, hit.first - 1, {
                            end_col = hit.last,
                            hl_group = "TelescopeMatching",
                            priority = 201,
                        })
                    end
                end
            end
        end
        api.nvim_win_set_cursor(win, { entry.lnum, 0 })
        api.nvim_win_call(win, function()
            vim.cmd("normal! zz")
        end)
    end

    -- Load an entry's file into the preview buffer, or render it when already loaded.
    local function load(state, buf, win, entry)
        if state.ready[buf] then
            render(state, buf)
        elseif state.ready[buf] == nil then
            -- Re-selecting a cached buffer must not bypass an in-flight read.
            state.ready[buf] = false
            config.buffer_previewer_maker(entry.path, buf, {
                winid = win,
                preview = opts.preview,
                file_encoding = opts.file_encoding,
                callback = vim.schedule_wrap(function()
                    if state.ready[buf] == false then
                        state.ready[buf] = true
                        render(state, buf)
                    end
                end),
            })
        end
    end

    -- Draw the first page of the selected PDF, or fall back to its .bib file. The buffer shows a
    -- placeholder until the image is ready, and is emptied under the image.
    local function preview_pdf(state, selection, image)
        local buf, entry = selection.buf, selection.entry
        if not state.pdf[buf] then
            state.pdf[buf] = true
            set_lines(buf, { vim.fn.fnamemodify(entry.pdf, ":~"), "", "Rendering preview…" })
        end
        pdf_preview.rasterize(entry.pdf, pdf_options, function(png, err)
            local win = selection.win
            -- Ignore results for a previous selection or a closed picker.
            if state.selection ~= selection or not api.nvim_buf_is_valid(buf) or not api.nvim_win_is_valid(win) then
                return
            end
            if api.nvim_win_get_buf(win) ~= buf then
                return
            end
            if png then
                set_lines(buf, { "" })
                state.image, err = pdf_preview.show(image, png, win, buf)
                if state.image then
                    return
                end
            end
            pdf_preview.warn(err)
            load(state, buf, win, entry)
        end)
    end

    return require("telescope.previewers").new_buffer_previewer({
        title = "Grep Preview",
        dyn_title = function(_, entry)
            return entry.value.relative
        end,
        get_buffer_by_name = function(_, entry)
            -- With image previews, a PDF entry has its own buffer instead of sharing the .bib one.
            return entry.pdf and pdf_options and entry.pdf or entry.path
        end,
        setup = function()
            return { ready = {}, pdf = {} }
        end,
        teardown = function(self)
            -- The next picker retries failed renderings, and reports them again.
            pdf_preview.forget_errors()
            -- Telescope may tear down a previewer that was never set up.
            local state = self.state
            if not state then
                return
            end
            clear(state)
            state.selection = nil
            state.ready = {}
            state.pdf = {}
        end,
        define_preview = function(self, entry)
            local state = self.state
            local buf, win = state.bufnr, state.winid
            clear(state)
            local selection = { buf = buf, win = win, entry = entry }
            state.selection = selection
            -- A PDF buffer that fell back to text keeps showing text.
            local image = entry.pdf and pdf_options and state.ready[buf] == nil and pdf_preview.available()
            if image then
                preview_pdf(state, selection, image)
            else
                load(state, buf, win, entry)
            end
        end,
    })
end

--- Open the search picker.
--- @param root string normalized workspace root
--- @param index_config table external.indexer public configuration
--- @param opts table|nil Telescope picker options
function M.open(root, index_config, opts)
    local ok, pickers = pcall(require, "telescope.pickers")
    if not ok then
        vim.notify(
            "Neorg indexer search requires telescope.nvim and plenary.nvim: " .. tostring(pickers),
            vim.log.levels.ERROR
        )
        return
    end
    local finders = require("telescope.finders")
    local sorters = require("telescope.sorters")
    local config = require("telescope.config").values
    local search_index = require("neorg.modules.external.indexer.search_index")
    opts = opts or {}
    local search_content = index_config.search.search_content
    local excluded = not index_config.search.include_generated and search_index.generated_paths(index_config, root)
        or nil
    -- Metadata filters use the generated indexes, read once per picker.
    local metadata = search_index.read(root, index_config)
    local mappings = type(index_config.search.mappings) == "table" and index_config.search.mappings or {}
    local open_pdf_keys = M.mapping_keys(mappings.open_pdf)

    local snapshot = {}
    local picker = pickers.new(opts, {
        cwd = root,
        prompt_title = "Search Neorg notes",
        results_title = "Workspace notes",
        sorting_strategy = "ascending",
        previewer = previewer(config, opts, pdf_preview.options(index_config.search.pdf_preview)),
        attach_mappings = function(_, map)
            local action_set = require("telescope.actions.set")
            local action_state = require("telescope.actions.state")
            local telescope_actions = require("telescope.actions")
            -- Every select action (default, split, vsplit, tab, drop) on a PDF entry closes the
            -- picker and opens the PDF with the system default application.
            action_set.select:replace_if(function(prompt_bufnr)
                local entry = action_state.get_selected_entry(prompt_bufnr)
                return entry ~= nil and entry.pdf ~= nil
            end, function(prompt_bufnr)
                local entry = action_state.get_selected_entry(prompt_bufnr)
                telescope_actions.close(prompt_bufnr)
                if vim.fn.filereadable(entry.pdf) ~= 1 then
                    vim.notify("Neorg indexer: no PDF found for " .. entry.value.relative, vim.log.levels.WARN)
                    return
                end
                vim.ui.open(entry.pdf)
            end)
            for mode, key in pairs(open_pdf_keys) do
                map(mode, key, M.actions.open_pdf, { desc = "Open the PDF of the literature" })
            end
            return true
        end,
        finder = finders.new_dynamic({
            fn = function(prompt)
                return M.entries(root, snapshot, query.parse(prompt), search_content)
            end,
            entry_maker = function(entry)
                return entry
            end,
        }),
        sorter = sorters.Sorter:new({
            scoring_function = function(_, _, _, entry)
                return entry.index
            end,
        }),
    })
    picker:find()
    notes.scan(root, excluded, function()
        return not picker.closed and vim.api.nvim_buf_is_valid(picker.prompt_bufnr)
    end, function(results)
        snapshot = results
        picker:refresh()
    end, metadata)
    return picker
end

return M
