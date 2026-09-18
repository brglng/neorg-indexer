--[[
    file: module.lua
    title: Indexer Module for Neorg
    description: Index Neorg documents by category
    author: neorg-indexer
--]]

local neorg = require("neorg.core")
local modules, utils = neorg.modules, neorg.utils

local module = modules.create("external.indexer")

module.setup = function()
    return {
        success = true,
        requires = {
            "core.dirman",
            "core.esupports.metagen",
            "core.integrations.treesitter",
        },
    }
end

module.load = function()
    modules.await("core.neorgcmd", function(neorgcmd)
        neorgcmd.add_commands_from_table({
            ["indexer"] = {
                min_args = 0,
                name = "indexer.index",
            },
        })
    end)
    if module.config.public.categories.index_on_launch then
        modules.await("core.dirman", function(dirman)
            module.private.trigger_index_on_launch(dirman)
        end)
    end
    if module.config.public.categories.index_on_change then
        module.private.setup_workspace_watchers()
    end
end

module.config.public = {
    categories = {
        name = "index.norg",
        dir = "categories",
        index_on_launch = false,
        index_on_change = true,
        subcategory_separator = "/",
        per_subcategory_index = true,
        list_subcategory_notes = false,
        sort_by = "alphabetical",
        sort_direction = "ascending",
        ---@param meta table normalized metadata of the note
        ---@return string formatted title
        title_formatter = function(meta)
            return meta.title
        end,
    },
}

---@class external.indexer
module.public = {
    --- Generate the category index for a workspace.
    --- @param ws_name string|nil workspace name; defaults to the current workspace
    --- @param opts table|nil options: { changed_files = string[] }
    index = function(ws_name, opts)
        local dirman = modules.get_module("core.dirman")

        if not dirman then
            utils.notify("`core.dirman` is not loaded! It is required to generate indexes", vim.log.levels.ERROR)
            return
        end

        if type(ws_name) == "table" then
            ws_name = ws_name[1]
        end

        if not ws_name then
            ws_name = dirman.get_current_workspace()[1]
        end

        if not ws_name or ws_name == "default" then
            -- Don't generate an index for non-registered workspace (default is cwd)
            return
        end

        local ws_root = dirman.get_workspace(ws_name)
        if not ws_root then
            return
        end

        local ws_norm = vim.fs.normalize(tostring(ws_root))
        local config = module.config.public.categories
        local index_path = vim.fs.normalize(vim.fs.abspath(vim.fn.resolve(ws_norm .. "/" .. config.name)))

        opts = opts or {}
        local changed_set = nil
        if type(opts.changed_files) == "table" then
            changed_set = {}
            for _, path in ipairs(opts.changed_files) do
                local normalized = vim.fs.normalize(vim.fs.abspath(vim.fn.resolve(path)))
                changed_set[normalized] = true
            end
            if not next(changed_set) then
                changed_set = nil
            end
        end

        local cats_dir_abs = nil
        if config.per_subcategory_index then
            cats_dir_abs = vim.fs.normalize(vim.fn.resolve(ws_norm .. "/" .. config.dir))
        end

        -- Collect entries from all norg files
        local categorized, category_order, affected_categories = module.private.collect_entries(
            dirman.get_norg_files(ws_name) or {},
            ws_norm,
            index_path,
            cats_dir_abs,
            changed_set
        )

        if changed_set and config.per_subcategory_index and cats_dir_abs then
            local changed_norgnames = {}
            for path in pairs(changed_set) do
                if path ~= index_path
                    and path:match("%.norg$")
                    and not (cats_dir_abs and vim.startswith(path, cats_dir_abs .. "/")) then
                    if vim.startswith(path, ws_norm .. "/") then
                        local norgname = path:gsub("^" .. vim.pesc(ws_norm), ""):gsub("%.norg$", "")
                        table.insert(changed_norgnames, norgname)
                    end
                end
            end
            if #changed_norgnames > 0 then
                local old_categories =
                    module.private.find_categories_for_norgnames(ws_norm, cats_dir_abs, changed_norgnames)
                for cat in pairs(old_categories) do
                    affected_categories[cat] = true
                    local parts = vim.split(cat, config.subcategory_separator, { plain = true })
                    parts = vim.tbl_filter(function(p)
                        return p ~= ""
                    end, parts)
                    if #parts > 1 then
                        local acc = {}
                        for _, part in ipairs(parts) do
                            table.insert(acc, part)
                            affected_categories[table.concat(acc, config.subcategory_separator)] = true
                        end
                    end
                end
            end
        end

        local partial_update = changed_set ~= nil and next(affected_categories) ~= nil

        -- Build category tree
        local tree = module.private.build_category_tree(categorized, category_order, config.subcategory_separator)

        local write_main = true
        if config.per_subcategory_index and not config.list_subcategory_notes and partial_update then
            write_main = module.private.top_level_categories_changed(cats_dir_abs, tree.child_order)
        end

        if config.per_subcategory_index then
            -- Generate main index with links to category indexes
            local main_lines
            if write_main then
                main_lines = module.private.generate_main_index_lines(tree)
            end

            -- Generate all category file contents (relative paths -> body content)
            local category_files =
                module.private.generate_all_category_index_files(tree, partial_update and affected_categories or nil)

            local main_body
            if write_main then
                main_body = table.concat(main_lines, "\n") .. "\n"
            end

            -- Prepare content with metadata handling (BEFORE deleting categories dir)
            local files_to_write = {}

            -- Main index
            if write_main then
                local main_content = module.private.prepare_index_content(index_path, main_body, "Index")
                table.insert(files_to_write, { path = index_path, content = main_content })
            end

            -- Category indexes (read old data BEFORE directory deletion)
            local category_contents = {}
            for rel_path, body in pairs(category_files) do
                local abs_path = vim.fs.normalize(ws_norm .. "/" .. rel_path)
                local category_title = body:match("^%*+ ([^\n]+)") or vim.fn.fnamemodify(rel_path, ":t:r")
                category_contents[abs_path] = module.private.prepare_index_content(abs_path, body, category_title)
            end

            -- Now safe to delete categories directory for full rebuilds only
            if not partial_update then
                if cats_dir_abs and vim.fn.isdirectory(cats_dir_abs) == 1 then
                    vim.fn.delete(cats_dir_abs, "rf")
                end
            elseif affected_categories and next(affected_categories) ~= nil then
                module.private.delete_obsolete_category_files(ws_norm, tree, affected_categories, config.subcategory_separator)
            end

            -- Create directories and prepare file entries
            for abs_path, content in pairs(category_contents) do
                local dir = vim.fn.fnamemodify(abs_path, ":h")
                vim.fn.mkdir(dir, "p")
                table.insert(files_to_write, { path = abs_path, content = content })
            end

            -- Write all files, preferring buffer updates for open files
            local disk_writes = {}
            for _, file_info in ipairs(files_to_write) do
                local bufnr = module.private.find_open_buffer(file_info.path)
                if bufnr then
                    module.private.write_to_buffer(bufnr, file_info.content)
                else
                    table.insert(disk_writes, file_info)
                end
            end
            if #disk_writes > 0 then
                module.private.write_files_async(disk_writes, function()
                    vim.schedule(function()
                        utils.notify("Index generated at " .. index_path)
                    end)
                end)
            else
                utils.notify("Index generated at " .. index_path)
            end
        else
            -- Generate the main index with tree sub-headings
            local main_lines = vim.list_extend({ "* Index", "\n" }, module.private.generate_tree_lines(tree, 2))
            local main_body = table.concat(main_lines, "\n") .. "\n"

            local content = module.private.prepare_index_content(index_path, main_body, "Index")

            -- Write single file, preferring buffer update if open
            local bufnr = module.private.find_open_buffer(index_path)
            if bufnr then
                module.private.write_to_buffer(bufnr, content)
                utils.notify("Index generated at " .. index_path)
            else
                module.private.write_file_async(index_path, content, function(err)
                    vim.schedule(function()
                        if err then
                            utils.notify("Failed to write index file: " .. err, vim.log.levels.ERROR)
                        else
                            utils.notify("Index generated at " .. index_path)
                        end
                    end)
                end)
            end
        end
    end,
}

