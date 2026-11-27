--[[
    file: module.lua
    title: Indexer Module for Neorg
    description: Index Neorg documents by category, author, date, and BibTeX keyword
    author: neorg-indexer
--]]

local neorg = require("neorg.core")
local modules, utils = neorg.modules, neorg.utils
local indexers = require("neorg.modules.external.indexer.indexers")
local bibtex = require("neorg.modules.external.indexer.bibtex")
local progress = require("neorg.modules.external.indexer.progress")

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
    module.private.warn_deprecated_options()
    modules.await("core.neorgcmd", function(neorgcmd)
        neorgcmd.add_commands_from_table({
            ["indexer"] = {
                min_args = 0,
                name = "indexer.index",
            },
            ["indexer-search"] = {
                args = 0,
                name = "indexer.search",
            },
        })
    end)
    if module.config.public.index_on_launch then
        modules.await("core.dirman", function(dirman)
            module.private.trigger_index_on_launch(dirman)
        end)
    end
    if module.config.public.index_on_change then
        module.private.setup_workspace_watchers()
    end
end

local default_title_formatter = indexers.default_title_formatter

module.config.public = {
    name = "index.norg",
    index_on_launch = false,
    index_on_change = true,
    -- Progress notification while generating indexes. It appears once a run takes longer than
    -- `delay_ms`; with `enabled = false` only the final message is shown.
    progress = {
        enabled = true,
        delay_ms = 300,
    },
    search = {
        search_content = true,
        include_generated = false,
        pdf_preview = {
            enabled = true,
            density = 110,
        },
        mappings = {
            open_pdf = "<C-o>",
        },
    },
    categories = vim.deepcopy(indexers.defaults.categories),
    authors = vim.deepcopy(indexers.defaults.authors),
    created = vim.deepcopy(indexers.defaults.created),
    updated = vim.deepcopy(indexers.defaults.updated),
    bibtex = vim.deepcopy(indexers.defaults.bibtex),
}

---@class external.indexer
module.public = {
    --- Search saved notes in the current workspace using Telescope.
    --- @param opts table|nil Telescope picker options
    search = function(opts)
        local dirman = modules.get_module("core.dirman")
        local workspace = dirman and dirman.get_current_workspace()
        if not workspace then
            utils.notify("Cannot search notes: no current Dirman workspace", vim.log.levels.ERROR)
            return
        end
        local root = workspace[1] == "default" and vim.fn.getcwd() or tostring(workspace[2])
        return require("neorg.modules.external.indexer.search_picker").open(
            vim.fs.normalize(vim.fs.abspath(root)),
            module.config.public,
            opts
        )
    end,

    --- Generate the indexes for a workspace. Files are read and written asynchronously; requests
    --- made while the workspace is being indexed are merged into one follow-up run.
    --- @param ws_name string|nil workspace name; defaults to the current workspace
    --- @param opts table|nil options: { changed_files = string[], on_done = fun(err: string|nil) }
    ---   on_done is called once the run, and the follow-up run queued meanwhile, completed.
    index = function(ws_name, opts)
        opts = opts or {}
        local on_done = opts.on_done or function() end
        local dirman = modules.get_module("core.dirman")

        if not dirman then
            local message = "`core.dirman` is not loaded! It is required to generate indexes"
            utils.notify(message, vim.log.levels.ERROR)
            on_done(message)
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
            on_done(nil)
            return
        end

        local ws_root = dirman.get_workspace(ws_name)
        if not ws_root then
            on_done(nil)
            return
        end

        -- Paths are built from the workspace root as dirman reports it, so notes that are symlinks
        -- (or live in symlinked directories) keep their in-workspace names.
        local ws_norm = vim.fs.normalize(vim.fs.abspath(tostring(ws_root)))

        local run = module.private.index_runs[ws_norm]
        if run then
            module.private.queue_index_request(run, opts.changed_files)
            table.insert(run.callbacks, on_done)
            return
        end
        -- `progress = false` disables the bar, `progress = true` keeps the defaults.
        local config = module.config.public.progress
        if config == false then
            config = { enabled = false }
        elseif type(config) ~= "table" then
            config = {}
        end
        run = {
            ws_norm = ws_norm,
            callbacks = { on_done },
            errors = {},
            progress = progress.new({
                id = "neorg.indexer.progress." .. ws_norm,
                enabled = config.enabled ~= false,
                delay_ms = config.delay_ms or 300,
            }),
        }
        module.private.index_runs[ws_norm] = run
        run.progress:start()
        module.private.run_index(run, opts.changed_files)
    end,
}

