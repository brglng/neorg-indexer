--- BibTeX literature support: parse `.bib` files with the tree-sitter-bibtex grammar and project
--- their first entry onto the normalized metadata used for notes.
local M = {}

M.lang = "bibtex"

local availability = nil
local warned = false

--- Whether the bibtex tree-sitter parser can be loaded. Besides the runtimepath (where lazy.nvim
--- puts the parser of the `tree-sitter-bibtex` rock), the parsers of lazy.nvim's rocks are tried.
--- @return boolean
function M.available()
    if availability ~= nil then
        return availability
    end
    local ok, loaded = pcall(vim.treesitter.language.add, M.lang)
    if not ok or not loaded then
        local pattern = vim.fn.stdpath("data") .. "/lazy-rocks/*/lib/lua/5.1/parser/" .. M.lang .. ".so"
        for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
            ok, loaded = pcall(vim.treesitter.language.add, M.lang, { path = path })
            if ok and loaded then
                break
            end
        end
    end
    availability = ok and loaded and true or false
    return availability
end

--- Report a missing parser once per session.
--- @param notify fun(message: string, level: integer)|nil defaults to vim.notify
function M.warn_unavailable(notify)
    if warned then
        return
    end
    warned = true
    (notify or vim.notify)(
        "external.indexer: the tree-sitter parser for BibTeX (`bibtex`) is not installed; .bib files are skipped. "
            .. "Install the `tree-sitter-bibtex` rock (installed by lazy.nvim from the plugin's rockspec) "
            .. "or run `:TSInstall bibtex`.",
        vim.log.levels.ERROR
    )
end

local month_names = {
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
}

local month_macros = {}
for i, name in ipairs(month_names) do
    month_macros[name:sub(1, 3):lower()] = name
end

-- Fields whose values are not LaTeX text.
local verbatim = { url = true, doi = true, file = true, eprint = true, pdf = true }

-- Precomposed characters for LaTeX accent commands.
local accents = {
    ['"'] = {
        a = "ä",
        e = "ë",
        i = "ï",
        o = "ö",
        u = "ü",
        y = "ÿ",
        A = "Ä",
        E = "Ë",
        I = "Ï",
        O = "Ö",
        U = "Ü",
        Y = "Ÿ",
    },
    ["'"] = {
        a = "á",
        e = "é",
        i = "í",
        o = "ó",
        u = "ú",
        y = "ý",
        c = "ć",
        n = "ń",
        s = "ś",
        z = "ź",
        A = "Á",
        E = "É",
        I = "Í",
        O = "Ó",
        U = "Ú",
        Y = "Ý",
        C = "Ć",
        N = "Ń",
        S = "Ś",
        Z = "Ź",
    },
    ["`"] = { a = "à", e = "è", i = "ì", o = "ò", u = "ù", A = "À", E = "È", I = "Ì", O = "Ò", U = "Ù" },
    ["^"] = { a = "â", e = "ê", i = "î", o = "ô", u = "û", A = "Â", E = "Ê", I = "Î", O = "Ô", U = "Û" },
    ["~"] = { a = "ã", n = "ñ", o = "õ", A = "Ã", N = "Ñ", O = "Õ" },
    ["="] = { a = "ā", e = "ē", i = "ī", o = "ō", u = "ū", A = "Ā", E = "Ē", I = "Ī", O = "Ō", U = "Ū" },
    ["."] = { e = "ė", z = "ż", E = "Ė", Z = "Ż" },
    c = { c = "ç", s = "ş", C = "Ç", S = "Ş" },
    v = {
        c = "č",
        e = "ě",
        n = "ň",
        r = "ř",
        s = "š",
        z = "ž",
        C = "Č",
        E = "Ě",
        N = "Ň",
        R = "Ř",
        S = "Š",
        Z = "Ž",
    },
    u = { a = "ă", g = "ğ", A = "Ă", G = "Ğ" },
    H = { o = "ő", u = "ű", O = "Ő", U = "Ű" },
    r = { a = "å", u = "ů", A = "Å", U = "Ů" },
    k = { a = "ą", e = "ę", A = "Ą", E = "Ę" },
}