module.private = {
    workspace_watchers = {},
    watch_timers = {},
    pending_changes = {},
    index_on_launch_pending = false,
    watch_debounce_ms = 200,

    --- Attempt to run index_on_launch once a real workspace is available.
    --- @param dirman table|nil
    --- @return boolean triggered true when an index was scheduled
    trigger_index_on_launch = function(dirman)
        if not module.config.public.categories.index_on_launch then
            return false
        end
        dirman = dirman or module.required["core.dirman"]
        if not dirman then
            return false
        end
        local ws_name = dirman.get_current_workspace()[1]
        if not ws_name or ws_name == "default" then
            module.private.index_on_launch_pending = true
            return false
        end
        module.private.index_on_launch_pending = false
        vim.schedule(function()
            module.public.index(ws_name)
        end)
        return true
    end,

    --- Find the workspace that contains the given file path.
    --- @param filepath string normalized absolute file path
    --- @return string|nil workspace name or nil if not found
    find_workspace_for_file = function(filepath)
        local dirman = module.required["core.dirman"]
        for _, name in ipairs(dirman.get_workspace_names()) do
            local root = vim.fs.normalize(tostring(dirman.get_workspace(name)))
            if vim.startswith(filepath, root .. "/") then
                return name
            end
        end
        return nil
    end,

    --- Determine whether a path should be ignored for watcher-triggered updates.
    --- @param filename string normalized absolute file path
    --- @param ws_root string normalized workspace root
    --- @return boolean
    should_ignore_path = function(filename, ws_root)
        local config = module.config.public.categories
        local index_name = vim.fs.normalize(vim.fn.resolve(ws_root .. "/" .. config.name))
        if filename == index_name then
            return true
        end
        if config.per_subcategory_index then
            local cats_dir = vim.fs.normalize(vim.fn.resolve(ws_root .. "/" .. config.dir))
            if vim.startswith(filename, cats_dir .. "/") then
                return true
            end
        end
        return false
    end,

    --- Debounce index generation per workspace.
    --- @param ws_name string
    --- @param filename string|nil normalized absolute file path to track
    debounce_workspace_update = function(ws_name, filename)
        local timers = module.private.watch_timers
        local pending = module.private.pending_changes
        if filename then
            pending[ws_name] = pending[ws_name] or {}
            pending[ws_name][filename] = true
        end
        local timer = timers[ws_name]
        if not timer then
            timer = vim.uv.new_timer()
            if not timer then
                return
            end
            timers[ws_name] = timer
        else
            timer:stop()
        end
        timer:start(module.private.watch_debounce_ms, 0, function()
            timer:stop()
            local changed = pending[ws_name]
            pending[ws_name] = nil
            local changed_list = nil
            if changed then
                changed_list = vim.tbl_keys(changed)
            end
            vim.schedule(function()
                module.public.index(ws_name, { changed_files = changed_list })
            end)
        end)
    end,

    --- Setup filesystem watchers for all workspaces to track .norg changes.
    setup_workspace_watchers = function()
        local dirman = module.required["core.dirman"]
        if not dirman then
            return
        end

        for _, name in ipairs(dirman.get_workspace_names()) do
            local root = dirman.get_workspace(name)
            if root then
                local ws_root = vim.fs.normalize(tostring(root))
                if not module.private.workspace_watchers[name] then
                    local watcher = vim.uv.new_fs_event()
                    if watcher then
                        watcher:start(ws_root, { recursive = true }, function(err, filename, _)
                            if err then
                                vim.schedule(function()
                                    utils.notify("Watcher error for " .. ws_root .. ": " .. err, vim.log.levels.ERROR)
                                end)
                                return
                            end
                            if not filename or filename == "" then
                                return
                            end
                            local abs_path = vim.fs.normalize(vim.fs.abspath(ws_root .. "/" .. filename))
                            if not abs_path:match("%.norg$") then
                                return
                            end
                            if module.private.should_ignore_path(abs_path, ws_root) then
                                return
                            end
                            module.private.debounce_workspace_update(name, abs_path)
                        end)
                        module.private.workspace_watchers[name] = { watcher = watcher, root = ws_root }
                    end
                end
            end
        end
    end,

    --- @param bufnr number buffer number to delete
    safe_buf_delete = function(bufnr)
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end
        -- Detach all LSP clients before deleting to prevent LSP cleanup errors
        local clients = vim.lsp.get_clients({ bufnr = bufnr })
        for _, client in ipairs(clients) do
            vim.lsp.buf_detach_client(bufnr, client.id)
        end
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end,

    --- Find an open, loaded buffer for the given file path.
    --- Uses resolved paths for reliable matching (handles symlinks).
    --- @param path string absolute file path
    --- @return number|nil buffer number or nil if not found
    find_open_buffer = function(path)
        local resolved = vim.fs.normalize(vim.fn.resolve(path))
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
                local buf_name = vim.api.nvim_buf_get_name(bufnr)
                if buf_name ~= "" then
                    local buf_resolved = vim.fs.normalize(vim.fn.resolve(buf_name))
                    if buf_resolved == resolved then
                        return bufnr
                    end
                end
            end
        end
        return nil
    end,

    --- Write content to an open buffer and save it.
    --- @param bufnr number buffer number
    --- @param content string file content to write
    write_to_buffer = function(bufnr, content)
        local lines = vim.split(content, "\n", { plain = true })
        -- Remove trailing empty string from split when content ends with \n
        if #lines > 0 and lines[#lines] == "" then
            table.remove(lines)
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("silent write")
        end)
    end,

    --- Read entire file contents using vim.uv (synchronous).
    --- @param path string absolute file path
    --- @return string|nil file contents or nil on error
    read_file_contents = function(path)
        local stat = vim.uv.fs_stat(path)
        if not stat then
            return nil
        end
        -- 438 is octal 0666 (rw-rw-rw-), the standard permission for files
        local fd = vim.uv.fs_open(path, "r", 438)
        if not fd then
            return nil
        end
        local data = vim.uv.fs_read(fd, stat.size, 0)
        vim.uv.fs_close(fd)
        return data
    end,

    --- Get a buffer suitable for treesitter operations on a file.
    --- If the buffer is already open and loaded, returns it directly.
    --- Otherwise, reads the file with vim.uv and creates a hidden scratch buffer
    --- with the content for treesitter parsing.
    --- @param abs_path string absolute file path
    --- @return number|nil bufnr buffer number, or nil if file can't be read
    --- @return boolean created_scratch true if a scratch buffer was created (caller should delete it)
    get_or_create_treesitter_buffer = function(abs_path)
        local bufnr = vim.fn.bufnr(abs_path)
        if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
            -- Verify the buffer actually corresponds to the requested file
            local buf_name = vim.fs.normalize(vim.fs.abspath(vim.api.nvim_buf_get_name(bufnr)))
            if buf_name == abs_path then
                return bufnr, false
            end
        end

        -- Read file contents with vim.uv
        local content = module.private.read_file_contents(abs_path)
        if not content then
            return nil, false
        end

        -- Create scratch buffer with file content
        local scratch = vim.api.nvim_create_buf(false, true)
        local lines = vim.split(content, "\n", { plain = true })
        vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
        vim.bo[scratch].filetype = "norg"

        return scratch, true
    end,

    --- Normalize a metadata field into a list for an indexer.
    --- Keeping this separate from category tree construction lets future
    --- indexers reuse the same entry collection pipeline for other fields.
    --- @param metadata table normalized document metadata
    --- @param field string metadata field to index
    --- @param fallback string[] values used when the field is absent
    --- @return string[] values
    normalize_metadata_values = function(metadata, field, fallback)
        local values = metadata[field]
        if not values or values == vim.NIL then
            return vim.list_extend({}, fallback)
        end
        if type(values) ~= "table" then
            return { tostring(values) }
        end
        return values
    end,

    --- Collect entries from norg files, grouped by metadata value.
    --- @param files string[] list of absolute file paths
    --- @param ws_norm string normalized workspace root
    --- @param index_path string absolute path of the main index file to skip
    --- @param cats_dir_abs string|nil absolute path of the category index directory to skip
    --- @param changed_set table|nil map of normalized absolute file paths that changed
    --- @return table categorized map of full category string -> entries list
    --- @return string[] category_order ordered list of unique full category strings
    --- @return table affected_categories map of full category strings affected by changed files
    collect_entries = function(files, ws_norm, index_path, cats_dir_abs, changed_set)
        local ts = module.required["core.integrations.treesitter"]
        local categorized = {}
        local category_order = {}
        local affected_categories = {}
        local config = module.config.public.categories
        local separator = config.subcategory_separator

        for _, file in ipairs(files) do
            local abs_path = vim.fs.normalize(tostring(file))

            -- Skip the main index file
            if abs_path == index_path then
                goto continue
            end

            -- Skip files inside the category index directory
            if cats_dir_abs and vim.startswith(abs_path, cats_dir_abs .. "/") then
                goto continue
            end

            -- Get a buffer for treesitter (existing or scratch)
            local bufnr, created_scratch = module.private.get_or_create_treesitter_buffer(abs_path)
            if not bufnr then
                goto continue
            end

            local metadata = ts.get_document_metadata(bufnr) or {}

            if created_scratch then
                module.private.safe_buf_delete(bufnr)
            end

            -- Path relative to workspace root, without .norg extension, used in links.
            -- The leading "/" is intentional: combined with the "$" workspace anchor it
            -- produces links of the form {:$/path/to/file:}[Title].
            local norgname = abs_path:gsub("^" .. vim.pesc(ws_norm), ""):gsub("%.norg$", "")

            -- Fall back to filename when no title is present in metadata
            local title = (metadata.title ~= vim.NIL and metadata.title ~= "") and metadata.title
                or vim.fs.basename(abs_path):gsub("%.norg$", "")

            local description = (metadata.description ~= vim.NIL) and metadata.description

            local created = (metadata.created ~= vim.NIL and metadata.created ~= "") and metadata.created or nil
            local updated = (metadata.updated ~= vim.NIL and metadata.updated ~= "") and metadata.updated or nil

            -- Build normalized metadata for the title_formatter callback
            local norm_meta = {}
            for k, v in pairs(metadata) do
                if v ~= vim.NIL then
                    norm_meta[k] = v
                end
            end
            norm_meta.title = title -- ensure resolved title is available

            local cats = module.private.normalize_metadata_values(metadata, "categories", { "Uncategorized" })

            if changed_set and changed_set[abs_path] then
                for _, cat in ipairs(cats) do
                    affected_categories[cat] = true
                    local parts = vim.split(cat, separator, { plain = true })
                    parts = vim.tbl_filter(function(p)
                        return p ~= ""
                    end, parts)
                    if #parts > 1 then
                        local acc = {}
                        for _, part in ipairs(parts) do
                            table.insert(acc, part)
                            affected_categories[table.concat(acc, separator)] = true
                        end
                    end
                end
            end

            local entry = {
                title = title,
                norgname = norgname,
                description = description,
                created = created,
                updated = updated,
                metadata = norm_meta,
            }

            for _, cat in ipairs(cats) do
                if not categorized[cat] then
                    categorized[cat] = {}
                    table.insert(category_order, cat)
                end
                table.insert(categorized[cat], entry)
            end

            ::continue::
        end

        if changed_set and not next(affected_categories) then
            affected_categories = {}
        end

        return categorized, category_order, affected_categories
    end,

    --- Build a category tree from flat categorized entries.
    --- Each node has: children (map), child_order (list), entries (list).
    --- @param categorized table map of full category string -> entries list
    --- @param category_order string[] ordered list of full category strings
    --- @param separator string the sub-category separator
    --- @return table tree root node
    build_category_tree = function(categorized, category_order, separator)
        local tree = { children = {}, entries = {}, child_order = {} }

        for _, full_cat in ipairs(category_order) do
            local parts = vim.split(full_cat, separator, { plain = true })
            -- Filter out empty parts from leading/trailing/double separators
            parts = vim.tbl_filter(function(p)
                return p ~= ""
            end, parts)
            if #parts == 0 then
                parts = { full_cat }
            end

            local node = tree
            for _, part in ipairs(parts) do
                if not node.children[part] then
                    node.children[part] = { children = {}, entries = {}, child_order = {} }
                    table.insert(node.child_order, part)
                end
                node = node.children[part]
            end

            for _, entry in ipairs(categorized[full_cat]) do
                table.insert(node.entries, entry)
            end
        end

        return tree
    end,

    --- Check whether top-level categories have changed compared to existing category files.
    --- @param cats_dir_abs string|nil
    --- @param top_level string[]
    --- @return boolean
    top_level_categories_changed = function(cats_dir_abs, top_level)
        if not cats_dir_abs or vim.fn.isdirectory(cats_dir_abs) ~= 1 then
            return true
        end
        local existing = {}
        for name, entry_type in vim.fs.dir(cats_dir_abs) do
            if entry_type == "file" and name:sub(-5) == ".norg" then
                table.insert(existing, name:sub(1, -6))
            end
        end
        local desired = vim.list_extend({}, top_level)
        module.private.sort_strings(existing)
        module.private.sort_strings(desired)
        if #existing ~= #desired then
            return true
        end
        for i = 1, #existing do
            if existing[i] ~= desired[i] then
                return true
            end
        end
        return false
    end,

    --- Check whether a full category exists in the tree.
    --- @param tree table
    --- @param full_cat string
    --- @param separator string
    --- @return boolean
    category_exists = function(tree, full_cat, separator)
        local parts = vim.split(full_cat, separator, { plain = true })
        parts = vim.tbl_filter(function(p)
            return p ~= ""
        end, parts)
        if #parts == 0 then
            return false
        end
        local node = tree
        for _, part in ipairs(parts) do
            if not node.children[part] then
                return false
            end
            node = node.children[part]
        end
        return true
    end,

    --- Convert a full category string to its relative category file path.
    --- @param full_cat string
    --- @param separator string
    --- @return string
    get_category_rel_path_from_string = function(full_cat, separator)
        local parts = vim.split(full_cat, separator, { plain = true })
        parts = vim.tbl_filter(function(p)
            return p ~= ""
        end, parts)
        if #parts == 0 then
            parts = { full_cat }
        end
        return module.private.get_category_rel_path(parts, nil)
    end,

    --- Find categories whose index files currently reference any of the given note norgnames.
    --- @param ws_norm string
    --- @param cats_dir_abs string
    --- @param norgnames string[]
    --- @return table map of full category strings -> true
    find_categories_for_norgnames = function(ws_norm, cats_dir_abs, norgnames)
        local config = module.config.public.categories
        local results = {}
        if not cats_dir_abs or #norgnames == 0 then
            return results
        end
        if vim.fn.isdirectory(cats_dir_abs) ~= 1 then
            return results
        end
        local files = vim.fs.find(function(name, _)
            return name:sub(-5) == ".norg"
        end, { path = cats_dir_abs, type = "file", limit = math.huge })
        for _, abs_path in ipairs(files) do
            local content = module.private.read_file_contents(abs_path)
            if content then
                for _, norgname in ipairs(norgnames) do
                    if content:find("{:$" .. norgname .. ":}", 1, true) then
                        local rel_path = abs_path:gsub("^" .. vim.pesc(ws_norm .. "/"), "")
                        local cat_path = rel_path
                            :gsub("^" .. vim.pesc(config.dir .. "/"), "")
                            :gsub("%.norg$", "")
                        local full_cat = cat_path:gsub("/", config.subcategory_separator)
                        results[full_cat] = true
                        break
                    end
                end
            end
        end
        return results
    end,

    --- Delete category files that no longer exist in the tree.
    --- @param ws_norm string
    --- @param tree table
    --- @param affected_categories table map of full category strings
    --- @param separator string
    delete_obsolete_category_files = function(ws_norm, tree, affected_categories, separator)
        for full_cat in pairs(affected_categories) do
            if not module.private.category_exists(tree, full_cat, separator) then
                local rel_path = module.private.get_category_rel_path_from_string(full_cat, separator)
                local abs_path = vim.fs.normalize(ws_norm .. "/" .. rel_path)
                if vim.fn.filereadable(abs_path) == 1 then
                    vim.fn.delete(abs_path)
                end
            end
        end
    end,

    --- Recursively collect all entries from a node and its descendants.
    collect_all_entries = function(node)
        local entries = {}
        for _, entry in ipairs(node.entries) do
            table.insert(entries, entry)
        end
        for _, child_name in ipairs(node.child_order) do
            vim.list_extend(entries, module.private.collect_all_entries(node.children[child_name]))
        end
        return entries
    end,

    --- Check if a tree node has any children.
    has_children = function(node)
        return #node.child_order > 0
    end,

    --- Get the relative file path (from workspace root) for a category index.
    --- Always: <dir>/<path...>/<category_name>.norg
    get_category_rel_path = function(path_parts, _)
        local config = module.config.public.categories
        local parts = { config.dir }
        for i = 1, #path_parts - 1 do
            table.insert(parts, path_parts[i])
        end
        table.insert(parts, path_parts[#path_parts] .. ".norg")
        return table.concat(parts, "/")
    end,

    --- Get the norgname (for links) of a category file.
    --- Returns a path like /categories/a/b (without .norg).
    get_category_norgname = function(path_parts, node)
        local rel_path = module.private.get_category_rel_path(path_parts, node)
        return "/" .. rel_path:gsub("%.norg$", "")
    end,

    --- Compute relative norgname from one file to another.
    --- Both paths are relative to the workspace root.
    --- @param from_rel_path string relative path of the source file (e.g., "index.norg")
    --- @param to_rel_path string relative path of the target file (e.g., "categories/Programming.norg")
    --- @return string relative norgname (e.g., "./categories/Programming")
    get_relative_norgname = function(from_rel_path, to_rel_path)
        local from_dir = vim.fn.fnamemodify(from_rel_path, ":h")
        local from_parts = (from_dir == "." or from_dir == "") and {} or vim.split(from_dir, "/", { plain = true })
        local to_file_parts = vim.split(to_rel_path, "/", { plain = true })

        -- Find common prefix length
        local common = 0
        for i = 1, math.min(#from_parts, #to_file_parts) do
            if from_parts[i] == to_file_parts[i] then
                common = common + 1
            else
                break
            end
        end

        -- Build relative path: go up from source dir, then down to target
        local result_parts = {}
        for _ = common + 1, #from_parts do
            table.insert(result_parts, "..")
        end
        for i = common + 1, #to_file_parts do
            table.insert(result_parts, to_file_parts[i])
        end

        local rel = table.concat(result_parts, "/")
        rel = rel:gsub("%.norg$", "")

        return rel
    end,

    --- Format a list of entries as heading link lines.
    format_entry_lines = function(entries, heading_level)
        local config = module.config.public.categories
        local lines = {}
        for _, entry in ipairs(entries) do
            local display_title = config.title_formatter(entry.metadata)
            local line = string.rep("*", heading_level) .. " {:$" .. entry.norgname .. ":}[" .. display_title .. "]"
            table.insert(lines, line)
        end
        return lines
    end,

    --- Sort entries based on config (sort_by and sort_direction).
    sort_entries = function(entries)
        local config = module.config.public.categories
        local sort_by = config.sort_by
        local ascending = config.sort_direction == "ascending"

        table.sort(entries, function(a, b)
            local va, vb
            if sort_by == "created" then
                va = a.created or ""
                vb = b.created or ""
            elseif sort_by == "updated" then
                va = a.updated or ""
                vb = b.updated or ""
            else -- "alphabetical"
                va = a.title:lower()
                vb = b.title:lower()
            end
            if ascending then
                return va < vb
            else
                return va > vb
            end
        end)
    end,

    --- Deduplicate entries by norgname, preserving order.
    deduplicate_entries = function(entries)
        local seen = {}
        local result = {}
        for _, entry in ipairs(entries) do
            if not seen[entry.norgname] then
                seen[entry.norgname] = true
                table.insert(result, entry)
            end
        end
        return result
    end,

    --- Sort a list of strings alphabetically (case-insensitive), respecting sort_direction.
    sort_strings = function(list)
        local ascending = module.config.public.categories.sort_direction == "ascending"
        table.sort(list, function(a, b)
            if ascending then
                return a:lower() < b:lower()
            else
                return a:lower() > b:lower()
            end
        end)
    end,

    --- Generate main index lines when per_subcategory_index is enabled.
    --- Top-level categories become headings that link to their category indexes.
    generate_main_index_lines = function(tree)
        local config = module.config.public.categories
        local heading_level = 1
        local result = { string.rep("*", heading_level) .. " Index", "" }

        local child_heading_level = 2
        local sorted_children = vim.list_extend({}, tree.child_order)
        module.private.sort_strings(sorted_children)

        -- Category headings (no entry lines under them)
        for _, child_name in ipairs(sorted_children) do
            local child = tree.children[child_name]
            local child_rel_path = module.private.get_category_rel_path({ child_name }, child)
            local rel_norgname = module.private.get_relative_norgname(config.name, child_rel_path)
            table.insert(
                result,
                string.rep("*", child_heading_level) .. " {:" .. rel_norgname .. ":}[" .. child_name .. "]"
            )
        end

        if config.list_subcategory_notes then
            -- "Notes" heading with all descendant entries flattened
            local all_entries = module.private.deduplicate_entries(module.private.collect_all_entries(tree))
            module.private.sort_entries(all_entries)
            if #all_entries > 0 then
                vim.list_extend(result, { "", string.rep("*", heading_level) .. " Notes", "" })
                vim.list_extend(result, module.private.format_entry_lines(all_entries, heading_level + 1))
            end
        end

        return result
    end,

    --- Generate tree lines for inline mode (per_subcategory_index is false).
    --- Recursively generate the full category tree with notes listed under
    --- their corresponding subcategory (not flattened). No "Notes" heading.
    generate_tree_lines = function(node, heading_level)
        local result = {}
        local sorted_children = vim.list_extend({}, node.child_order)
        module.private.sort_strings(sorted_children)
        for _, child_name in ipairs(sorted_children) do
            local child = node.children[child_name]

            -- Category heading
            table.insert(result, string.rep("*", heading_level) .. " " .. child_name)

            -- Direct entries of this category
            local entries = module.private.deduplicate_entries(vim.list_extend({}, child.entries))
            module.private.sort_entries(entries)
            vim.list_extend(result, module.private.format_entry_lines(entries, heading_level + 1))

            -- Recurse into subcategories
            if module.private.has_children(child) then
                vim.list_extend(result, module.private.generate_tree_lines(child, heading_level + 1))
            end
        end
        return result
    end,

    --- Generate all category index contents.
    --- @param affected_categories table|nil map of full category strings to include
    --- @return table map of relative_path -> content_string
    generate_all_category_index_files = function(tree, affected_categories)
        local config = module.config.public.categories
        local files = {}
        local separator = config.subcategory_separator

        local function generate_node(node, node_name, path_parts)
            local full_cat = table.concat(path_parts, separator)
            local rel_path = module.private.get_category_rel_path(path_parts, node)
            local heading_level = 1
            local child_heading_level = heading_level + 1
            local lines = { string.rep("*", heading_level) .. " " .. node_name, "" }

            -- Compute parent link (relative)
            local parent_rel_path, parent_name
            if #path_parts == 1 then
                -- Top-level category: parent is the main index file
                parent_rel_path = config.name
                parent_name = config.name:gsub("%.norg$", "")
            else
                -- Sub-category: parent is the parent category file
                local parent_path_parts = {}
                for i = 1, #path_parts - 1 do
                    table.insert(parent_path_parts, path_parts[i])
                end
                parent_rel_path = module.private.get_category_rel_path(parent_path_parts, nil)
                parent_name = path_parts[#path_parts - 1]
            end
            local parent_rel_norgname = module.private.get_relative_norgname(rel_path, parent_rel_path)
            local parent_link_line = string.rep("*", child_heading_level)
                .. " {:"
                .. parent_rel_norgname
                .. ":}[󰜱 "
                .. parent_name
                .. "]"

            if module.private.has_children(node) then
                local sorted_children = vim.list_extend({}, node.child_order)
                module.private.sort_strings(sorted_children)

                if config.list_subcategory_notes then
                    -- Sub-category headings (no entries under them)
                    for _, child_name in ipairs(sorted_children) do
                        local child = node.children[child_name]
                        local child_path_parts = vim.list_extend({}, path_parts)
                        table.insert(child_path_parts, child_name)
                        local child_rel_path = module.private.get_category_rel_path(child_path_parts, child)
                        local rel_norgname = module.private.get_relative_norgname(rel_path, child_rel_path)
                        table.insert(
                            lines,
                            string.rep("*", child_heading_level) .. " {:" .. rel_norgname .. ":}[" .. child_name .. "]"
                        )
                    end
                    -- Parent link as last subcategory heading
                    table.insert(lines, parent_link_line)

                    -- "Notes" heading with all entries (direct + descendants) flattened
                    local all_entries = module.private.deduplicate_entries(module.private.collect_all_entries(node))
                    module.private.sort_entries(all_entries)
                    if #all_entries > 0 then
                        vim.list_extend(lines, { "", string.rep("*", heading_level) .. " Notes", "" })
                        vim.list_extend(lines, module.private.format_entry_lines(all_entries, heading_level + 1))
                    end
                else
                    -- Headings linking to child files
                    local heading_lines = {}
                    for _, child_name in ipairs(sorted_children) do
                        local child = node.children[child_name]
                        local child_path_parts = vim.list_extend({}, path_parts)
                        table.insert(child_path_parts, child_name)
                        local child_rel_path = module.private.get_category_rel_path(child_path_parts, child)
                        local rel_norgname = module.private.get_relative_norgname(rel_path, child_rel_path)
                        table.insert(
                            heading_lines,
                            string.rep("*", child_heading_level) .. " {:" .. rel_norgname .. ":}[" .. child_name .. "]"
                        )
                    end

                    -- Only direct entries
                    local entries = module.private.deduplicate_entries(vim.list_extend({}, node.entries))
                    module.private.sort_entries(entries)
                    local entry_lines = module.private.format_entry_lines(entries, heading_level + 1)

                    vim.list_extend(lines, entry_lines)
                    vim.list_extend(lines, heading_lines)
                    -- Parent link as last heading
                    table.insert(lines, parent_link_line)
                end
            else
                -- Leaf node: list direct entries, sorted and deduplicated
                local entries = module.private.deduplicate_entries(vim.list_extend({}, node.entries))
                module.private.sort_entries(entries)
                vim.list_extend(lines, module.private.format_entry_lines(entries, heading_level + 1))
                -- Parent link as last item
                table.insert(lines, parent_link_line)
            end

            local content = table.concat(lines, "\n") .. "\n"

            if not affected_categories or affected_categories[full_cat] then
                files[rel_path] = content
            end

            -- Recurse into children
            for _, child_name in ipairs(node.child_order) do
                local child = node.children[child_name]
                local child_path_parts = vim.list_extend({}, path_parts)
                table.insert(child_path_parts, child_name)
                generate_node(child, child_name, child_path_parts)
            end
        end

        for _, child_name in ipairs(tree.child_order) do
            generate_node(tree.children[child_name], child_name, { child_name })
        end

        return files
    end,

    --- Read existing @document.meta from a file (if it exists).
    --- @return string[]|nil metadata lines or nil
    read_existing_metadata = function(path)
        local ts = module.required["core.integrations.treesitter"]

        local bufnr, created_scratch = module.private.get_or_create_treesitter_buffer(path)
        if not bufnr then
            return nil
        end

        local query = utils.ts_parse_query(
            "norg",
            [[
                (ranged_verbatim_tag
                    (tag_name) @name
                    (#eq? @name "document.meta")
                ) @meta
            ]]
        )

        local root = ts.get_document_root(bufnr)
        local metadata = nil

        if root then
            local _, found = query:iter_matches(root, bufnr)()
            if found then
                for id, node in pairs(found) do
                    local name = query.captures[id]
                    -- node is a list in nvim 0.11+
                    if vim.islist(node) then
                        node = node[1]
                    end
                    if name == "meta" then
                        local start_row, _, start_col, end_row, _, end_col = node:range(true)
                        metadata = vim.api.nvim_buf_get_text(bufnr, start_row, start_col, end_row, end_col, {})
                        break
                    end
                end
            end
        end

        if created_scratch then
            module.private.safe_buf_delete(bufnr)
        end

        return metadata
    end,

    --- Read file body content (everything except the @document.meta block).
    --- @param path string absolute file path
    --- @return string|nil body content or nil if file doesn't exist
    read_file_body = function(path)
        local content = module.private.read_file_contents(path)
        if not content then
            return nil
        end
        local lines = vim.split(content, "\n", { plain = true })
        local in_meta = false
        local body_lines = {}
        local found_meta = false
        for _, line in ipairs(lines) do
            if not found_meta and line:match("^@document%.meta") then
                in_meta = true
                found_meta = true
            elseif in_meta and line:match("^@end") then
                in_meta = false
            elseif not in_meta then
                table.insert(body_lines, line)
            end
        end
        -- Skip leading blank lines
        local start_idx = 1
        while start_idx <= #body_lines and body_lines[start_idx]:match("^%s*$") do
            start_idx = start_idx + 1
        end
        return table.concat(body_lines, "\n", start_idx)
    end,

    --- Return the configured core.esupports.metagen options.
    --- The indexer follows the metagen module's type and update_date settings.
    --- @return table metagen configuration
    get_metagen_config = function()
        local metagen = module.required["core.esupports.metagen"]
        return metagen.config and metagen.config.public or {}
    end,

    --- Whether metadata should be created for an index file.
    --- @param path string absolute path of the index file
    --- @return boolean
    should_generate_metadata = function(path)
        local metadata_type = module.private.get_metagen_config().type
        if metadata_type == "auto" then
            return true
        end
        if metadata_type == "empty" then
            return module.private.read_file_contents(path) == nil
        end
        return false
    end,

    --- Generate fresh metadata lines for an index file using the metagen API.
    --- @param title string the title for the metadata
    --- @return string[] metadata lines
    generate_metadata_lines = function(title)
        local metagen = module.required["core.esupports.metagen"]
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "placeholder" })
        local lines = metagen.construct_metadata(buf, { title = title })
        module.private.safe_buf_delete(buf)
        -- Remove trailing empty lines if present (added by metagen for spacing)
        local end_idx = #lines
        while end_idx > 0 and lines[end_idx] == "" do
            end_idx = end_idx - 1
        end
        local result = {}
        for i = 1, end_idx do
            table.insert(result, lines[i])
        end
        return result
    end,

    --- Update the "updated" timestamp in existing metadata lines using the metagen API.
    --- @param metadata_lines string[] existing metadata lines
    --- @return string[] updated metadata lines
    update_metadata_timestamp = function(metadata_lines)
        local metagen = module.required["core.esupports.metagen"]
        -- Generate fresh metadata to extract the updated timestamp format
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "placeholder" })
        local fresh_lines = metagen.construct_metadata(buf, {})
        module.private.safe_buf_delete(buf)

        -- Extract the updated line from fresh metadata
        local fresh_updated_line = nil
        for _, line in ipairs(fresh_lines) do
            if line:match("^%s*updated") then
                fresh_updated_line = line
                break
            end
        end

        if not fresh_updated_line then
            return metadata_lines
        end

        -- Replace or insert the updated field in old metadata
        local result = {}
        local replaced = false
        for _, line in ipairs(metadata_lines) do
            if not replaced and line:match("^%s*updated") then
                table.insert(result, fresh_updated_line)
                replaced = true
            elseif not replaced and line:match("^@end") then
                -- Add updated before @end if not found in existing metadata
                table.insert(result, fresh_updated_line)
                table.insert(result, line)
                replaced = true
            else
                table.insert(result, line)
            end
        end
        return result
    end,

    --- Prepare generated index content according to core.esupports.metagen.
    --- Existing metadata is preserved; missing metadata is generated only when
    --- metagen.type is "auto" or when it is "empty" and the file is new.
    --- @param path string absolute file path
    --- @param body string the body content (without metadata)
    --- @param title string the title for fresh metadata
    --- @return string full file content
    prepare_index_content = function(path, body, title)
        local old_metadata_lines = module.private.read_existing_metadata(path)
        local old_body = module.private.read_file_body(path)
        local metagen_config = module.private.get_metagen_config()

        if not old_metadata_lines then
            if not module.private.should_generate_metadata(path) then
                return body
            end
            local metadata_lines = module.private.generate_metadata_lines(title)
            return table.concat(metadata_lines, "\n") .. "\n\n" .. body
        end

        local metadata_lines = old_metadata_lines
        local content_changed = not old_body or vim.trim(old_body) ~= vim.trim(body)
        if
            content_changed
            and metagen_config.type ~= "none"
            and metagen_config.update_date ~= false
        then
            metadata_lines = module.private.update_metadata_timestamp(old_metadata_lines)
        end

        return table.concat(metadata_lines, "\n") .. "\n\n" .. body
    end,

    --- Write a single file asynchronously.
    --- callback(err) is called on completion; err is nil on success.
    write_file_async = function(path, content, callback)
        -- 438 is octal 0666 (rw-rw-rw-), the standard permission for new files
        vim.uv.fs_open(path, "w", 438, function(open_err, fd)
            if open_err then
                callback("Failed to open " .. path .. ": " .. open_err)
                return
            end
            vim.uv.fs_write(fd, content, nil, function(write_err, _)
                vim.uv.fs_close(fd, function(close_err)
                    if write_err then
                        callback("Failed to write " .. path .. ": " .. write_err)
                    elseif close_err then
                        callback("Failed to close " .. path .. ": " .. close_err)
                    else
                        callback(nil)
                    end
                end)
            end)
        end)
    end,

    --- Write multiple files asynchronously, calling on_done when all complete.
    write_files_async = function(files, on_done)
        if #files == 0 then
            on_done()
            return
        end

        local completed = 0
        local errors = {}

        for _, file_info in ipairs(files) do
            module.private.write_file_async(file_info.path, file_info.content, function(err)
                if err then
                    table.insert(errors, err)
                end
                completed = completed + 1
                if completed == #files then
                    if #errors > 0 then
                        vim.schedule(function()
                            utils.notify("Errors writing files:\n" .. table.concat(errors, "\n"), vim.log.levels.ERROR)
                        end)
                    else
                        on_done()
                    end
                end
            end)
        end
    end,
}

