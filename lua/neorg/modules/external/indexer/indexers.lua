--- Definitions shared by index generation and index-backed search.
--- Each indexer maps a note's metadata to hierarchical bucket paths.
local M = {}

--- Default note title formatter.
--- @param meta table normalized metadata of the note
--- @return string formatted title
function M.default_title_formatter(meta)
    return meta.title
end

--- Default options of each indexer. Every indexer is enabled unless `enabled` is `false`.
M.defaults = {
    categories = {
        enabled = true,
        dir = "index/categories",
        fallback = "Uncategorized",
        subcategory_separator = "/",
        per_subcategory_index = true,
        list_subcategory_notes = false,
        sort_by = "alphabetical",
        sort_direction = "ascending",
        title_formatter = M.default_title_formatter,
    },
    authors = {
        enabled = true,
        dir = "index/authors",
        fallback = "Unknown",
        per_author_index = true,
        sort_by = "alphabetical",
        sort_direction = "ascending",
        title_formatter = M.default_title_formatter,
    },
    created = {
        enabled = true,
        dir = "index/created",
        fallback = "Unknown",
        granularity = "day",
        per_period_index = true,
        list_subperiod_notes = false,
        sort_by = "created",
        sort_direction = "descending",
        title_formatter = M.default_title_formatter,
    },
    updated = {
        enabled = true,
        dir = "index/updated",
        fallback = "Unknown",
        granularity = "day",
        per_period_index = true,
        list_subperiod_notes = false,
        sort_by = "updated",
        sort_direction = "descending",
        title_formatter = M.default_title_formatter,
    },
}

--- Merge an indexer's configured options over its defaults.
--- A missing configuration yields the defaults, so the indexer is enabled; `false` disables it.
--- @param key string indexer key
--- @param cfg any configured options
--- @return table
function M.resolve_config(key, cfg)
    local defaults = vim.deepcopy(M.defaults[key] or {})
    if cfg == false then
        defaults.enabled = false
        return defaults
    end
    if type(cfg) ~= "table" then
        return defaults
    end
    return vim.tbl_deep_extend("force", defaults, cfg)
end

