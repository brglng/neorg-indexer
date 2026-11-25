local M = {}

local aliases = {
    author = { "author", "authors" },
    authors = { "authors", "author" },
    category = { "category", "categories" },
    categories = { "categories", "category" },
}

local function normalize_date_separators(value)
    return (value:gsub("(%d)/%f[%d]", "%1-"))
end

function M.parse(prompt)
    local groups, group = {}, {}
    local i = 1
    while i <= #prompt do
        local char = prompt:sub(i, i)
        if char:match("%s") then
            i = i + 1
        elseif char == "|" then
            if #group == 0 then
                return nil
            end
            groups[#groups + 1], group = group, {}
            i = i + 1
        else
            local excluded = char == "-"
            if excluded then
                i = i + 1
            end
            local _, key_end, key = prompt:find("^([^%s:|\"]+):", i)
            if key then
                i = key_end + 1
                key = vim.fn.tolower(key)
            end

            local value
            if prompt:sub(i, i) == "\"" then
                local parts = {}
                i = i + 1
                while i <= #prompt and prompt:sub(i, i) ~= "\"" do
                    local current, following = prompt:sub(i, i), prompt:sub(i + 1, i + 1)
                    if current == "\\" and (following == "\"" or following == "\\") then
                        current = following
                        i = i + 1
                    end
                    parts[#parts + 1] = current
                    i = i + 1
                end
                if i > #prompt or prompt:sub(i + 1, i + 1):match("[^%s|]") then
                    return nil
                end
                value = table.concat(parts)
                i = i + 1
            else
                local _, last, word = prompt:find("^([^%s|\"]+)", i)
                if not word or prompt:sub(last + 1, last + 1) == "\"" then
                    return nil
                end
                value, i = word, last + 1
            end
            if not value:find("%S") then
                return nil
            end

            local timestamp = key == "created" or key == "updated"
            if timestamp then
                value = normalize_date_separators(value)
            end
            group[#group + 1] = {
                field = key,
                value = value,
                lower = value:lower(),
                excluded = excluded,
                timestamp = timestamp,
            }
        end
    end
    if #group == 0 then
        return nil
    end
    groups[#groups + 1] = group
    return groups
end

local function find(text, term)
    -- Normalization preserves byte offsets into the original metadata value.
    if text.lower then
        local lower = term.timestamp and normalize_date_separators(text.lower) or text.lower
        return lower:find(term.lower, 1, true)
    else
        if term.regex == nil then
            local ok, regex = pcall(vim.regex, "\\c\\V" .. term.value:gsub("\\", "\\\\"))
            term.regex = ok and regex or false
        end
        if not term.regex then
            return
        end
        local value = term.timestamp and normalize_date_separators(text.value) or text.value
        local first, last = term.regex:match_str(value)
        if first then
            return first + 1, last
        end
    end
end

local function hit(text, term, kind, label)
    local first, last = find(text, term)
    if first then
        return { text = text.value, first = first, last = last, kind = kind, label = label, lnum = text.lnum }
    end
end

local function match_term(note, term, search_content)
    local field = term.field
    if not field or field == "title" then
        local match = hit(note.title, term, "title")
        if match or field then
            return match and { match }
        end
    end
    if field == "content" or (not field and search_content) then
        local matches = {}
        for _, line in ipairs(note.body) do
            local match = hit(line, term, "content")
            if match then
                if term.excluded then
                    return { match }
                end
                matches[#matches + 1] = match
            end
        end
        return #matches > 0 and matches or nil
    elseif field then
        for _, key in ipairs(aliases[field] or { field }) do
            for _, text in ipairs(note.metadata[key] or {}) do
                local match = hit(text, term, "metadata", key)
                if match then
                    return { match }
                end
            end
        end
    end
end

function M.match(note, groups, search_content)
    local rows, by_line, title_hit = {}, {}, false

    local function add_row(lnum, line, context, hits)
        local key = lnum or 0
        local row = by_line[key]
        if not row then
            row = { lnum = lnum, text = line, hits = {} }
            by_line[key] = row
            rows[#rows + 1] = row
        end
        vim.list_extend(row.hits, context)
        if hits then
            vim.list_extend(row.hits, hits)
        end
    end

    for _, group in ipairs(groups) do
        local context, lines = {}, {}
        local satisfied = true
        for _, term in ipairs(group) do
            local matches = match_term(note, term, search_content)
            if (matches ~= nil) == term.excluded then
                satisfied = false
                break
            elseif matches then
                for _, match in ipairs(matches) do
                    if match.lnum then
                        local hits = lines[match.lnum] or {}
                        hits[#hits + 1] = match
                        lines[match.lnum] = hits
                    else
                        context[#context + 1] = match
                    end
                end
            end
        end
        -- AND is note-scoped. Emit the union of body lines only after the whole
        -- group matches, with the metadata associated with those lines' groups.
        if satisfied then
            for _, match in ipairs(context) do
                title_hit = title_hit or match.kind == "title"
            end
            if next(lines) then
                for lnum, hits in pairs(lines) do
                    add_row(lnum, hits[1].text, context, hits)
                end
            else
                add_row(nil, note.title.value, context)
            end
        end
    end
    if #rows > 0 then
        table.sort(rows, function(a, b)
            return (a.lnum or 0) < (b.lnum or 0)
        end)
        return rows, title_hit
    end
end

return M