module.on_event = function(event)
    if event.type == "core.neorgcmd.events.indexer.index" then
        vim.schedule(function()
            module.public.index()
        end)
        return
    end

    if event.type == "core.dirman.events.workspace_changed" then
        local handled_index_on_launch = false
        if module.private.index_on_launch_pending then
            handled_index_on_launch = module.private.trigger_index_on_launch()
        end

        if module.config.public.categories.index_on_change then
            vim.schedule(function()
                module.private.setup_workspace_watchers()
                local new_ws = event.content and event.content.new
                if new_ws and not handled_index_on_launch then
                    module.public.index(new_ws)
                end
            end)
        end
        return
    end

    if module.config.public.categories.index_on_change then
        if event.type == "core.dirman.events.file_created" then
            vim.schedule(function()
                local bufnr = event.content and event.content.buffer
                if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
                    local filepath = vim.fs.normalize(vim.fs.abspath(vim.fn.resolve(vim.api.nvim_buf_get_name(bufnr))))
                    local ws_name = module.private.find_workspace_for_file(filepath)
                    if ws_name then
                        module.public.index(ws_name)
                    end
                end
            end)
        end
    end
end

module.events.subscribed = {
    ["core.neorgcmd"] = {
        ["indexer.index"] = true,
    },
    ["core.dirman"] = {
        ["workspace_changed"] = true,
        ["file_created"] = true,
    },
}

return module
