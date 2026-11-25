local M = {}

--- Create a searchable text object.
--- @param value string
--- @return table { value = string, lower = string|nil }
local function text(value)
    -- ASCII can use the cheaper literal search. Keep the original for display and
    -- for byte-accurate case-insensitive matching of non-ASCII text.
    return { value = value, lower = not value:find("[\128-\255]") and value:lower() or nil }
end

M.text = text

-- @document.meta is parsed only for the title and to keep it out of the body.
-- Searchable metadata comes from the generated indexes (see search_index.lua).
function M.parse(path, relative, source)
    local metadata, body = {}, {}
    local tag, containers, items
    local lnum = 0

    local function add_body_line(line)
        if line ~= "" then
            local body_line = text(line)
            body_line.lnum = lnum
            body[#body + 1] = body_line
        end
    end

    for line in (source .. "\n"):gmatch("([^\n]*)\n") do
        lnum = lnum + 1
        line = line:gsub("\r$", "")
        local tag_name = line:match("^%s*@([^%s]+)")
        if tag and line:match("^%s*@end%s*$") then
            if tag ~= "document.meta" then
                add_body_line(line)
            end
            tag = nil
        elseif tag == "document.meta" then
            local trimmed = vim.trim(line)
            if #containers > 0 then
                if trimmed == containers[#containers] then
                    containers[#containers] = nil
                elseif trimmed == "[" or trimmed == "{" then
                    containers[#containers + 1] = trimmed == "[" and "]" or "}"
                elseif #containers == 1 and items and trimmed ~= "" then
                    items[#items + 1] = text(trimmed)
                elseif not items then
                    local opener = trimmed:match("^[^%s:]+:%s+([%[{])$")
                    if opener then
                        containers[#containers + 1] = opener == "[" and "]" or "}"
                    end
                end
            else
                local key, value = trimmed:match("^([^%s:]+):%s*(.*)$")
                if key then
                    key = vim.fn.tolower(key)
                    if value == "[" or value == "{" then
                        containers[1] = value == "[" and "]" or "}"
                        items = value == "[" and {} or nil
                        metadata[key] = items
                    elseif value:match("^%[%s*%]$") or value:match("^{%s*}$") then
                        metadata[key] = nil
                    elseif value:sub(1, 1) == "[" and value:sub(-1) == "]" then
                        local item = vim.trim(value:sub(2, -2))
                        metadata[key] = { text(item) }
                    else
                        metadata[key] = value ~= "" and { text(value) } or nil
                    end
                end
            end
        elseif not tag and tag_name == "document.meta" then
            tag, containers, items = tag_name, {}, nil
        else
            add_body_line(line)
            if not tag and tag_name ~= "end" then
                tag = tag_name
            end
        end
    end

    local stem = relative:match("([^/]+)$"):sub(1, -6)
    local title = metadata.title and metadata.title[1] or text(stem)
    return { path = path, relative = relative, title = title, body = body, metadata = {} }
end

-- Yield between batches, including during traversal. Never follow directory or
-- file symlinks: a search should not walk out of the chosen workspace.
-- `excluded` lists workspace-relative files and directories to skip (excluded
-- directories are not traversed). `metadata` maps a note's relative path to its
-- index-derived metadata.
function M.scan(root, excluded, active, done, metadata)
    local notes = {}
    local skip = {}
    for _, path in ipairs(excluded or {}) do
        -- Join before normalizing so dot segments in the config are workspace-relative.
        skip[vim.fs.normalize(root .. "/" .. path)] = true
    end
    local dirs = skip[vim.fs.normalize(root)] and {} or { { path = root, relative = "" } }
    local dir, handle

    local function step()
        local start = vim.uv.hrtime()
        while active() do
            if not handle then
                dir = table.remove(dirs)
                if not dir then
                    table.sort(notes, function(a, b)
                        return a.relative < b.relative
                    end)
                    done(notes)
                    return
                end
                handle = vim.uv.fs_scandir(dir.path)
            end

            local name, kind
            if handle then
                name, kind = vim.uv.fs_scandir_next(handle)
            end
            if not name then
                handle = nil
            else
                local relative = dir.relative .. name
                local path = vim.fs.joinpath(root, relative)
                if kind == "directory" and not skip[path] then
                    dirs[#dirs + 1] = { path = path, relative = relative .. "/" }
                elseif kind == "file" and name:sub(-5) == ".norg" and not skip[path] then
                    local file = io.open(path, "rb")
                    if file then
                        local source = file:read("*a")
                        file:close()
                        if source then
                            local note = M.parse(path, relative, source)
                            note.metadata = metadata and metadata[relative] or {}
                            notes[#notes + 1] = note
                        end
                    end
                end
            end

            if vim.uv.hrtime() - start >= 6e6 then
                vim.schedule(step)
                return
            end
        end
    end

    vim.schedule(step)
end

return M