--- Normalize a metadata value into a list of non-empty strings.
--- @param value any metadata value (string, number, list, or nil)
--- @return string[]
function M.list_values(value)
    if value == nil or value == vim.NIL then
        return {}
    end
    if type(value) ~= "table" then
        value = { value }
    end
    local result = {}
    for _, item in ipairs(value) do
        if item ~= vim.NIL and type(item) ~= "table" then
            item = vim.trim(tostring(item))
            if item ~= "" then
                result[#result + 1] = item
            end
        end
    end
    return result
end

--- Split a value into non-empty parts.
--- @param value string
--- @param separator string
--- @return string[]
local function split_parts(value, separator)
    local parts = {}
    for _, part in ipairs(vim.split(value, separator, { plain = true })) do
        if part ~= "" then
            parts[#parts + 1] = part
        end
    end
    return parts
end

local depths = { year = 1, month = 2, day = 3 }

--- Whether a granularity option is valid.
--- @param granularity any
--- @return boolean
function M.valid_granularity(granularity)
    return depths[granularity] ~= nil
end

--- Parse a 1- or 2-digit date component after a separator, range-checked and zero-padded.
--- @param rest string text following the previous component
--- @param max integer largest valid value
--- @return string|nil part zero-padded component, nil when absent
--- @return string|boolean rest text after the component, or false when the component is invalid
local function date_component(rest, max)
    local digits, after = rest:match("^[-/](%d%d?)(.*)$")
    if not digits then
        return nil, rest
    end
    local number = tonumber(digits)
    -- A component must end at a non-digit boundary.
    if after:match("^%d") or number < 1 or number > max then
        return nil, false
    end
    return string.format("%02d", number), after
end

--- Parse a timestamp into date parts truncated to the configured granularity.
--- Accepts YYYY, YYYY-M[M], and YYYY-M[M]-D[D] with "-" or "/" separators, followed by
--- anything that does not start with a digit (e.g. a time of day).
--- @param value any metadata value
--- @param granularity string "year", "month", or "day"
--- @return string[][] a list with at most one path
local function date_values(value, granularity)
    local item = M.list_values(value)[1]
    if not item then
        return {}
    end
    local year, rest = item:match("^(%d%d%d%d)(.*)$")
    if not year or rest:match("^%d") then
        return {}
    end
    local parts = { year }
    local month, day
    month, rest = date_component(rest, 12)
    if rest == false then
        return {}
    end
    if month then
        parts[2] = month
        day, rest = date_component(rest, 31)
        if rest == false then
            return {}
        end
        parts[3] = day
    end
    return { vim.list_slice(parts, 1, depths[granularity] or 3) }
end

local function last(labels)
    return labels[#labels]
end

local function date_indexer(key, title)
    return {
        key = key,
        title = title,
        per_file = "per_period_index",
        list_notes = "list_subperiod_notes",
        values = function(metadata, config)
            return date_values(metadata[key], config.granularity)
        end,
        label = function(path_parts)
            return table.concat(path_parts, "-")
        end,
        inline_value = last,
        file_value = function(path_parts)
            return table.concat(path_parts, "-")
        end,
        ancestor_separator = function()
            return "-"
        end,
    }
end

--- Indexer definitions, in index.norg section order.
--- - values(metadata, config): list of bucket paths (each a list of raw parts)
--- - label(path_parts, config): display name of the bucket at path_parts
--- - inline_value(labels, config): searchable value from the inline heading labels along a path
--- - file_value(path_parts, heading, config): searchable value of a bucket file, from its decoded path
---   parts under the indexer directory and its first heading (unescaped)
--- - ancestor_separator(config): separator between a value and its descendants, if hierarchical
M.list = {
    {
        key = "categories",
        title = "Categories",
        per_file = "per_subcategory_index",
        list_notes = "list_subcategory_notes",
        values = function(metadata, config)
            local result = {}
            for _, value in ipairs(M.list_values(metadata.categories)) do
                local parts = split_parts(value, config.subcategory_separator)
                if #parts > 0 then
                    result[#result + 1] = parts
                end
            end
            return result
        end,
        label = last,
        inline_value = function(labels, config)
            return table.concat(labels, config.subcategory_separator)
        end,
        file_value = function(path_parts, _, config)
            return table.concat(path_parts, config.subcategory_separator)
        end,
        ancestor_separator = function(config)
            return config.subcategory_separator
        end,
    },
    {
        key = "authors",
        title = "Authors",
        per_file = "per_author_index",
        values = function(metadata)
            local values = metadata.authors
            if values == nil or values == vim.NIL then
                values = metadata.author
            end
            return vim.tbl_map(function(name)
                return { name }
            end, M.list_values(values))
        end,
        label = last,
        inline_value = last,
        file_value = function(_, heading)
            return heading
        end,
        ancestor_separator = function()
            return nil
        end,
    },
    date_indexer("created", "Created"),
    date_indexer("updated", "Updated"),
}

--- Name of the marker file that identifies a directory generated by the indexer.
M.marker = ".neorg-indexer"

-- Characters encoded anywhere in a file name part. "=" is the escape character itself and "~"
-- introduces collision suffixes. "%", "&", "$", and "`" are encoded because the Norg parser does
-- not accept them inside link locations.
local encoded_chars = '[=~%%&$`/\\:%[%]{}*?"<>|%c]'

local function encode_byte(char)
    return string.format("=%02X", char:byte())
end

--- Encode a raw bucket path part as a file or directory name.
--- The encoding is injective and keeps ordinary names readable: special characters become
--- "=XX" (uppercase hexadecimal byte value), as do a leading ".", "(", ")", or space.
--- @param part string
--- @return string
function M.encode_part(part)
    local encoded = part:gsub(encoded_chars, encode_byte)
    return (encoded:gsub("^[.() ]", encode_byte))
end

--- Decode a file or directory name produced by encode_part, dropping any collision suffix.
--- @param name string
--- @return string
function M.decode_part(name)
    name = name:gsub("~%d+$", "")
    return (name:gsub("=(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

--- Case-fold a name for comparisons on case-insensitive file systems.
--- Uses only Lua string functions so that it is safe in libuv callbacks.
--- @param name string
--- @return string
function M.fold_case(name)
    return name:lower()
end

--- Normalize an indexer directory option.
--- @param dir any configured `dir`
--- @return string|nil normalized path relative to the workspace root
--- @return string|nil error why the directory is invalid
function M.normalize_dir(dir)
    if type(dir) ~= "string" or vim.trim(dir) == "" then
        return nil, "must be a non-empty relative path"
    end
    if dir:match("^[/\\~$]") or dir:match("^%a:") then
        return nil, "must be relative to the workspace root"
    end
    local normalized = vim.fs.normalize(dir)
    if normalized == "" or normalized == "." or normalized == ".." or vim.startswith(normalized, "../") then
        return nil, "must be strictly inside the workspace"
    end
    if normalized:match("^/") then
        return nil, "must be relative to the workspace root"
    end
    return normalized
end

--- Whether one workspace-relative path equals or contains another, ignoring case.
local function overlaps(a, b)
    a, b = M.fold_case(a), M.fold_case(b)
    return a == b or vim.startswith(b, a .. "/") or vim.startswith(a, b .. "/")
end

--- Return all configured indexers with their validated directories.
--- Enabled indexers must have a directory strictly inside the workspace that does not overlap
--- another enabled indexer's directory or the main index file.
--- @param config table external.indexer public configuration
--- @return table[] list of { def, config, enabled, dir, error, warning, per_file, list_notes }
function M.configured(config)
    local index_rel = vim.fs.normalize(config.name or "")
    local result = {}
    for _, def in ipairs(M.list) do
        local cfg = M.resolve_config(def.key, config[def.key])
        do
            local dir, err = M.normalize_dir(cfg.dir)
            local ix = {
                def = def,
                config = cfg,
                enabled = cfg.enabled ~= false,
                dir = dir,
                error = err and ("`" .. def.key .. ".dir` " .. err .. ": " .. vim.inspect(cfg.dir)),
                per_file = cfg[def.per_file] and true or false,
                list_notes = def.list_notes ~= nil and cfg[def.list_notes] == true,
            }
            if ix.enabled and dir and overlaps(dir, index_rel) then
                ix.error = "`" .. def.key .. ".dir` must not contain the main index file: " .. vim.inspect(cfg.dir)
            end
            if cfg.granularity ~= nil and not M.valid_granularity(cfg.granularity) then
                ix.warning = "`"
                    .. def.key
                    .. ".granularity` must be \"year\", \"month\", or \"day\"; using \"day\" instead of "
                    .. vim.inspect(cfg.granularity)
            end
            result[#result + 1] = ix
        end
    end
    for _, ix in ipairs(result) do
        if ix.enabled and ix.dir then
            for _, other in ipairs(result) do
                if other ~= ix and other.enabled and other.dir and overlaps(ix.dir, other.dir) then
                    ix.error = ix.error
                        or (
                            "`"
                            .. ix.def.key
                            .. ".dir` must not equal, contain, or be inside `"
                            .. other.def.key
                            .. ".dir`: "
                            .. vim.inspect(ix.config.dir)
                        )
                end
            end
        end
    end
    return result
end

--- Return the enabled indexers whose directories are valid.
--- @param config table external.indexer public configuration
--- @return table[] list of { def, config, enabled, dir, per_file, list_notes }
function M.enabled(config)
    return vim.tbl_filter(function(ix)
        return ix.enabled and not ix.error
    end, M.configured(config))
end

--- Whether an absolute directory contains the indexer marker file.
--- Uses only libuv so that it is safe in libuv callbacks.
--- @param dir_abs string
--- @return boolean
function M.has_marker(dir_abs)
    local stat = vim.uv.fs_stat(dir_abs .. "/" .. M.marker)
    return stat ~= nil and stat.type == "file"
end

--- Workspace-relative directories of configured indexers, enabled or not, that contain the
--- marker file and therefore hold generated files.
--- @param config table external.indexer public configuration
--- @param root string normalized workspace root
--- @return string[]
function M.marked_dirs(config, root)
    local result = {}
    for _, ix in ipairs(M.configured(config)) do
        if ix.dir and M.has_marker(root .. "/" .. ix.dir) and not vim.tbl_contains(result, ix.dir) then
            result[#result + 1] = ix.dir
        end
    end
    return result
end

return M
