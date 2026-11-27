-- Progress notification tests: the replace chain, the delay, the native progress fallback,
-- coalescing of overlapping runs, and errors.
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local root = vim.fn.tempname()
local function run()
    local plugins = vim.env.NEORG_TEST_PLUGINS or (vim.fn.stdpath("data") .. "/lazy")
    for _, name in ipairs({ "neorg", "lua-utils.nvim", "nvim-nio", "nui.nvim", "pathlib.nvim" }) do
        vim.opt.runtimepath:append(plugins .. "/" .. name)
    end
    -- Metadata is read with treesitter: register the norg parsers installed by lazy.nvim.
    local rocks = vim.env.NEORG_TEST_ROCKS or (vim.fn.stdpath("data") .. "/lazy-rocks")
    for _, lang in ipairs({ "norg", "norg_meta" }) do
        local ok_lang, loaded = pcall(vim.treesitter.language.add, lang)
        if not ok_lang or not loaded then
            local parser = vim.fn.glob(rocks .. "/tree-sitter-*/lib/lua/5.1/parser/" .. lang .. ".so", false, true)[1]
            assert(parser, "tree-sitter parser not found: " .. lang)
            vim.treesitter.language.add(lang, { path = parser })
        end
    end
    local ws = root .. "/workspace"
    vim.fn.mkdir(ws, "p")
    for i = 1, 40 do
        vim.fn.writefile({
            "@document.meta",
            "title: Note " .. i,
            "categories: c" .. (i % 5),
            "@end",
            "",
            "body",
        }, ws .. "/n" .. i .. ".norg")
    end

    local notify = vim.notify
    require("neorg").setup({
        load = {
            ["core.neorgcmd"] = {},
            ["core.dirman"] = { config = { workspaces = { notes = ws }, default_workspace = "notes" } },
            ["core.integrations.treesitter"] = { config = { configure_parsers = false } },
            ["external.indexer"] = { config = { index_on_change = false } },
        },
    })
    local modules = require("neorg.core").modules
    local indexer = assert(modules.get_module("external.indexer"))
    local config = modules.get_module_config("external.indexer")
    local private = require("neorg.modules.external.indexer.module").private
    local ws_norm = vim.fs.normalize(vim.fs.abspath(ws))
    local final = "Index generated at " .. ws_norm .. "/index.norg"

    local function await(description, predicate)
        assert(vim.wait(10000, predicate, 10), "timed out waiting for " .. description)
    end

    -- Slow reads down so that runs outlast several renders.
    local read_file_async = private.read_file_async
    local function slow_reads(enabled)
        private.read_file_async = enabled
                and function(path, callback)
                    read_file_async(path, function(data)
                        vim.defer_fn(function()
                            callback(data)
                        end, 150)
                    end)
                end
            or read_file_async
    end

    -- vim.notify stub returning a record, like nvim-notify.
    local calls
    local function record_notify()
        calls = {}
        vim.notify = function(message, level, opts)
            local record = { index = #calls + 1 }
            table.insert(calls, { message = message, level = level, opts = opts or {}, record = record })
            return record
        end
    end
    local function percent_of(message)
        local percent, done, total = message:match("Indexing notes ▕.-▏ (%d+)%% %((%d+)/(%d+)%)$")
        return tonumber(percent), tonumber(done), tonumber(total)
    end
    -- Every update after the first replaces the previous one, with the same id.
    local function assert_replace_chain()
        assert(#calls >= 2, vim.inspect(calls))
        assert(calls[1].opts.replace == nil, vim.inspect(calls[1]))
        for i, call in ipairs(calls) do
            assert(call.opts.title == "Neorg", vim.inspect(call))
            assert(call.opts.id == "neorg.indexer.progress." .. ws_norm, vim.inspect(call))
            if i > 1 then
                assert(call.opts.replace == calls[i - 1].record, "update " .. i .. " does not replace the previous")
            end
        end
    end
    local function index(opts)
        local result = nil
        opts = opts or {}
        opts.on_done = function(err)
            result = { err = err }
        end
        indexer.index("notes", opts)
        await("index generation", function()
            return result ~= nil
        end)
        return result.err
    end

    -- The bar replaces itself, its percentage never decreases, and the final message replaces it.
    config.progress.delay_ms = 0
    slow_reads(true)
    record_notify()
    assert(index() == nil)
    assert_replace_chain()
    local bars, last = 0, -1
    for i = 1, #calls - 1 do
        local message = calls[i].message
        local percent, done, total = percent_of(message)
        assert(percent, "not a progress bar: " .. message)
        local spinner = message:match("^(.-) Indexing notes")
        assert(vim.tbl_contains(require("neorg.modules.external.indexer.progress").spinner, spinner), message)
        assert(vim.fn.strchars(message:match("▕(.-)▏")) == 10, message)
        assert(done <= total and total >= 40, message)
        assert(percent >= last, "percentage decreased: " .. vim.inspect(calls))
        assert(calls[i].opts.timeout == false, vim.inspect(calls[i]))
        last = percent
        bars = bars + 1
    end
    assert(bars >= 2, vim.inspect(calls))
    assert(calls[#calls].message == "✓ " .. final, calls[#calls].message)
    -- An explicit timeout: nvim-notify would otherwise inherit `false` from the bar it replaces.
    assert(calls[#calls].opts.timeout == require("neorg.modules.external.indexer.progress").final_timeout_ms)
    assert(calls[#calls].opts.hide_from_history == false)
    assert(vim.fn.filereadable(ws .. "/index/categories/c1.norg") == 1)
    assert(vim.tbl_isempty(private.index_runs))

    -- A run that finishes before the delay only shows the final message.
    config.progress.delay_ms = 60000
    slow_reads(false)
    record_notify()
    assert(index() == nil)
    assert(#calls == 1 and calls[1].message == final, vim.inspect(calls))
    assert(calls[1].opts.replace == nil and calls[1].opts.id == nil, vim.inspect(calls))

    -- Without the bar, only the final message is shown.
    config.progress = { enabled = false, delay_ms = 0 }
    slow_reads(true)
    record_notify()
    assert(index() == nil)
    assert(#calls == 1 and calls[1].message == final, vim.inspect(calls))
    config.progress = { enabled = true, delay_ms = 0 }
    -- `progress = false` disables the bar too.
    config.progress = false
    record_notify()
    assert(index() == nil)
    assert(#calls == 1 and calls[1].message == final, vim.inspect(calls))
    config.progress = { enabled = true, delay_ms = 0 }

    -- When vim.notify returns no record, updates are native progress messages.
    local nvim_echo = vim.api.nvim_echo
    local echoes = {}
    vim.api.nvim_echo = function(chunks, history, opts)
        table.insert(echoes, { text = chunks[1][1], history = history, opts = opts })
        return "echo-id"
    end
    record_notify()
    local stub = vim.notify
    vim.notify = function(...)
        stub(...)
        return nil
    end
    local ok, err = pcall(index)
    vim.api.nvim_echo = nvim_echo
    assert(ok, err)
    assert(err == nil)
    -- The first update went through vim.notify, the others through nvim_echo.
    assert(#calls == 1 and percent_of(calls[1].message), vim.inspect(calls))
    assert(#echoes >= 2, vim.inspect(echoes))
    for i, echo in ipairs(echoes) do
        assert(echo.opts.kind == "progress" and echo.opts.title == "Neorg", vim.inspect(echo))
        assert(echo.opts.id == (i > 1 and "echo-id" or nil), vim.inspect(echoes))
        if i < #echoes then
            assert(echo.opts.status == "running" and echo.history == false, vim.inspect(echo))
            assert(percent_of(echo.text) == echo.opts.percent, vim.inspect(echo))
        end
    end
    local last_echo = echoes[#echoes]
    assert(last_echo.text == "✓ " .. final, vim.inspect(last_echo))
    assert(last_echo.opts.status == "success" and last_echo.opts.percent == 100, vim.inspect(last_echo))
    assert(last_echo.history == true)

    -- Requests made during a run are merged into exactly one follow-up run, in the same notification.
    local runs = 0
    local run_index = private.run_index
    private.run_index = function(...)
        runs = runs + 1
        return run_index(...)
    end
    record_notify()
    local done = {}
    for i, changed in ipairs({ false, { ws .. "/n1.norg" }, { ws .. "/n2.norg" } }) do
        indexer.index("notes", {
            changed_files = changed or nil,
            on_done = function(callback_err)
                assert(callback_err == nil, callback_err)
                done[i] = (done[i] or 0) + 1
            end,
        })
    end
    local pending = private.index_runs[ws_norm].pending
    assert(not pending.full and #pending.changed_files == 2, vim.inspect(pending))
    -- A full request makes the follow-up run a full one.
    indexer.index("notes", {
        on_done = function()
            done[4] = (done[4] or 0) + 1
        end,
    })
    assert(private.index_runs[ws_norm].pending.full)
    await("coalesced runs", function()
        return #done == 4
    end)
    vim.wait(300)
    private.run_index = run_index
    assert(runs == 2, "runs: " .. runs)
    assert(vim.deep_equal(done, { 1, 1, 1, 1 }), vim.inspect(done))
    assert_replace_chain()
    local finals, resets, previous = 0, 0, -1
    for _, call in ipairs(calls) do
        if call.message:find("Index generated at", 1, true) then
            finals = finals + 1
        else
            local percent = percent_of(call.message)
            if percent < previous then
                resets = resets + 1
            end
            previous = percent
        end
    end
    assert(finals == 1 and calls[#calls].message == "✓ " .. final, vim.inspect(calls))
    assert(resets <= 1, vim.inspect(calls))

    -- Reads that cannot start (fs_open failing synchronously) do not leave the run in flight.
    local fs_open = vim.uv.fs_open
    vim.uv.fs_open = function(path, flags, mode, callback)
        if flags == "r" and callback then
            return nil, "EMFILE: too many open files"
        end
        return fs_open(path, flags, mode, callback)
    end
    record_notify()
    ok, err = pcall(index)
    vim.uv.fs_open = fs_open
    assert(ok, err)
    assert(err == nil, err)
    assert(vim.tbl_isempty(private.index_runs))
    assert(calls[#calls].message:find(final, 1, true), vim.inspect(calls))

    -- An error while collecting ends the run with that error; the next run works again.
    local slow_read = private.read_file_async
    private.read_file_async = function()
        error("read exploded")
    end
    record_notify()
    err = index()
    private.read_file_async = slow_read
    assert(err and err:find("read exploded", 1, true), vim.inspect(err))
    assert(calls[#calls].level == vim.log.levels.ERROR, vim.inspect(calls))
    assert(vim.tbl_isempty(private.index_runs))
    record_notify()
    assert(index() == nil)
    assert(calls[#calls].message == "✓ " .. final, vim.inspect(calls))
    assert(vim.fn.filereadable(ws .. "/index/categories/c1.norg") == 1)

    -- A notifier failing while rendering the bar stops it without breaking completion.
    calls = {}
    vim.notify = function(message, level, opts)
        if message:find("Indexing notes", 1, true) then
            error("notifier broke")
        end
        table.insert(calls, { message = message, level = level, opts = opts or {} })
        return {}
    end
    assert(index() == nil)
    assert(#calls == 1 and calls[1].message == final, vim.inspect(calls))
    assert(vim.tbl_isempty(private.index_runs))

    -- Write errors end the run with an error that replaces the bar.
    local write_file_async = private.write_file_async
    private.write_file_async = function(path, _, callback)
        callback("Failed to open " .. path .. ": boom")
    end
    record_notify()
    err = index()
    private.write_file_async = write_file_async
    assert(err and err:find("Errors writing files:\n", 1, true), vim.inspect(err))
    assert_replace_chain()
    assert(calls[#calls].level == vim.log.levels.ERROR, vim.inspect(calls[#calls]))
    assert(calls[#calls].message == "✗ " .. err, calls[#calls].message)
    assert(vim.tbl_isempty(private.index_runs))

    -- The work is split into time slices, and the editor runs in between (a timer due "now" fires
    -- during the run). Scratch buffers for reading metadata do not run FileType autocommands.
    slow_reads(false)
    record_notify()
    local budget, defer = private.slice_budget_ms, private.defer
    local slices, timer_fired, filetypes = 0, false, 0
    private.slice_budget_ms = 0
    private.defer = function(fn)
        slices = slices + 1
        defer(fn)
    end
    local autocmd = vim.api.nvim_create_autocmd("FileType", {
        callback = function()
            filetypes = filetypes + 1
        end,
    })
    local result = nil
    indexer.index("notes", {
        on_done = function(index_err)
            result = { err = index_err, timer_fired = timer_fired }
        end,
    })
    vim.defer_fn(function()
        timer_fired = true
    end, 0)
    await("sliced index generation", function()
        return result ~= nil
    end)
    private.slice_budget_ms, private.defer = budget, defer
    vim.api.nvim_del_autocmd(autocmd)
    assert(result.err == nil, vim.inspect(result))
    assert(result.timer_fired, "the editor did not run during indexing")
    assert(slices > 40, "slices: " .. slices)
    assert(filetypes == 0, "FileType autocommands: " .. filetypes)
    assert(vim.fn.filereadable(ws .. "/index/categories/c1.norg") == 1)
    assert(calls[#calls].message:find(final, 1, true), vim.inspect(calls[#calls]))

    vim.notify = notify
end

local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then
    io.stderr:write(err .. "\n")
    vim.cmd("cquit!")
end
print("progress tests passed")
vim.cmd("qa!")