-- Commands that produce a character.
local symbols = {
    ss = "ß",
    o = "ø",
    O = "Ø",
    aa = "å",
    AA = "Å",
    ae = "æ",
    AE = "Æ",
    oe = "œ",
    OE = "Œ",
    l = "ł",
    L = "Ł",
    i = "ı",
    j = "ȷ",
    textendash = "–",
    textemdash = "—",
    textquoteright = "’",
    textquoteleft = "‘",
    LaTeX = "LaTeX",
    TeX = "TeX",
}

local function accent(command, base)
    base = base:gsub("^\\", "")
    local map = accents[command]
    return map and map[base] or base
end

--- Convert a LaTeX field value to plain text, best-effort.
--- @param value string field value with grouping braces
--- @param plain boolean|nil true for verbatim fields: only braces and whitespace are processed
--- @return string
function M.clean(value, plain)
    local text = value
    if not plain then
        -- Escaped braces survive the removal of grouping braces.
        text = text:gsub("\\([{}&%%$#_])", function(char)
            return char == "{" and "\1" or char == "}" and "\2" or char
        end)
        text = text:gsub("\\([\"'`%^~=%.])%s*{%s*(\\?%a)%s*}", accent)
        text = text:gsub("\\([\"'`%^~=%.])%s*(\\?%a)", accent)
        text = text:gsub("\\([cvuHrkdb])%s*{%s*(\\?%a)%s*}", accent)
        text = text:gsub("\\([cvuHrkdb])%s+(\\?%a)%f[%A]", accent)
        text = text:gsub("\\(%a+)%s*", function(name)
            return symbols[name] or ""
        end)
        text = text:gsub("\\[,;!:%s]", " "):gsub("\\\\", " "):gsub("\\", "")
        text = text:gsub("~", " "):gsub("%-%-%-", "—"):gsub("%-%-", "–")
    end
    text = text:gsub("[{}]", ""):gsub("\1", "{"):gsub("\2", "}")
    return vim.trim((text:gsub("%s+", " ")))
end