module.private = {
    -- In-flight index runs per workspace root. See `run_index`.
    index_runs = {},
    -- Maximum number of source files read at the same time.
    read_concurrency = 32,
    -- Number of files written by the last run per workspace root, to estimate the next run's.
    last_write_count = {},

    --- Record an index request for a workspace that is being indexed. Requests are merged: a
    --- full request (without changed files) makes the follow-up run a full one.
    --- @param run table in-flight run
    --- @param changed_files string[]|nil
    queue_index_request = function(run, changed_files)
        if type(changed_files) ~= "table" or #changed_files == 0 then
            run.pending = { full = true }
        elseif not run.pending then
            run.pending = { changed_files = vim.list_extend({}, changed_files) }
        elseif not run.pending.full then
            vim.list_extend(run.pending.changed_files, changed_files)
        end
    end,

    --- Generate the indexes of a workspace, then the follow-up run queued meanwhile, if any.
    --- The final message is shown and the callbacks are called once no run is queued.
    --- @param run table in-flight run: { ws_norm, progress, callbacks, errors, pending }
    --- @param changed_files string[]|nil
    run_index = function(run, changed_files)
        -- Paths are built from the workspace root as dirman reports it. The resolved root is only
        -- used to match paths reported in resolved form.
        local ws_norm = run.ws_norm
        local index_path = nil

        -- Called exactly once per run, whatever happens, so that the run is never left in flight.
        local completed = false
        local function complete(err)
            if completed then
                return
            end
            completed = true
            if err then
                table.insert(run.errors, err)
            end
            local pending = run.pending
            if pending then
                run.pending = nil
                run.progress:reset()
                module.private.run_index(run, pending.changed_files)
                return
            end
            module.private.index_runs[ws_norm] = nil
            local message = nil
            if #run.errors > 0 then
                message = table.concat(run.errors, "\n")
            end
            local ok_finish, finish_err = pcall(function()
                if message then
                    run.progress:finish(message, vim.log.levels.ERROR)
                else
                    run.progress:finish("Index generated at " .. (index_path or ws_norm))
                end
            end)
            if not ok_finish then
                pcall(utils.notify, "external.indexer: " .. tostring(finish_err), vim.log.levels.ERROR)
            end
            for _, callback in ipairs(run.callbacks) do
                local ok_callback, callback_err = pcall(callback, message)
                if not ok_callback then
                    pcall(utils.notify, "external.indexer: " .. tostring(callback_err), vim.log.levels.ERROR)
                end
            end
        end

        -- The setup scans the workspace: run it in time slices so that the editor stays responsive.
        module.private.run_sliced(function()
            -- Paths are built from the workspace root as dirman reports it. The resolved root is
            -- only used to match paths reported in resolved form.
            local ws_real = module.private.real_path(ws_norm)
            local index_rel = vim.fs.normalize(module.config.public.name)
            index_path = vim.fs.normalize(ws_norm .. "/" .. index_rel)
            local changed_set = nil
            if type(changed_files) == "table" then
                changed_set = {}
                for _, path in ipairs(changed_files) do
                    local normalized = vim.fs.normalize(vim.fs.abspath(path))
                    changed_set[normalized] = true
                    changed_set[module.private.real_path(normalized)] = true
                end
                if not next(changed_set) then
                    changed_set = nil
                end
            end

            local active = module.private.get_active_indexers(ws_norm)
            local generated_dirs = indexers.marked_dirs(module.config.public, ws_norm)
            local context = {
                ws_norm = ws_norm,
                ws_real = ws_real,
                index_rel = index_rel,
                index_path = index_path,
                changed_set = changed_set,
                active = active,
                generated_dirs = generated_dirs,
            }

            -- Collect entries from all norg and bib files
            module.private.collect_entries_async(
                module.private.list_source_files(ws_norm),
                { ws_norm, ws_real },
                index_rel,
                generated_dirs,
                module.private.last_write_count[ws_norm],
                run.progress,
                function(entries, collect_err)
                    if collect_err then
                        complete(collect_err)
                        return
                    end
                    module.private.run_sliced(function()
                        module.private.generate_index(context, entries, run.progress, complete)
                    end, function(slice_err)
                        complete(tostring(slice_err))
                    end)
                end
            )
        end, function(err)
            complete(tostring(err))
        end)
    end,

    --- Generate and write the index files of a workspace from its collected entries.
    --- @param context table { ws_norm, ws_real, index_rel, index_path, changed_set, active, generated_dirs }
    --- @param entries table[] collected entries
    --- @param progress table progress notification, advanced per written file
    --- @param on_done fun(err: string|nil) called on the main loop once all files are written
    generate_index = function(context, entries, progress, on_done)
        local ws_norm, ws_real, index_rel, index_path =
            context.ws_norm, context.ws_real, context.index_rel, context.index_path
        local changed_set, active, generated_dirs = context.changed_set, context.active, context.generated_dirs

        module.private.pdf_bibs[ws_norm] = module.private.build_pdf_bibs(entries)

        local changed_targets = {}
        if changed_set then
            -- A changed PDF changes the literatures whose `file` field resolves to it, whether the
            -- PDF was created or deleted.
            local pdf_bibs = module.private.pdf_bibs[ws_norm] or {}
            for path in pairs(vim.deepcopy(changed_set)) do
                if path:lower():match("%.pdf$") then
                    for _, bib in ipairs(pdf_bibs[path] or {}) do
                        changed_set[bib] = true
                    end
                end
            end
            local seen = {}
            for path in pairs(changed_set) do
                local rel = module.private.get_relative_path(path, { ws_norm, ws_real })
                local target = rel
                    and not module.private.is_generated_path(rel, index_rel, generated_dirs)
                    and module.private.get_link_target(rel)
                if target and not seen[target.norgname] then
                    seen[target.norgname] = true
                    table.insert(changed_targets, target)
                end
            end
        end

        local sections = {}
        local bucket_contents = {}
        local written_paths = {}
        local dirs_to_delete = {}
        local partial_updates = {}
        local marked_dirs = {}
        for _, ix in ipairs(active) do
            local tree = module.private.build_tree(ix, entries)
            local state = ix.per_file and module.private.get_dir_state(ix.dir_abs) or nil
            if state == "foreign" then
                -- Never overwrite or delete files the indexer did not generate.
                module.private.notify_once(
                    "external.indexer: `"
                        .. ix.def.key
                        .. ".dir` ("
                        .. ix.dir_abs
                        .. ") exists, is not empty, and has no "
                        .. indexers.marker
                        .. " marker file; skipping the "
                        .. indexers.full_title(ix.def)
                        .. " index",
                    vim.log.levels.ERROR
                )
                goto continue
            end
            local section = module.private.generate_section_lines(ix, tree, index_rel)
            if section then
                table.insert(sections, { group = ix.def.group, lines = section })
            end

            if ix.per_file then
                -- Partial updates need an existing generated index directory to patch. Name collisions
                -- shift the names of other buckets, so they always trigger a full rebuild.
                local affected = nil
                if
                    changed_set
                    and state == "marked"
                    and not tree.has_collisions
                    and not module.private.has_collision_suffix(ix.dir_abs)
                then
                    affected = module.private.find_affected_buckets(ix, entries, changed_set, changed_targets)
                end

                -- Prepare content with metadata handling (BEFORE deleting index directories)
                local files = module.private.generate_bucket_files(ix, tree, affected, index_rel)
                local rel_paths = vim.tbl_keys(files)
                table.sort(rel_paths)
                for _, rel_path in ipairs(rel_paths) do
                    module.private.yield_if_needed()
                    local body = files[rel_path]
                    local abs_path = vim.fs.normalize(ws_norm .. "/" .. rel_path)
                    local folded = indexers.fold_case(abs_path)
                    -- Each path is written at most once per run.
                    if not written_paths[folded] then
                        written_paths[folded] = true
                        local title = body:match("^%*+ ([^\n]+)") or vim.fn.fnamemodify(rel_path, ":t:r")
                        bucket_contents[abs_path] =
                            module.private.prepare_index_content(abs_path, body, module.private.unescape(title))
                    end
                end

                if affected then
                    table.insert(partial_updates, { ix = ix, tree = tree, affected = affected })
                else
                    if state == "marked" then
                        table.insert(dirs_to_delete, ix.dir_abs)
                    end
                    if #rel_paths > 0 then
                        table.insert(marked_dirs, ix.dir_abs)
                    end
                end
            end
            ::continue::
        end

        local files_to_write = {}

        -- Main index: skip the write when nothing would change. The "* Index" heading is kept
        -- even when no indexer has a section. Grouped sections are level-3 headings under one
        -- level-2 group heading, which exists only when one of its sections does.
        local main_lines = { "* Index" }
        local group
        for _, section in ipairs(sections) do
            table.insert(main_lines, "")
            if section.group and section.group ~= group then
                vim.list_extend(main_lines, { "** " .. section.group, "" })
            end
            group = section.group
            vim.list_extend(main_lines, section.lines)
        end
        local main_body = table.concat(main_lines, "\n") .. "\n"
        local main_content = module.private.prepare_index_content(index_path, main_body, "Index")
        if main_content ~= module.private.read_file_contents(index_path) then
            table.insert(files_to_write, { path = index_path, content = main_content })
        end

        -- Now safe to delete index directories for full rebuilds. Only directories that contain
        -- the marker file are ever deleted.
        for _, dir in ipairs(dirs_to_delete) do
            if vim.fn.isdirectory(dir) == 1 and indexers.has_marker(dir) then
                module.private.delete_tree(dir)
            end
        end
        for _, update in ipairs(partial_updates) do
            module.private.delete_obsolete_bucket_files(update.ix, update.tree, update.affected)
        end
        -- Mark generated directories before writing their files.
        for _, dir in ipairs(marked_dirs) do
            module.private.yield_if_needed()
            module.private.write_marker(dir)
        end

        -- Create directories and prepare file entries
        local bucket_paths = vim.tbl_keys(bucket_contents)
        table.sort(bucket_paths)
        for _, abs_path in ipairs(bucket_paths) do
            vim.fn.mkdir(vim.fn.fnamemodify(abs_path, ":h"), "p")
            table.insert(files_to_write, { path = abs_path, content = bucket_contents[abs_path] })
        end

        -- Write all files, preferring buffer updates for open files
        progress:settle(#files_to_write)
        module.private.last_write_count[ws_norm] = #files_to_write
        local disk_writes = {}
        for _, file_info in ipairs(files_to_write) do
            module.private.yield_if_needed()
            local bufnr = module.private.find_open_buffer(file_info.path)
            if bufnr then
                module.private.write_to_buffer(bufnr, file_info.content)
                progress:advance()
            else
                table.insert(disk_writes, file_info)
            end
        end
        module.private.write_files_async(disk_writes, function(errors)
            vim.schedule(function()
                if #errors > 0 then
                    on_done("Errors writing files:\n" .. table.concat(errors, "\n"))
                else
                    on_done(nil)
                end
            end)
        end, function()
            progress:advance()
        end)
    end,

    workspace_watchers = {},
    -- Longest stretch of indexing work, in milliseconds, before the editor gets to handle input
    -- and redraw.
    slice_budget_ms = 8,
    -- Coroutine of the running time-sliced work and when its current slice started.
    slice_co = nil,
    slice_started = 0,

    --- Whether a time slice that started at `started` (vim.uv.hrtime) is used up.
    --- @param started integer
    --- @return boolean
    slice_expired = function(started)
        return (vim.uv.hrtime() - started) / 1e6 >= module.private.slice_budget_ms
    end,

    --- Run `fn` after the editor had a chance to handle pending input and redraw. A timer is used
    --- rather than vim.schedule so that the event loop polls for input in between.
    --- @param fn function
    defer = function(fn)
        vim.defer_fn(fn, 0)
    end,

    --- Run `fn` in time slices: `yield_if_needed` calls inside it pause it once a slice is used up
    --- and it is resumed after the editor handled input. on_error(err) is called if it throws.
    --- @param fn function
    --- @param on_error fun(err: any)
    run_sliced = function(fn, on_error)
        local co = coroutine.create(fn)
        local function step()
            local outer_co, outer_started = module.private.slice_co, module.private.slice_started
            module.private.slice_co = co
            module.private.slice_started = vim.uv.hrtime()
            local ok, err = coroutine.resume(co)
            module.private.slice_co, module.private.slice_started = outer_co, outer_started
            if not ok then
                on_error(err)
            elseif coroutine.status(co) == "suspended" then
                module.private.defer(step)
            end
        end
        step()
    end,

    --- Pause the running `run_sliced` work if its time slice is used up. Does nothing elsewhere.
    yield_if_needed = function()
        local co = coroutine.running()
        if co and co == module.private.slice_co and module.private.slice_expired(module.private.slice_started) then
            coroutine.yield()
        end
    end,
    -- Per workspace root: PDF path (as written and resolved) -> .bib files whose `file` field
    -- resolves to it, whether or not the PDF exists.
    pdf_bibs = {},
    watch_timers = {},
    pending_changes = {},
    index_on_launch_pending = false,
    deprecation_warned = false,
    notified = {},
    watch_debounce_ms = 200,

    --- Warn once about options that moved from `categories` to the top level.
    --- The old keys are not honored.
    warn_deprecated_options = function()
        if module.private.deprecation_warned then
            return
        end
        local categories = module.config.public.categories
        if type(categories) ~= "table" then
            return
        end
        local messages = {}
        for _, key in ipairs({ "name", "index_on_launch", "index_on_change" }) do
            if categories[key] ~= nil then
                table.insert(messages, "`categories." .. key .. "` is no longer supported; use `" .. key .. "` instead")
            end
        end
        if #messages > 0 then
            module.private.deprecation_warned = true
            utils.notify("external.indexer: " .. table.concat(messages, "; "), vim.log.levels.WARN)
        end
    end,

    --- Notify a message once per session.
    --- @param message string
    --- @param level integer vim.log.levels value
    notify_once = function(message, level)
        if module.private.notified[message] then
            return
        end
        module.private.notified[message] = true
        utils.notify(message, level)
    end,

    --- Attempt to run index_on_launch once a real workspace is available.
    --- @param dirman table|nil
    --- @return boolean triggered true when an index was scheduled
    trigger_index_on_launch = function(dirman)
        if not module.config.public.index_on_launch then
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
            if module.private.get_relative_path(filepath, { root, module.private.real_path(root) }) then
                return name
            end
        end
        return nil
    end,

    --- Normalize an absolute path with symlinks resolved.
    --- A missing file is resolved through its parent directory. Uses only libuv so that it is
    --- safe in libuv callbacks.
    --- @param path string
    --- @return string
    real_path = function(path)
        path = vim.fs.normalize(vim.fs.abspath(path))
        local resolved = vim.uv.fs_realpath(path)
        if resolved then
            return vim.fs.normalize(resolved)
        end
        local parent = vim.uv.fs_realpath(vim.fs.dirname(path))
        if parent then
            return vim.fs.normalize(parent .. "/" .. vim.fs.basename(path))
        end
        return path
    end,

    --- List the .norg and .bib files of a workspace, following symlinks like `core.dirman` does.
    --- Unlike `core.dirman.get_norg_files`, paths are not resolved: a symlinked note or directory
    --- keeps its path inside the workspace.
    --- @param ws_root string normalized absolute workspace root
    --- @return string[] normalized absolute file paths
    list_source_files = function(ws_root)
        local files = {}
        -- Real paths of the directories on the current walk, to avoid symlink cycles.
        local ancestors = {}
        local function walk(dir, depth)
            local real = vim.uv.fs_realpath(dir)
            if not real or ancestors[real] or depth > 20 then
                return
            end
            ancestors[real] = true
            local handle = vim.uv.fs_scandir(dir)
            while handle do
                module.private.yield_if_needed()
                local name, kind = vim.uv.fs_scandir_next(handle)
                if not name then
                    break
                end
                local path = dir .. "/" .. name
                if kind == "link" or kind == nil then
                    local stat = vim.uv.fs_stat(path)
                    kind = stat and stat.type
                end
                if kind == "directory" then
                    walk(path, depth + 1)
                elseif kind == "file" and (name:sub(-5) == ".norg" or name:sub(-4) == ".bib") then
                    table.insert(files, path)
                end
            end
            ancestors[real] = nil
        end
        walk(ws_root, 1)
        table.sort(files)
        return files
    end,

    --- Path relative to the first root that contains it.
    --- @param path string normalized absolute path
    --- @param roots string[] normalized absolute workspace roots (e.g. unresolved and resolved)
    --- @return string|nil
    get_relative_path = function(path, roots)
        for _, root in ipairs(roots) do
            if vim.startswith(path, root .. "/") then
                return path:sub(#root + 2)
            end
        end
        return nil
    end,

    --- Return the usable enabled indexers with their absolute index directories.
    --- Indexers with an invalid `dir` are reported once and skipped.
    --- @param ws_root string normalized workspace root
    --- @return table[] list of { def, config, dir, dir_abs, per_file, list_notes }
    get_active_indexers = function(ws_root)
        local active = {}
        for _, ix in ipairs(indexers.configured(module.config.public)) do
            if ix.enabled then
                if ix.warning then
                    module.private.notify_once("external.indexer: " .. ix.warning, vim.log.levels.WARN)
                end
                if ix.error then
                    module.private.notify_once(
                        "external.indexer: " .. ix.error .. "; skipping the " .. indexers.full_title(ix.def) .. " index",
                        vim.log.levels.ERROR
                    )
                else
                    ix.dir_abs = vim.fs.normalize(ws_root .. "/" .. ix.dir)
                    table.insert(active, ix)
                end
            end
        end
        return active
    end,

    --- State of an indexer directory.
    --- @param dir_abs string absolute directory path
    --- @return string "missing", "empty", "marked" (contains the marker file), or "foreign"
    get_dir_state = function(dir_abs)
        local stat = vim.uv.fs_stat(dir_abs)
        if not stat then
            return "missing"
        end
        if stat.type ~= "directory" then
            return "foreign"
        end
        if indexers.has_marker(dir_abs) then
            return "marked"
        end
        local handle = vim.uv.fs_scandir(dir_abs)
        if handle and vim.uv.fs_scandir_next(handle) == nil then
            return "empty"
        end
        return "foreign"
    end,

    --- Delete a directory recursively, like `delete(dir, "rf")`, pausing time-sliced work between
    --- entries. Symbolic links are removed, not followed.
    --- @param dir string absolute directory path
    delete_tree = function(dir)
        local handle = vim.uv.fs_scandir(dir)
        while handle do
            module.private.yield_if_needed()
            local name, kind = vim.uv.fs_scandir_next(handle)
            if not name then
                break
            end
            local path = dir .. "/" .. name
            if kind == nil then
                local stat = vim.uv.fs_lstat(path)
                kind = stat and stat.type
            end
            if kind == "directory" then
                module.private.delete_tree(path)
            else
                vim.uv.fs_unlink(path)
            end
        end
        vim.uv.fs_rmdir(dir)
    end,

    --- Create an indexer directory and its marker file.
    --- @param dir_abs string absolute directory path
    write_marker = function(dir_abs)
        vim.fn.mkdir(dir_abs, "p")
        if not indexers.has_marker(dir_abs) then
            vim.fn.writefile({
                "This directory is generated by neorg-indexer.",
                "It is deleted and regenerated on full rebuilds. Do not store notes here.",
            }, dir_abs .. "/" .. indexers.marker)
        end
    end,

    --- Whether an indexer directory contains a file with a collision suffix ("name~2.norg").
    --- @param dir_abs string absolute directory path
    --- @return boolean
    has_collision_suffix = function(dir_abs)
        local found = vim.fs.find(function(name)
            return name:match("~%d+%.norg$") ~= nil
        end, { path = dir_abs, type = "file", limit = 1 })
        return #found > 0
    end,

    --- Whether a workspace-relative path is the main index file or inside a generated directory.
    --- @param rel string normalized path relative to the workspace root
    --- @param index_rel string normalized main index path relative to the workspace root
    --- @param dirs string[] normalized generated directories relative to the workspace root
    --- @return boolean
    is_generated_path = function(rel, index_rel, dirs)
        if rel == index_rel then
            return true
        end
        for _, dir in ipairs(dirs) do
            if rel == dir or vim.startswith(rel, dir .. "/") then
                return true
            end
        end
        return false
    end,

    --- Determine whether a path should be ignored for watcher-triggered updates.
    --- Called from libuv callbacks: uses only fast-safe functions.
    --- @param filename string normalized absolute file path
    --- @param ws_root string normalized workspace root
    --- @return boolean
    should_ignore_path = function(filename, ws_root)
        local roots = { ws_root, module.private.real_path(ws_root) }
        local rel = module.private.get_relative_path(filename, roots)
            or module.private.get_relative_path(module.private.real_path(filename), roots)
        if not rel then
            return false
        end
        return module.private.is_generated_path(
            rel,
            vim.fs.normalize(module.config.public.name),
            indexers.marked_dirs(module.config.public, ws_root)
        )
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

    --- Setup filesystem watchers for all workspaces to track .norg, .bib, and .pdf changes.
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
                            local lower = abs_path:lower()
                            if
                                not abs_path:match("%.norg$")
                                and not abs_path:match("%.bib$")
                                and not lower:match("%.pdf$")
                            then
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

    --- Read entire file contents using vim.uv (asynchronous).
    --- @param path string absolute file path
    --- @param callback fun(data: string|nil) called from a libuv callback; data is nil on error
    read_file_async = function(path, callback)
        -- The asynchronous forms return nil without calling back when a request cannot start.
        local function close(fd, data)
            local closing = vim.uv.fs_close(fd, function()
                callback(data)
            end)
            if not closing then
                callback(data)
            end
        end
        -- 438 is octal 0666 (rw-rw-rw-), the standard permission for files
        local opened = vim.uv.fs_open(path, "r", 438, function(open_err, fd)
            if open_err or not fd then
                callback(nil)
                return
            end
            local stat_started = vim.uv.fs_fstat(fd, function(stat_err, stat)
                if stat_err or not stat then
                    close(fd, nil)
                    return
                end
                local read_started = vim.uv.fs_read(fd, stat.size, 0, function(read_err, data)
                    close(fd, not read_err and data or nil)
                end)
                if not read_started then
                    close(fd, nil)
                end
            end)
            if not stat_started then
                close(fd, nil)
            end
        end)
        if not opened then
            callback(nil)
        end
    end,

    --- The loaded buffer of a file, if any.
    --- @param abs_path string normalized absolute file path
    --- @return number|nil bufnr
    loaded_buffer = function(abs_path)
        local bufnr = vim.fn.bufnr(abs_path)
        if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
            -- Verify the buffer actually corresponds to the requested file
            local buf_name = vim.fs.normalize(vim.fs.abspath(vim.api.nvim_buf_get_name(bufnr)))
            if buf_name == abs_path then
                return bufnr
            end
        end
        return nil
    end,

    --- Get a buffer suitable for treesitter operations on a file.
    --- If the buffer is already open and loaded, returns it directly.
    --- Otherwise, reads the file with vim.uv and creates a hidden scratch buffer
    --- with the content for treesitter parsing.
    --- @param abs_path string absolute file path
    --- @param content string|false|nil file contents already read (false: unreadable), read when nil
    --- @return number|nil bufnr buffer number, or nil if file can't be read
    --- @return boolean created_scratch true if a scratch buffer was created (caller should delete it)
    get_or_create_treesitter_buffer = function(abs_path, content)
        local bufnr = module.private.loaded_buffer(abs_path)
        if bufnr then
            return bufnr, false
        end

        -- Read file contents with vim.uv
        if content == nil then
            content = module.private.read_file_contents(abs_path)
        end
        if not content then
            return nil, false
        end

        -- Create a scratch buffer with the file content. Autocommands are skipped and no filetype is
        -- set: parsers are requested with an explicit language, and running FileType handlers
        -- (Neorg, highlighting, completion, ...) for every note would block the editor.
        local eventignore = vim.o.eventignore
        vim.o.eventignore = "all"
        local ok, scratch = pcall(vim.api.nvim_create_buf, false, true)
        if ok then
            ok, scratch = pcall(function()
                vim.api.nvim_buf_set_lines(scratch, 0, -1, false, vim.split(content, "\n", { plain = true }))
                return scratch
            end)
        end
        vim.o.eventignore = eventignore
        if not ok then
            error(scratch)
        end

        return scratch, true
    end,

    --- Path relative to the workspace root, without .norg extension, used in links.
    --- The leading "/" is intentional: combined with the "$" workspace anchor it
    --- produces links of the form {:$/path/to/file:}[Title].
    --- @param rel string normalized file path relative to the workspace root
    --- @return string
    get_norgname = function(rel)
        return "/" .. rel:gsub("%.norg$", "")
    end,

    --- Link target of an indexed file: a note ({:$/path:}) or a literature ({/ path.bib}).
    --- @param rel string normalized file path relative to the workspace root
    --- @return table|nil { kind, rel, norgname } where norgname identifies the entry
    get_link_target = function(rel)
        if rel:match("%.norg$") then
            return { kind = "note", rel = rel, norgname = module.private.get_norgname(rel) }
        elseif rel:match("%.bib$") then
            return { kind = "literature", rel = rel, norgname = "/" .. rel }
        end
        return nil
    end,

    --- Link location of a file in a `{/ ...}` link written in another workspace file.
    --- Neorg does not expand `$` in file links: relative paths are resolved from the directory of
    --- the file that contains the link.
    --- @param host_rel string path of the file containing the link, relative to the workspace root
    --- @param to_rel string path of the linked file, relative to the workspace root
    --- @return string
    get_file_link = function(host_rel, to_rel)
        local from_dir = vim.fn.fnamemodify(host_rel, ":h")
        local from_parts = (from_dir == "." or from_dir == "") and {} or vim.split(from_dir, "/", { plain = true })
        local to_parts = vim.split(to_rel, "/", { plain = true })
        local common = 0
        -- Only directories are shared; the last part of to_rel is the file name.
        while common < #from_parts and common < #to_parts - 1 and from_parts[common + 1] == to_parts[common + 1] do
            common = common + 1
        end
        local parts = {}
        for _ = common + 1, #from_parts do
            table.insert(parts, "..")
        end
        vim.list_extend(parts, to_parts, common + 1)
        local link = table.concat(parts, "/")
        -- A leading "~" would be read as the home directory.
        if link:sub(1, 1) == "~" then
            link = "./" .. link
        end
        return link
    end,

    --- Text that identifies a link to a target in a generated file.
    --- @param target table from get_link_target (or an entry)
    --- @param host_rel string path of the generated file, relative to the workspace root
    --- @return string
    get_link_token = function(target, host_rel)
        if target.kind == "literature" then
            return "{/ " .. module.private.get_file_link(host_rel, target.rel) .. "}"
        end
        return "{:$" .. target.norgname .. ":}"
    end,

    --- Escape text for a Norg heading or link description.
    --- @param text string
    --- @return string
    escape = function(text)
        return (text:gsub("[\\%[%]]", "\\%0"))
    end,

    --- Remove Norg backslash escapes.
    --- @param text string
    --- @return string
    unescape = function(text)
        return (text:gsub("\\(.)", "%1"))
    end,

    --- Collect entries from norg and bib files. Metadata is read once and shared by all indexers.
    --- Paths are not resolved: a symlinked note is indexed under its path in the workspace.
    --- Files are read with libuv, a bounded number at a time, and parsed on the main loop in their
    --- order, so entries are deterministic.
    --- @param files string[] list of absolute file paths
    --- @param roots string[] normalized workspace roots (unresolved first, then resolved)
    --- @param index_rel string main index path relative to the workspace root
    --- @param skip_dirs string[] generated directories relative to the workspace root
    --- @param expected_writes integer|nil estimated number of files to write, defaults to #files
    --- @param progress table progress notification, advanced per collected file
    --- @param on_done fun(entries: table[]|nil, err: string|nil) called once, on the main loop
    collect_entries_async = function(files, roots, index_rel, skip_dirs, expected_writes, progress, on_done)
        local items = module.private.source_items(files, roots, index_rel, skip_dirs)
        progress:add_total(#items)
        -- Files to write are counted once the trees are built; until then assume as many as the
        -- last run wrote, or about as many as files to read.
        progress:expect(expected_writes or #items)
        local entries = {}
        local state = {}
        -- contents[i] is the content of items[i] (false: unreadable, nil: read from its buffer);
        -- ready[i] is true once it is available.
        local contents, ready = {}, {}
        local next_read, next_parse, in_flight = 1, 1, 0
        local finished = false
        local parse_deferred = false

        local function finish(result, err)
            if not finished then
                finished = true
                on_done(result, err)
            end
        end
        -- Run a step of the collection; an error ends it.
        local function guard(step)
            local ok, err = pcall(step)
            if not ok then
                finish(nil, tostring(err))
            end
        end

        local function parse_ready()
            if parse_deferred then
                return
            end
            local started = vim.uv.hrtime()
            local parsed = 0
            while not finished and ready[next_parse] do
                -- At least one file is parsed per slice.
                if parsed > 0 and module.private.slice_expired(started) then
                    -- Let the editor handle input and redraw before parsing more.
                    parse_deferred = true
                    module.private.defer(function()
                        parse_deferred = false
                        guard(parse_ready)
                    end)
                    return
                end
                local i = next_parse
                next_parse = i + 1
                local content = contents[i]
                contents[i] = nil
                parsed = parsed + 1
                local entry = module.private.collect_entry(items[i], content, state)
                if entry then
                    table.insert(entries, entry)
                end
                progress:advance()
            end
            if next_parse > #items then
                finish(entries)
            end
        end

        local function pump()
            while not finished and in_flight < module.private.read_concurrency and next_read <= #items do
                local i = next_read
                next_read = i + 1
                local item = items[i]
                if not item.rel:match("%.bib$") and module.private.loaded_buffer(item.abs_path) then
                    ready[i] = true
                else
                    in_flight = in_flight + 1
                    module.private.read_file_async(item.abs_path, function(data)
                        vim.schedule(function()
                            guard(function()
                                in_flight = in_flight - 1
                                contents[i] = data or false
                                ready[i] = true
                                pump()
                                parse_ready()
                            end)
                        end)
                    end)
                end
            end
        end

        vim.schedule(function()
            guard(function()
                pump()
                parse_ready()
            end)
        end)
    end,

    --- Source files to collect entries from, in order, as { abs_path, rel } items.
    --- @param files string[] list of absolute file paths
    --- @param roots string[] normalized workspace roots (unresolved first, then resolved)
    --- @param index_rel string main index path relative to the workspace root
    --- @param skip_dirs string[] generated directories relative to the workspace root
    --- @return table[] items
    source_items = function(files, roots, index_rel, skip_dirs)
        local items = {}
        for _, file in ipairs(files) do
            local abs_path = vim.fs.normalize(vim.fs.abspath(tostring(file)))
            local rel = module.private.get_relative_path(abs_path, roots)
            -- Skip files outside the workspace, the main index file, and generated index directories
            if rel and not module.private.is_generated_path(rel, index_rel, skip_dirs) then
                table.insert(items, { abs_path = abs_path, rel = rel })
            end
        end
        return items
    end,

    --- Collect the entry of one source file.
    --- @param item table { abs_path, rel } from `source_items`
    --- @param content string|false|nil file contents already read (false: unreadable), read when nil
    --- @param state table shared by the files of one collection
    --- @return table|nil entry
    collect_entry = function(item, content, state)
        local ts = module.required["core.integrations.treesitter"]
        local abs_path, rel = item.abs_path, item.rel

        if rel:match("%.bib$") then
            if state.bib_available == nil then
                state.bib_available = bibtex.available()
                if not state.bib_available then
                    bibtex.warn_unavailable(utils.notify)
                end
            end
            if state.bib_available then
                return module.private.collect_literature(abs_path, rel, content)
            end
            return nil
        end

        -- Get a buffer for treesitter (existing or scratch)
        local bufnr, created_scratch = module.private.get_or_create_treesitter_buffer(abs_path, content)
        if not bufnr then
            return nil
        end

        -- Delete the scratch buffer even when parsing fails.
        local ok, metadata = pcall(ts.get_document_metadata, bufnr)
        if created_scratch then
            module.private.safe_buf_delete(bufnr)
        end
        if not ok then
            error(metadata, 0)
        end
        metadata = metadata or {}

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

        return {
            kind = "note",
            abs_path = abs_path,
            rel = rel,
            title = title,
            norgname = module.private.get_norgname(rel),
            description = description,
            created = type(created) == "string" and created or nil,
            updated = type(updated) == "string" and updated or nil,
            metadata = norm_meta,
        }
    end,

    --- Read the literature entry of a .bib file: its first BibTeX entry.
    --- @param abs_path string normalized absolute path
    --- @param rel string path relative to the workspace root
    --- @param source string|false|nil file contents already read (false: unreadable), read when nil
    --- @return table|nil entry, nil when the file has no entry
    collect_literature = function(abs_path, rel, source)
        if source == nil then
            source = module.private.read_file_contents(abs_path)
        end
        if not source then
            return nil
        end
        local item = bibtex.read(source, abs_path)
        if not item then
            return nil
        end
        if item.extra > 0 then
            module.private.notify_once(
                "external.indexer: "
                    .. rel
                    .. " contains "
                    .. (item.extra + 1)
                    .. " BibTeX entries; only the first one ("
                    .. item.citekey
                    .. ") is indexed",
                vim.log.levels.WARN
            )
        end
        local metadata = item.metadata
        return {
            kind = "literature",
            abs_path = abs_path,
            rel = rel,
            title = metadata.title,
            norgname = "/" .. rel,
            citekey = item.citekey,
            pdf = item.pdf,
            pdf_candidates = item.pdf_candidates,
            description = metadata.description,
            created = metadata.created,
            updated = metadata.updated,
            metadata = metadata,
        }
    end,

    --- Map PDF paths named by literatures' `file` fields to the .bib files that name them.
    --- @param entries table[]
    --- @return table<string, string[]>
    build_pdf_bibs = function(entries)
        local result = {}
        local function add(path, bib)
            result[path] = result[path] or {}
            if not vim.tbl_contains(result[path], bib) then
                table.insert(result[path], bib)
            end
        end
        for _, entry in ipairs(entries) do
            for _, path in ipairs(entry.pdf_candidates or {}) do
                add(path, entry.abs_path)
                add(module.private.real_path(path), entry.abs_path)
            end
        end
        return result
    end,

    --- Return the bucket paths of an entry for an indexer, using the fallback bucket when empty.
    --- Literatures use `literature_fallback` instead of `fallback` when the indexer has one.
    --- @param ix table active indexer
    --- @param entry table
    --- @return string[][] bucket paths (lists of raw parts)
    --- @return boolean is_fallback
    get_bucket_paths = function(ix, entry)
        if ix.def.literature_only and entry.kind ~= "literature" then
            return {}, false
        end
        local paths = ix.def.values(entry.metadata, ix.config)
        if #paths > 0 then
            return paths, false
        end
        local fallback = ix.config.fallback
        local literature_fallback = ix.config.literature_fallback
        if entry.kind == "literature" and literature_fallback and literature_fallback ~= "" then
            fallback = literature_fallback
        end
        if fallback == nil or fallback == false or fallback == "" then
            return {}, false
        end
        return { { tostring(fallback) } }, true
    end,

    --- Create an empty tree node.
    new_node = function()
        return { children = {}, entries = {}, child_order = {} }
    end,

    --- Assign a unique file name to every child of a node, recursively.
    --- Names are encoded with indexers.encode_part. Siblings whose names differ only by case
    --- would share a file on case-insensitive file systems: in sorted order of their raw names,
    --- the first keeps its name and the others get "~2", "~3", ... suffixes.
    --- @param node table
    --- @param root table tree root, flagged with has_collisions when any suffix is used
    assign_file_names = function(node, root)
        local groups = {}
        for _, name in ipairs(node.child_order) do
            local encoded = indexers.encode_part(name)
            local folded = vim.fn.tolower(encoded)
            groups[folded] = groups[folded] or {}
            table.insert(groups[folded], name)
        end
        for _, names in pairs(groups) do
            table.sort(names)
            for i, name in ipairs(names) do
                local file_name = indexers.encode_part(name)
                if i > 1 then
                    file_name = file_name .. "~" .. i
                    root.has_collisions = true
                end
                node.children[name].file_name = file_name
            end
        end
        for _, name in ipairs(node.child_order) do
            module.private.assign_file_names(node.children[name], root)
        end
    end,

    --- Build a bucket tree for an indexer and store it as `ix.tree`.
    --- Each node has: children (map), child_order (list), entries (list), fallback (boolean),
    --- and file_name (string, except for the root).
    --- @param ix table active indexer
    --- @param entries table[]
    --- @return table tree root node
    build_tree = function(ix, entries)
        local tree = module.private.new_node()
        for _, entry in ipairs(entries) do
            local paths, is_fallback = module.private.get_bucket_paths(ix, entry)
            for _, parts in ipairs(paths) do
                local node = tree
                for _, part in ipairs(parts) do
                    if not node.children[part] then
                        node.children[part] = module.private.new_node()
                        table.insert(node.child_order, part)
                    end
                    node = node.children[part]
                end
                node.fallback = node.fallback or is_fallback
                table.insert(node.entries, entry)
            end
        end
        module.private.assign_file_names(tree, tree)
        ix.tree = tree
        return tree
    end,

    --- Key of a bucket: its file path relative to the indexer directory, without extension.
    --- @param ix table active indexer, with the tree built by build_tree
    --- @param path_parts string[] raw bucket path
    --- @return string
    get_bucket_key = function(ix, path_parts)
        local names = {}
        local node = ix.tree
        for _, part in ipairs(path_parts) do
            node = node and node.children[part]
            table.insert(names, node and node.file_name or indexers.encode_part(part))
        end
        return table.concat(names, "/")
    end,

    --- Get the relative file path (from workspace root) for a bucket index.
    --- Always: <dir>/<path...>/<name>.norg
    --- @param ix table active indexer
    --- @param path_parts string[] raw bucket path
    --- @return string
    get_bucket_rel_path = function(ix, path_parts)
        return ix.dir .. "/" .. module.private.get_bucket_key(ix, path_parts) .. ".norg"
    end,

    --- Display name of a bucket.
    --- @param ix table active indexer
    --- @param path_parts string[] raw bucket path
    --- @return string
    get_bucket_label = function(ix, path_parts)
        return module.private.escape(ix.def.label(path_parts, ix.config))
    end,

    --- Collect the keys of all buckets in a tree.
    --- @param ix table active indexer
    --- @param tree table
    --- @return table set of bucket keys
    collect_bucket_keys = function(ix, tree)
        local keys = {}
        local function walk(node, path_parts)
            for _, child_name in ipairs(node.child_order) do
                local child_path_parts = vim.list_extend({}, path_parts)
                table.insert(child_path_parts, child_name)
                keys[module.private.get_bucket_key(ix, child_path_parts)] = true
                walk(node.children[child_name], child_path_parts)
            end
        end
        walk(tree, {})
        return keys
    end,

    --- Find buckets whose index files currently link to any of the given notes or literatures.
    --- @param ix table active indexer
    --- @param targets table[] link targets from get_link_target
    --- @return table map of bucket keys -> true
    find_buckets_for_targets = function(ix, targets)
        local results = {}
        if #targets == 0 or vim.fn.isdirectory(ix.dir_abs) ~= 1 then
            return results
        end
        local files = vim.fs.find(function(name, _)
            return name:sub(-5) == ".norg"
        end, { path = ix.dir_abs, type = "file", limit = math.huge })
        for _, abs_path in ipairs(files) do
            local content = module.private.read_file_contents(abs_path)
            if content then
                local key = vim.fs.normalize(abs_path):sub(#ix.dir_abs + 2):gsub("%.norg$", "")
                local host_rel = ix.dir .. "/" .. key .. ".norg"
                for _, target in ipairs(targets) do
                    if content:find(module.private.get_link_token(target, host_rel), 1, true) then
                        results[key] = true
                        break
                    end
                end
            end
        end
        return results
    end,

    --- Find buckets affected by changed notes: their new and old buckets plus all ancestors.
    --- @param ix table active indexer
    --- @param entries table[]
    --- @param changed_set table map of normalized absolute file paths that changed
    --- @param changed_targets table[] link targets of changed notes and literatures
    --- @return table map of bucket keys -> true
    find_affected_buckets = function(ix, entries, changed_set, changed_targets)
        local affected = {}
        for _, entry in ipairs(entries) do
            if changed_set[entry.abs_path] or changed_set[module.private.real_path(entry.abs_path)] then
                -- Keys of the bucket and its ancestors, from the raw parts: a part may contain
                -- the subcategory separator or "/" and is not split again.
                for _, parts in ipairs((module.private.get_bucket_paths(ix, entry))) do
                    for i = 1, #parts do
                        affected[module.private.get_bucket_key(ix, vim.list_slice(parts, 1, i))] = true
                    end
                end
            end
        end
        -- Keys of existing files are file paths: encoded names never contain "/".
        for key in pairs(module.private.find_buckets_for_targets(ix, changed_targets)) do
            local acc = {}
            for _, name in ipairs(vim.split(key, "/", { plain = true })) do
                table.insert(acc, name)
                affected[table.concat(acc, "/")] = true
            end
        end
        return affected
    end,

    --- Delete bucket files that no longer exist in the tree, and directories left empty.
    --- @param ix table active indexer
    --- @param tree table
    --- @param affected table map of bucket keys
    delete_obsolete_bucket_files = function(ix, tree, affected)
        if not indexers.has_marker(ix.dir_abs) then
            return
        end
        -- Compare case-insensitively: on a case-insensitive file system, an obsolete key that
        -- differs only by case from a valid one names the same, still valid, file.
        local existing = {}
        for key in pairs(module.private.collect_bucket_keys(ix, tree)) do
            existing[indexers.fold_case(key)] = true
        end
        for key in pairs(affected) do
            if not existing[indexers.fold_case(key)] then
                local abs_path = ix.dir_abs .. "/" .. key
                if vim.fn.filereadable(abs_path .. ".norg") == 1 then
                    vim.fn.delete(abs_path .. ".norg")
                end
                -- Remove now-empty directories; fs_rmdir fails harmlessly on non-empty ones.
                local dir = abs_path
                while dir ~= ix.dir_abs and vim.startswith(dir, ix.dir_abs .. "/") do
                    if vim.fn.isdirectory(dir) == 1 and not vim.uv.fs_rmdir(dir) then
                        break
                    end
                    dir = vim.fn.fnamemodify(dir, ":h")
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

    --- Format a list of entries as heading link lines (list items beyond the deepest heading level).
    --- Notes link to `{:$/path:}`. Literatures link to their .bib file with a path relative to the
    --- generated file, with a `[citekey]` prefix and a trailing `[PDF]` link to the PDF when there is
    --- one. Both brackets of the prefix and of `[PDF]` are escaped so that they display literally.
    --- @param ix table active indexer
    --- @param entries table[]
    --- @param heading_level integer
    --- @param host_rel string path of the generated file, relative to the workspace root
    --- @return string[]
    format_entry_lines = function(ix, entries, heading_level, host_rel)
        local title_formatter = ix.config.title_formatter or default_title_formatter
        local escape = module.private.escape
        local lines = {}
        for _, entry in ipairs(entries) do
            local display_title = escape(tostring(title_formatter(entry.metadata)))
            local line
            if entry.kind == "literature" then
                line = indexers.heading_prefix(heading_level)
                    .. " "
                    .. module.private.get_link_token(entry, host_rel)
                    .. "[\\["
                    .. escape(entry.citekey)
                    .. "\\] "
                    .. display_title
                    .. "]"
                if entry.pdf then
                    local pdf_rel = module.private.get_relative_path(entry.pdf, {
                        entry.abs_path:sub(1, #entry.abs_path - #entry.rel - 1),
                    })
                    if pdf_rel then
                        line = line .. " {/ " .. module.private.get_file_link(host_rel, pdf_rel) .. "}[\\[PDF\\]]"
                    else
                        line = line .. " {/ " .. entry.pdf .. "}[\\[PDF\\]]"
                    end
                end
            else
                line = indexers.heading_prefix(heading_level)
                    .. " {:$"
                    .. entry.norgname
                    .. ":}["
                    .. display_title
                    .. "]"
            end
            table.insert(lines, line)
        end
        return lines
    end,

    --- Sort entries based on the indexer config (sort_by and sort_direction).
    sort_entries = function(ix, entries)
        local sort_by = ix.config.sort_by
        local ascending = ix.config.sort_direction == "ascending"

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
            if va ~= vb then
                if ascending then
                    return va < vb
                end
                return va > vb
            end
            -- Deterministic tie-break: lowercased title, then norgname.
            local ta, tb = a.title:lower(), b.title:lower()
            if ta ~= tb then
                return ta < tb
            end
            return a.norgname < b.norgname
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

    --- Deduplicate and sort entries for display.
    prepare_entries = function(ix, entries)
        local result = module.private.deduplicate_entries(entries)
        module.private.sort_entries(ix, result)
        return result
    end,

    --- Sort child bucket names alphabetically (case-insensitive), respecting sort_direction.
    --- The fallback bucket always comes last.
    --- @param ix table active indexer
    --- @param node table
    --- @return string[] sorted child names
    sort_children = function(ix, node)
        local names = vim.list_extend({}, node.child_order)
        local ascending = ix.config.sort_direction == "ascending"
        table.sort(names, function(a, b)
            local fa, fb = node.children[a].fallback == true, node.children[b].fallback == true
            if fa ~= fb then
                return fb
            end
            local la, lb = a:lower(), b:lower()
            if la == lb then
                -- Deterministic order for names that differ only by case.
                return a < b
            end
            if ascending then
                return la < lb
            end
            return la > lb
        end)
        return names
    end,

    --- Generate the lines of an indexer's section in the main index.
    --- In per-file mode, top-level buckets become headings that link to their index files.
    --- An indexer without buckets has no section. A grouped indexer's section is one level deeper.
    --- @param ix table active indexer
    --- @param tree table
    --- @param index_rel string main index path relative to the workspace root
    --- @return string[]|nil nil when the tree has no buckets
    generate_section_lines = function(ix, tree, index_rel)
        if not module.private.has_children(tree) then
            return nil
        end
        local level = ix.def.group and 3 or 2
        local lines = { string.rep("*", level) .. " " .. ix.def.title }
        if not ix.per_file then
            vim.list_extend(lines, module.private.generate_tree_lines(ix, tree, {}, level + 1, index_rel))
            return lines
        end

        for _, child_name in ipairs(module.private.sort_children(ix, tree)) do
            local rel_path = module.private.get_bucket_rel_path(ix, { child_name })
            local rel_norgname = module.private.get_relative_norgname(index_rel, rel_path)
            local label = module.private.get_bucket_label(ix, { child_name })
            table.insert(lines, string.rep("*", level + 1) .. " {:" .. rel_norgname .. ":}[" .. label .. "]")
        end

        if ix.list_notes then
            -- "Notes" heading with all descendant entries flattened
            local all_entries = module.private.prepare_entries(ix, module.private.collect_all_entries(tree))
            if #all_entries > 0 then
                table.insert(lines, string.rep("*", level + 1) .. " Notes")
                vim.list_extend(lines, module.private.format_entry_lines(ix, all_entries, level + 2, index_rel))
            end
        end

        return lines
    end,

    --- Generate tree lines for inline mode (per-file index disabled).
    --- Recursively generate the full bucket tree with notes listed under
    --- their corresponding bucket (not flattened). No "Notes" heading. Levels deeper than Norg
    --- headings allow become nested list items (see indexers.heading_prefix).
    --- `host_rel` is the path of the file that contains the lines, relative to the workspace root.
    generate_tree_lines = function(ix, node, path_parts, heading_level, host_rel)
        local result = {}
        for _, child_name in ipairs(module.private.sort_children(ix, node)) do
            local child = node.children[child_name]
            local child_path_parts = vim.list_extend({}, path_parts)
            table.insert(child_path_parts, child_name)

            -- Bucket heading
            table.insert(
                result,
                indexers.heading_prefix(heading_level) .. " " .. module.private.get_bucket_label(ix, child_path_parts)
            )

            -- Direct entries of this bucket
            local entries = module.private.prepare_entries(ix, vim.list_extend({}, child.entries))
            vim.list_extend(result, module.private.format_entry_lines(ix, entries, heading_level + 1, host_rel))

            -- Recurse into sub-buckets
            if module.private.has_children(child) then
                vim.list_extend(
                    result,
                    module.private.generate_tree_lines(ix, child, child_path_parts, heading_level + 1, host_rel)
                )
            end
        end
        return result
    end,

    --- Generate all bucket index contents for an indexer.
    --- @param ix table active indexer
    --- @param tree table
    --- @param affected table|nil map of bucket keys to include
    --- @param index_rel string main index path relative to the workspace root
    --- @return table map of relative_path -> content_string
    generate_bucket_files = function(ix, tree, affected, index_rel)
        local files = {}

        local function generate_node(node, path_parts)
            local rel_path = module.private.get_bucket_rel_path(ix, path_parts)
            local heading_level = 1
            local child_heading_level = heading_level + 1
            local lines = {
                string.rep("*", heading_level) .. " " .. module.private.get_bucket_label(ix, path_parts),
                "",
            }

            -- Compute parent link (relative)
            local parent_rel_path, parent_name
            if #path_parts == 1 then
                -- Top-level bucket: parent is the main index file
                parent_rel_path = index_rel
                parent_name = module.private.escape((index_rel:gsub("%.norg$", "")))
            else
                -- Sub-bucket: parent is the parent bucket file
                local parent_path_parts = vim.list_slice(path_parts, 1, #path_parts - 1)
                parent_rel_path = module.private.get_bucket_rel_path(ix, parent_path_parts)
                parent_name = module.private.get_bucket_label(ix, parent_path_parts)
            end
            local parent_rel_norgname = module.private.get_relative_norgname(rel_path, parent_rel_path)
            local parent_link_line = string.rep("*", child_heading_level)
                .. " {:"
                .. parent_rel_norgname
                .. ":}[󰜱 "
                .. parent_name
                .. "]"

            -- Headings linking to child files
            local heading_lines = {}
            for _, child_name in ipairs(module.private.sort_children(ix, node)) do
                local child_path_parts = vim.list_extend({}, path_parts)
                table.insert(child_path_parts, child_name)
                local child_rel_path = module.private.get_bucket_rel_path(ix, child_path_parts)
                local rel_norgname = module.private.get_relative_norgname(rel_path, child_rel_path)
                table.insert(
                    heading_lines,
                    string.rep("*", child_heading_level)
                        .. " {:"
                        .. rel_norgname
                        .. ":}["
                        .. module.private.get_bucket_label(ix, child_path_parts)
                        .. "]"
                )
            end

            if module.private.has_children(node) and ix.list_notes then
                -- Sub-bucket headings, then the parent link as the last heading
                vim.list_extend(lines, heading_lines)
                table.insert(lines, parent_link_line)

                -- "Notes" heading with all entries (direct + descendants) flattened
                local all_entries = module.private.prepare_entries(ix, module.private.collect_all_entries(node))
                if #all_entries > 0 then
                    vim.list_extend(lines, { "", string.rep("*", heading_level) .. " Notes", "" })
                    vim.list_extend(
                        lines,
                        module.private.format_entry_lines(ix, all_entries, heading_level + 1, rel_path)
                    )
                end
            else
                -- Only direct entries, then child headings, then the parent link as the last heading
                local entries = module.private.prepare_entries(ix, vim.list_extend({}, node.entries))
                vim.list_extend(lines, module.private.format_entry_lines(ix, entries, heading_level + 1, rel_path))
                vim.list_extend(lines, heading_lines)
                table.insert(lines, parent_link_line)
            end

            local content = table.concat(lines, "\n") .. "\n"

            if not affected or affected[module.private.get_bucket_key(ix, path_parts)] then
                files[rel_path] = content
            end

            -- Recurse into children
            for _, child_name in ipairs(node.child_order) do
                local child_path_parts = vim.list_extend({}, path_parts)
                table.insert(child_path_parts, child_name)
                generate_node(node.children[child_name], child_path_parts)
            end
        end

        for _, child_name in ipairs(tree.child_order) do
            generate_node(tree.children[child_name], { child_name })
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
        -- `module.required[...]` only exposes the public API, not the config.
        return modules.get_module_config("core.esupports.metagen") or {}
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
        -- The asynchronous forms return nil and an error without calling back when a request
        -- cannot start.
        local function close(fd, write_err)
            local function done(close_err)
                if write_err then
                    callback("Failed to write " .. path .. ": " .. tostring(write_err))
                elseif close_err then
                    callback("Failed to close " .. path .. ": " .. tostring(close_err))
                else
                    callback(nil)
                end
            end
            local closing, close_err = vim.uv.fs_close(fd, done)
            if not closing then
                done(close_err or "unknown error")
            end
        end
        -- 438 is octal 0666 (rw-rw-rw-), the standard permission for new files
        local opened, err = vim.uv.fs_open(path, "w", 438, function(open_err, fd)
            if open_err or not fd then
                callback("Failed to open " .. path .. ": " .. tostring(open_err))
                return
            end
            local writing, write_err = vim.uv.fs_write(fd, content, nil, function(async_write_err, _)
                close(fd, async_write_err)
            end)
            if not writing then
                close(fd, write_err or "unknown error")
            end
        end)
        if not opened then
            callback("Failed to open " .. path .. ": " .. tostring(err))
        end
    end,

    --- Write multiple files asynchronously. on_progress() is called after each file and
    --- on_done(errors) once all are written; errors lists the failures (empty on success).
    --- Both are called from libuv callbacks.
    write_files_async = function(files, on_done, on_progress)
        if #files == 0 then
            on_done({})
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
                if on_progress then
                    on_progress()
                end
                if completed == #files then
                    on_done(errors)
                end
            end)
        end
    end,
}

module.on_event = function(event)
    if event.type == "core.neorgcmd.events.indexer.search" then
        vim.schedule(function()
            module.public.search()
        end)
        return
    end

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

        if module.config.public.index_on_change then
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

    if module.config.public.index_on_change then
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
        ["indexer.search"] = true,
    },
    ["core.dirman"] = {
        ["workspace_changed"] = true,
        ["file_created"] = true,
    },
}

return module
