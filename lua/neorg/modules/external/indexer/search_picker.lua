local notes = require("neorg.modules.external.indexer.search_notes")
local query = require("neorg.modules.external.indexer.search_query")

local M = {}

--- Picker actions. Each takes the prompt buffer number, like Telescope actions.
M.actions = {}

--- Open the PDF of the selected literature with the system default application.
--- @param prompt_bufnr integer
function M.actions.open_pdf(prompt_bufnr)
    local entry = require("telescope.actions.state").get_selected_entry(prompt_bufnr)
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
    local row = entry.value.relative .. ":"
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

local function previewer(config, opts)
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

    return require("telescope.previewers").new_buffer_previewer({
        title = "Grep Preview",
        dyn_title = function(_, entry)
            return entry.value.relative
        end,
        get_buffer_by_name = function(_, entry)
            return entry.path
        end,
        setup = function()
            return { ready = {} }
        end,
        teardown = function(self)
            -- Telescope may tear down a previewer that was never set up.
            local state = self.state
            if not state then
                return
            end
            clear(state)
            state.selection = nil
            state.ready = {}
        end,
        define_preview = function(self, entry)
            local state = self.state
            local buf, win = state.bufnr, state.winid
            clear(state)
            state.selection = { buf = buf, win = win, entry = entry }
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
        previewer = previewer(config, opts),
        attach_mappings = function(_, map)
            for mode, key in pairs(open_pdf_keys) do
                map(mode, key, M.actions.open_pdf, { desc = "Open the PDF of the literature" })
            end
            return true
        end,
        finder = finders.new_dynamic({
            fn = function(prompt)
                local groups = query.parse(prompt)
                local title_results, other_results = {}, {}
                if groups then
                    for _, note in ipairs(snapshot) do
                        local rows, title_hit = query.match(note, groups, search_content)
                        local results = title_hit and title_results or other_results
                        for _, result in ipairs(rows or {}) do
                            results[#results + 1] = {
                                value = note,
                                filename = note.path,
                                path = note.path,
                                ordinal = note.relative,
                                display = display,
                                result = result,
                                lnum = result.lnum,
                            }
                        end
                    end
                end
                return vim.list_extend(title_results, other_results)
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