--- Text of a value node: tokens joined with `#` concatenation, outer delimiters removed, and macros
--- expanded. Grouping braces inside the value are kept.
local function value_text(node, source, macros)
    local parts = {}
    for token in node:iter_children() do
        if token:named() and token:type() == "token" then
            local text = vim.treesitter.get_node_text(token, source)
            local first = text:sub(1, 1)
            if first == "{" or first == '"' then
                parts[#parts + 1] = text:sub(2, -2)
            elseif text:match("^%d+$") then
                parts[#parts + 1] = text
            else
                local name = text:lower()
                parts[#parts + 1] = macros[name] or month_macros[name] or text
            end
        end
    end
    return table.concat(parts)
end

--- Parse the entries of a BibTeX source. `@string` macros are expanded; `@comment`, `@preamble`,
--- and `@string` are not entries.
--- @param source string
--- @return table[]|nil entries { type, key, fields = { [name] = text }, raw = { [name] = value } }
--- @return string|nil error
function M.parse(source)
    if not M.available() then
        return nil, "bibtex parser unavailable"
    end
    local ok, parser = pcall(vim.treesitter.get_string_parser, source, M.lang)
    if not ok then
        return nil, tostring(parser)
    end
    local tree = parser:parse()[1]
    local entries, macros = {}, {}
    for node in tree:root():iter_children() do
        local kind = node:type()
        if kind == "string" then
            local name, value = node:field("name")[1], node:field("value")[1]
            if name and value then
                macros[vim.treesitter.get_node_text(name, source):lower()] = value_text(value, source, macros)
            end
        elseif kind == "entry" then
            local ty, key = node:field("ty")[1], node:field("key")[1]
            local entry_type = ty and vim.treesitter.get_node_text(ty, source):gsub("^@", ""):lower()
            if
                key
                and entry_type
                and entry_type ~= "comment"
                and entry_type ~= "preamble"
                and entry_type ~= "string"
            then
                local entry = {
                    type = entry_type,
                    key = vim.trim(vim.treesitter.get_node_text(key, source)),
                    fields = {},
                    raw = {},
                    lnum = node:start() + 1,
                }
                for _, field in ipairs(node:field("field")) do
                    local name, value = field:field("name")[1], field:field("value")[1]
                    if name and value then
                        name = vim.treesitter.get_node_text(name, source):lower()
                        local raw = value_text(value, source, macros)
                        entry.raw[name] = raw
                        entry.fields[name] = M.clean(raw, verbatim[name])
                    end
                end
                entries[#entries + 1] = entry
            end
        end
    end
    return entries
end

--- Split a value on a separator pattern at brace depth 0.
local function split_top(value, separator)
    local parts, depth, start, i = {}, 0, 1, 1
    while i <= #value do
        local char = value:sub(i, i)
        if char == "{" then
            depth = depth + 1
        elseif char == "}" then
            depth = math.max(depth - 1, 0)
        elseif depth == 0 then
            local first, last = value:find(separator, i)
            if first == i then
                parts[#parts + 1] = value:sub(start, i - 1)
                start = last + 1
                i = last
            end
        end
        i = i + 1
    end
    parts[#parts + 1] = value:sub(start)
    return parts
end

--- Split a BibTeX name list into display names ("Last, First" becomes "First Last"). "others"
--- is dropped.
--- @param raw string field value with grouping braces
--- @return string[]
function M.split_names(raw)
    local names = {}
    for _, name in ipairs(split_top(raw, "%s+[aA][nN][dD]%s+")) do
        name = vim.trim(name)
        if name ~= "" and name:lower() ~= "others" then
            local parts = vim.tbl_map(M.clean, split_top(name, "%s*,%s*"))
            local result
            if #parts == 2 then
                result = parts[2] .. " " .. parts[1]
            elseif #parts >= 3 then
                -- "von Last, Jr, First"
                result = parts[3] .. " " .. parts[1] .. " " .. parts[2]
            else
                result = parts[1]
            end
            result = vim.trim((result:gsub("%s+", " ")))
            if result ~= "" then
                names[#names + 1] = result
            end
        end
    end
    return names
end

--- Month number from a numeric or named month.
local function month_number(value)
    local number = tonumber(value)
    if number then
        return number >= 1 and number <= 12 and math.floor(number) or nil
    end
    local prefix = value:sub(1, 3):lower()
    for i, name in ipairs(month_names) do
        if name:sub(1, 3):lower() == prefix then
            return i
        end
    end
    return nil
end

--- Date of an entry: the `date` field, otherwise `year` and `month`.
--- @param fields table cleaned fields
--- @return string|nil date as YYYY, YYYY-MM, or YYYY-MM-DD
function M.date(fields)
    local date = fields.date and fields.date:match("^%d%d%d%d[-%d]*")
    if date then
        -- Drop a trailing separator and the end of a range.
        return (date:gsub("%-+$", ""))
    end
    local year = fields.year and fields.year:match("%d%d%d%d")
    if not year then
        return nil
    end
    local month = fields.month and month_number(vim.trim(fields.month))
    return month and string.format("%s-%02d", year, month) or year
end

--- Split a `keywords` field on "," or ";". Keywords are trimmed, empty ones are dropped, and
--- duplicates (compared case-sensitively) are removed, keeping the first occurrence.
--- @param value string|nil cleaned field value
--- @return string[]
function M.split_keywords(value)
    local result, seen = {}, {}
    for _, keyword in ipairs(vim.split(value or "", "[,;]")) do
        keyword = vim.trim(keyword)
        if keyword ~= "" and not seen[keyword] then
            seen[keyword] = true
            result[#result + 1] = keyword
        end
    end
    return result
end

--- Project an entry onto the normalized note metadata. All raw fields are kept under `bibtex`;
--- `keywords` and the other fields indexed by the `bibtex.*` indexers are not projected.
--- @param entry table parsed entry
--- @return table metadata
function M.project(entry)
    local fields = entry.fields
    local names = entry.raw.author and M.split_names(entry.raw.author) or {}
    if #names == 0 and entry.raw.editor then
        names = M.split_names(entry.raw.editor)
    end
    local date = M.date(fields)
    local title = fields.title ~= "" and fields.title or nil
    return {
        kind = "literature",
        title = title or entry.key,
        authors = #names > 0 and names or nil,
        description = fields.abstract,
        created = date,
        updated = date,
        citekey = entry.key,
        bibtex = { type = entry.type, key = entry.key, fields = vim.deepcopy(fields) },
    }
end

local function is_file(path)
    local stat = vim.uv.fs_stat(path)
    return stat ~= nil and stat.type == "file"
end

--- Split a `file` field into items: ";" separates files and "\\;", "\\:", and "\\\\" are JabRef
--- escapes. Each item is the list of its ":"-separated parts, unescaped.
--- @param value string
--- @return string[][]
local function file_items(value)
    -- Protect escaped characters: "\1" is "\", "\2" is ":", and "\3" is ";".
    value = value:gsub("\\\\", "\1"):gsub("\\:", "\2"):gsub("\\;", "\3")
    local items = {}
    for _, item in ipairs(vim.split(value, ";", { plain = true })) do
        local parts = vim.tbl_map(function(part)
            return (part:gsub("\1", "\\"):gsub("\2", ":"):gsub("\3", ";"))
        end, vim.split(item, ":", { plain = true }))
        items[#items + 1] = parts
    end
    return items
end

--- Absolute path of a path from a `file` field: absolute, "~"-prefixed, or relative to `dir`.
local function resolve_file(path, dir)
    if path:sub(1, 1) == "~" then
        return vim.fs.normalize(path)
    elseif path:match("^[/\\]") or path:match("^%a:[/\\]") then
        return vim.fs.normalize(path)
    end
    return vim.fs.normalize(dir .. "/" .. path)
end

--- Candidate PDF paths of a literature, from its `file` field, in order: a plain path, files
--- separated by ";", and JabRef/Zotero `Description:path:Type` items (the path may contain an
--- unescaped Windows drive letter such as `C:\`). Only paths with a `.pdf` extension (any case)
--- are candidates; they need not exist.
--- @param bib_path string absolute path of the .bib file
--- @param fields table|nil cleaned fields
--- @return string[] absolute paths
function M.pdf_candidates(bib_path, fields)
    local value = fields and fields.file
    if type(value) ~= "string" or vim.trim(value) == "" then
        return {}
    end
    local dir = vim.fs.dirname(bib_path)
    local result, seen = {}, {}
    local function add(path)
        path = vim.trim(path)
        if path ~= "" and path:lower():match("%.pdf$") then
            path = resolve_file(path, dir)
            if not seen[path] then
                seen[path] = true
                result[#result + 1] = path
            end
        end
    end
    for _, parts in ipairs(file_items(value)) do
        if #parts >= 3 then
            -- "Description:path:Type"; the path keeps any unescaped ":" (a drive letter).
            add(table.concat(parts, ":", 2, #parts - 1))
        elseif #parts == 2 and not parts[1]:match("^%a$") then
            -- "Description:path" without a type.
            add(parts[2])
        end
        add(table.concat(parts, ":"))
    end
    return result
end

--- PDF of a literature: the first candidate from the `file` field that exists.
--- @param bib_path string absolute path of the .bib file
--- @param fields table|nil cleaned fields
--- @return string|nil absolute path
function M.find_pdf(bib_path, fields)
    for _, path in ipairs(M.pdf_candidates(bib_path, fields)) do
        if is_file(path) then
            return path
        end
    end
    return nil
end

--- Read a literature item from a .bib source: its first entry.
--- @param source string
--- @param bib_path string absolute path of the .bib file
--- @return table|nil item { citekey, metadata, entry, pdf, pdf_candidates, extra } where extra counts
--- ignored entries
--- @return string|nil error
function M.read(source, bib_path)
    local entries, err = M.parse(source)
    if not entries then
        return nil, err
    end
    local entry = entries[1]
    if not entry then
        return nil, "no entry"
    end
    return {
        citekey = entry.key,
        entry = entry,
        metadata = M.project(entry),
        pdf = M.find_pdf(bib_path, entry.fields),
        pdf_candidates = M.pdf_candidates(bib_path, entry.fields),
        extra = #entries - 1,
    }
end

return M
