local notes = require("neorg.modules.external.indexer.search_notes")
local query = require("neorg.modules.external.indexer.search_query")

local M = {}

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

function M.open(root, search_content, categories, opts)
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
    opts = opts or {}

    local snapshot = {}
    local picker = pickers.new(opts, {
        cwd = root,
        prompt_title = "Search Neorg notes",
        results_title = "Workspace notes",
        sorting_strategy = "ascending",
        previewer = opts.previewer ~= false and config.grep_previewer(opts) or false,
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
    notes.scan(root, categories, function()
        return not picker.closed and vim.api.nvim_buf_is_valid(picker.prompt_bufnr)
    end, function(results)
        snapshot = results
        picker:refresh()
    end)
    return picker
end

return M
