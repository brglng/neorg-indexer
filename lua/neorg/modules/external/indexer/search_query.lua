local M = {}

local aliases = {
    author = { "author", "authors" },
    authors = { "authors", "author" },
    category = { "category", "categories" },
    categories = { "categories", "category" },
}

local function valid_date(value)
    local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not year then
        return false
    end
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    local leap = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
    local days = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    return days[month] and day >= 1 and day <= days[month]
end

local function date_filter(field, value)
    if field == "year" and value:match("^%d%d%d%d$") then
        return "created", value, 1
    elseif field == "month" then
        local year, month = value:match("^(%d%d%d%d)%-(%d%d)$")
        if year and valid_date(value .. "-01") then
            return "created", value, 1
        elseif not month and value:match("^%d%d?$") and tonumber(value) >= 1 and tonumber(value) <= 12 then
            return "created", string.format("%02d", tonumber(value)), 6
        end
    elseif field == "date" and valid_date(value) then
        return "created", value, 1
    end
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

            local term = { field = key, value = value, excluded = excluded }
            if key == "year" or key == "month" or key == "date" then
                term.field, term.value, term.date_start = date_filter(key, value)
                if not term.field then
                    return nil
                end
            else
                term.lower = value:lower()
            end
            group[#group + 1] = term
        end
    end
    if #group == 0 then
        return nil
    end
    groups[#groups + 1] = group
    return groups
end

local function find(text, term)
    if term.date_start then
        local date, suffix = text.value:match("^(%d%d%d%d%-%d%d%-%d%d)(.*)$")
        if date and valid_date(date) and (suffix == "" or suffix:match("^[Tt ]%d%d:%d%d")) then
            local first = term.date_start
            local last = first + #term.value - 1
            if date:sub(first, last) == term.value then
                return first, last
            end
        end
    elseif text.lower then
        return text.lower:find(term.lower, 1, true)
    else
        if term.regex == nil then
            local ok, regex = pcall(vim.regex, "\\c\\V" .. term.value:gsub("\\", "\\\\"))
            term.regex = ok and regex or false
        end
        if not term.regex then
            return
        end
        local first, last = term.regex:match_str(text.value)
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
