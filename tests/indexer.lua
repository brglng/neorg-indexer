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

    local function note(name, meta)
        local lines = { "@document.meta" }
        vim.list_extend(lines, meta)
        vim.list_extend(lines, { "@end", "", "body of " .. name })
        vim.fn.writefile(lines, ws .. "/" .. name .. ".norg")
    end
    note("a", {
        "title: A",
        "categories: [",
        "  f",
        "  a/b",
        "]",
        "authors: [",
        "  Ada Lovelace",
        "]",
        "created: 2025-03-15",
        "updated: 2025-04-02",
    })
    note("b", {
        "title: B",
        "categories: solo",
        "author: X/Y",
        "created: 2024-12-01T10:00:00+0000",
        "updated: 2025/04/03",
    })
    vim.fn.writefile({ "no metadata" }, ws .. "/c.norg")

    -- Second workspace: name encoding, escaping, symlinks, and directory safety.
    local ws2 = root .. "/extra"
    local outside = root .. "/outside"
    vim.fn.mkdir(ws2 .. "/index/authors", "p")
    vim.fn.mkdir(outside, "p")
    local function note2(path, meta)
        local lines = { "@document.meta" }
        vim.list_extend(lines, meta)
        vim.list_extend(lines, { "@end", "", "body" })
        vim.fn.writefile(lines, path)
    end
    note2(ws2 .. "/p1.norg", { "title: T]x\\y", "categories: a/b.c", "author: Ada", "created: 2025-3-5" })
    note2(ws2 .. "/p2.norg", { "title: p2", "author: ada", "created: 2025-03-150" })
    note2(ws2 .. "/p3.norg", { "title: p3", "author: X_Y", "created: 2025-13-01" })
    note2(ws2 .. "/p4.norg", { "title: p4", "author: X/Y", "created: 2025-03-05T10:00" })
    note2(ws2 .. "/p5.norg", { "title: p5", "author: Q: R]" })
    -- A note symlinked from outside the workspace is indexed under its workspace path.
    note2(outside .. "/ext.norg", { "title: Ext", "categories: ext" })
    assert(vim.uv.fs_symlink(outside .. "/ext.norg", ws2 .. "/linked.norg"))
    -- So are notes in a directory symlinked from outside the workspace.
    vim.fn.mkdir(outside .. "/dir", "p")
    note2(outside .. "/dir/inner.norg", { "title: Inner", "categories: ext" })
    assert(vim.uv.fs_symlink(outside .. "/dir", ws2 .. "/extdir"))
    -- A symlink alias inside the workspace gets its own name, not its target's.
    assert(vim.uv.fs_symlink(ws2 .. "/p4.norg", ws2 .. "/alias.norg"))
    -- A user folder where the authors index would go.
    note2(ws2 .. "/index/authors/mine.norg", { "title: Mine", "categories: mine" })

    local messages = {}
    vim.notify = function(message, level)
        table.insert(messages, { message = message, level = level })
    end
    -- Count notifications at a level containing a text, since a point in the messages list.
    local function count(level, text, since)
        local n = 0
        for i = (since or 0) + 1, #messages do
            if (level == nil or messages[i].level == level) and messages[i].message:find(text, 1, true) then
                n = n + 1
            end
        end
        return n
    end
    require("neorg").setup({
        load = {
            ["core.neorgcmd"] = {},
            ["core.dirman"] = { config = { workspaces = { notes = ws, extra = ws2 }, default_workspace = "notes" } },
            ["core.integrations.treesitter"] = { config = { configure_parsers = false } },
            ["external.indexer"] = {
                config = {
                    index_on_launch = true,
                    index_on_change = false,
                    -- Removed option: warned about and ignored.
                    categories = { name = "old.norg" },
                },
            },
        },
    })
    local warned = vim.tbl_filter(function(item)
        return item.level == vim.log.levels.WARN and item.message:find("`categories.name`", 1, true) ~= nil
    end, messages)
    assert(#warned == 1, vim.inspect(messages))

    local modules = require("neorg.core").modules
    local indexer = assert(modules.get_module("external.indexer"))
    local config = modules.get_module_config("external.indexer")
    local search_index = require("neorg.modules.external.indexer.search_index")
    local indexers = require("neorg.modules.external.indexer.indexers")
    local indexer_private = require("neorg.modules.external.indexer.module").private

    local function read(rel)
        local path = ws .. "/" .. rel
        return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or nil
    end
    local function has(rel, line)
        local lines = read(rel)
        return lines ~= nil and vim.tbl_contains(lines, line)
    end
    -- Writes are asynchronous: wait for the expected state.
    local function await(description, predicate)
        assert(vim.wait(3000, predicate, 10), "timed out waiting for " .. description)
    end
    -- Lines of a section of index.norg, excluding the section heading.
    local function section(title)
        local result, inside = nil, false
        for _, line in ipairs(read("index.norg") or {}) do
            if line:match("^%*%*? ") then
                inside = line == "** " .. title
                result = inside and {} or result
            elseif inside and line ~= "" then
                table.insert(result, line)
            end
        end
        return result
    end
    local function index(opts, name)
        local before = vim.uv.fs_stat(ws .. "/index.norg")
        local since = #messages
        indexer.index(name or "notes", opts)
        await("index generation", function()
            return count(nil, "Index generated at", since) > 0
        end)
        return before
    end

    -- Launch indexing runs with change indexing disabled and only targets the active workspace.
    await("launch index generation", function()
        return count(nil, "Index generated at " .. ws .. "/index.norg") == 1
    end)
    assert(vim.fn.filereadable(ws2 .. "/index.norg") == 0)
    assert(not read("old.norg"))
    assert(vim.deep_equal(section("Categories"), {
        "*** {:index/categories/a:}[a]",
        "*** {:index/categories/f:}[f]",
        "*** {:index/categories/solo:}[solo]",
        "*** {:index/categories/Uncategorized:}[Uncategorized]",
    }), vim.inspect(section("Categories")))
    assert(vim.deep_equal(section("Authors"), {
        "*** {:index/authors/Ada Lovelace:}[Ada Lovelace]",
        "*** {:index/authors/X=2FY:}[X/Y]",
        "*** {:index/authors/Unknown:}[Unknown]",
    }), vim.inspect(section("Authors")))
    assert(vim.deep_equal(section("Created"), {
        "*** {:index/created/2025:}[2025]",
        "*** {:index/created/2024:}[2024]",
        "*** {:index/created/Unknown:}[Unknown]",
    }), vim.inspect(section("Created")))
    assert(vim.deep_equal(section("Updated"), {
        "*** {:index/updated/2025:}[2025]",
        "*** {:index/updated/Unknown:}[Unknown]",
    }), vim.inspect(section("Updated")))
    local headings = vim.tbl_filter(function(line)
        return line:match("^%*%*? ") ~= nil
    end, read("index.norg"))
    -- Enabled indexers without buckets have no section: without .bib files, no BibTeX section and
    -- no "** BibTeX" group heading.
    local expected_headings = { "* Index", "** Categories", "** Authors", "** Created", "** Updated" }
    assert(vim.deep_equal(headings, expected_headings), vim.inspect(headings))
    assert(not vim.tbl_contains(read("index.norg"), "** BibTeX"))
    -- Levels deeper than the deepest Norg heading become nested list items.
    assert(indexers.heading_prefix(6) == "******")
    assert(indexers.heading_prefix(7) == "-")
    assert(indexers.heading_prefix(8) == "--")
    -- Notes are never listed in the BibTeX indexes, not even in the keyword fallback bucket.
    for _, field in ipairs(indexers.bibtex_fields) do
        assert(section(field.title) == nil, vim.inspect(section(field.title)))
        assert(vim.fn.isdirectory(ws .. "/index/bibtex/" .. field.name) == 0)
    end

    -- Bucket files and parent links.
    assert(has("index/categories/a.norg", "* a"))
    assert(has("index/categories/a.norg", "** {:a/b:}[b]"))
    assert(has("index/categories/a.norg", "** {:../../index:}[󰜱 index]"))
    assert(has("index/categories/a/b.norg", "** {:$/a:}[A]"))
    assert(has("index/categories/a/b.norg", "** {:../a:}[󰜱 a]"))
    assert(has("index/categories/Uncategorized.norg", "** {:$/c:}[c]"))
    assert(has("index/authors/Ada Lovelace.norg", "* Ada Lovelace"))
    assert(has("index/authors/Ada Lovelace.norg", "** {:$/a:}[A]"))
    assert(has("index/authors/X=2FY.norg", "* X/Y"))
    assert(has("index/authors/X=2FY.norg", "** {:../../index:}[󰜱 index]"))
    assert(has("index/authors/Unknown.norg", "** {:$/c:}[c]"))
    assert(has("index/created/2025.norg", "** {:2025/03:}[2025-03]"))
    assert(has("index/created/2025/03.norg", "* 2025-03"))
    assert(has("index/created/2025/03.norg", "** {:03/15:}[2025-03-15]"))
    assert(has("index/created/2025/03.norg", "** {:../2025:}[󰜱 2025]"))
    assert(has("index/created/2025/03/15.norg", "* 2025-03-15"))
    assert(has("index/created/2025/03/15.norg", "** {:$/a:}[A]"))
    assert(has("index/created/2025/03/15.norg", "** {:../03:}[󰜱 2025-03]"))
    assert(has("index/created/2024/12/01.norg", "** {:$/b:}[B]"))
    assert(has("index/updated/2025/04/03.norg", "** {:$/b:}[B]"))
    assert(has("index/updated/Unknown.norg", "** {:$/c:}[c]"))

    -- Index-backed search metadata.
    local metadata = search_index.read(ws, config)
    local function values(path, key)
        return vim.tbl_map(function(text)
            return text.value
        end, (metadata[path] or {})[key] or {})
    end
    local a_categories = values("a.norg", "categories")
    table.sort(a_categories)
    assert(vim.deep_equal(a_categories, { "a/b", "f" }), vim.inspect(a_categories))
    assert(vim.deep_equal(values("b.norg", "authors"), { "X/Y" }))
    assert(vim.deep_equal(values("b.norg", "created"), { "2024-12-01" }))
    assert(vim.deep_equal(values("c.norg", "updated"), { "Unknown" }))

    -- An unchanged index does not rewrite index.norg.
    local stat = vim.uv.fs_stat(ws .. "/index.norg")
    index()
    assert(vim.uv.fs_stat(ws .. "/index.norg").mtime.nsec == stat.mtime.nsec)

    -- Partial update: move b to another category and author.
    vim.fn.writefile(
        vim.tbl_map(function(line)
            return line:gsub("^categories: solo$", "categories: z"):gsub("^author: X/Y$", "author: Ada Lovelace")
        end, vim.fn.readfile(ws .. "/b.norg")),
        ws .. "/b.norg"
    )
    index({ changed_files = { ws .. "/b.norg" } })
    await("partial update", function()
        return has("index/categories/z.norg", "** {:$/b:}[B]") and has("index/authors/Ada Lovelace.norg", "** {:$/b:}[B]")
    end)
    assert(not read("index/categories/solo.norg"), "obsolete category file was not deleted")
    assert(not read("index/authors/X=2FY.norg"), "obsolete author file was not deleted")
    assert(has("index/categories/a/b.norg", "** {:$/a:}[A]"))
    assert(vim.deep_equal(section("Categories"), {
        "*** {:index/categories/a:}[a]",
        "*** {:index/categories/f:}[f]",
        "*** {:index/categories/z:}[z]",
        "*** {:index/categories/Uncategorized:}[Uncategorized]",
    }), vim.inspect(section("Categories")))
    assert(vim.deep_equal(section("Authors"), {
        "*** {:index/authors/Ada Lovelace:}[Ada Lovelace]",
        "*** {:index/authors/Unknown:}[Unknown]",
    }), vim.inspect(section("Authors")))

    -- Month granularity, no author fallback, inline updated index, disabled categories.
    config.created.granularity = "month"
    config.authors.fallback = false
    config.updated.per_period_index = false
    config.categories.enabled = false
    index()
    assert(section("Categories") == nil)
    assert(read("index/categories/a.norg"), "disabled indexer directory was deleted")
    assert(vim.deep_equal(section("Authors"), { "*** {:index/authors/Ada Lovelace:}[Ada Lovelace]" }))
    assert(not read("index/authors/Unknown.norg"))
    assert(has("index/created/2025.norg", "** {:2025/03:}[2025-03]"))
    assert(has("index/created/2025/03.norg", "** {:$/a:}[A]"))
    assert(vim.fn.isdirectory(ws .. "/index/created/2025/03") == 0)
    -- A disabled indexer's directory still has its marker: its files are not indexed as notes.
    assert(vim.deep_equal(section("Updated"), {
        "*** 2025",
        "**** 2025-04",
        "***** 2025-04-03",
        "****** {:$/b:}[B]",
        "***** 2025-04-02",
        "****** {:$/a:}[A]",
        "*** Unknown",
        "**** {:$/c:}[c]",
    }), vim.inspect(section("Updated")))
    metadata = search_index.read(ws, config)
    assert(vim.deep_equal(values("a.norg", "created"), { "2025-03" }))
    assert(vim.deep_equal(values("b.norg", "updated"), { "2025-04-03" }))
    assert(vim.deep_equal(values("c.norg", "updated"), { "Unknown" }))
    assert(vim.deep_equal(values("c.norg", "authors"), {}))
    assert(vim.deep_equal(values("a.norg", "categories"), {}))

    -- A section is listed only while its index has buckets: partial updates remove it when its
    -- last bucket goes and add it back with its first bucket.
    local a_lines, b_lines = vim.fn.readfile(ws .. "/a.norg"), vim.fn.readfile(ws .. "/b.norg")
    local function without_authors(lines)
        return vim.tbl_filter(function(line)
            return line ~= "  Ada Lovelace" and line ~= "author: Ada Lovelace"
        end, lines)
    end
    vim.fn.writefile(without_authors(a_lines), ws .. "/a.norg")
    vim.fn.writefile(without_authors(b_lines), ws .. "/b.norg")
    index({ changed_files = { ws .. "/a.norg", ws .. "/b.norg" } })
    assert(section("Authors") == nil, vim.inspect(read("index.norg")))
    assert(not read("index/authors/Ada Lovelace.norg"))
    assert(section("Created") and section("Updated"))
    metadata = search_index.read(ws, config)
    assert(vim.deep_equal(values("a.norg", "authors"), {}))
    assert(vim.deep_equal(values("b.norg", "updated"), { "2025-04-03" }))
    vim.fn.writefile(a_lines, ws .. "/a.norg")
    index({ changed_files = { ws .. "/a.norg" } })
    assert(vim.deep_equal(section("Authors"), { "*** {:index/authors/Ada Lovelace:}[Ada Lovelace]" }))
    assert(has("index/authors/Ada Lovelace.norg", "** {:$/a:}[A]"))
    assert(not has("index/authors/Ada Lovelace.norg", "** {:$/b:}[B]"))
    vim.fn.writefile(b_lines, ws .. "/b.norg")
    index({ changed_files = { ws .. "/b.norg" } })
    assert(has("index/authors/Ada Lovelace.norg", "** {:$/b:}[B]"))
    -- Without any section, the main index keeps its "* Index" heading.
    local saved = {}
    for _, key in ipairs({ "authors", "created", "updated" }) do
        saved[key] = config[key].enabled
        config[key].enabled = false
    end
    local bibtex_config = config.bibtex
    config.bibtex = false
    index()
    headings = vim.tbl_filter(function(line)
        return line:match("^%*+ ") ~= nil
    end, read("index.norg"))
    assert(vim.deep_equal(headings, { "* Index" }), vim.inspect(read("index.norg")))
    for key, enabled in pairs(saved) do
        config[key].enabled = enabled
    end
    config.bibtex = bibtex_config
    index()
    assert(section("Authors") and section("Created") and section("Updated"))
    -- The disabled indexer's marked directory is excluded from search and from the watcher.
    assert(vim.tbl_contains(search_index.generated_paths(config, ws), "index/categories"))
    assert(not vim.tbl_contains(search_index.generated_paths(config), "index/categories"))
    assert(indexer_private.should_ignore_path(ws .. "/index/categories/a.norg", ws))
    assert(not indexer_private.should_ignore_path(ws .. "/a.norg", ws))

    -- Every indexer is enabled when its key is missing; `<key> = false` or `enabled = false` disables it.
    do
        local keys = {}
        for _, ix in ipairs(indexers.enabled({ name = "index.norg" })) do
            keys[#keys + 1] = ix.def.key
            assert(ix.dir == "index/" .. ix.def.key:gsub("%.", "/"), vim.inspect(ix.dir))
        end
        local expected_keys = { "categories", "authors", "created", "updated" }
        for _, field in ipairs(indexers.bibtex_fields) do
            expected_keys[#expected_keys + 1] = "bibtex." .. field.name
        end
        assert(vim.deep_equal(keys, expected_keys), vim.inspect(keys))
        local partial = indexers.enabled({
            name = "index.norg",
            categories = { enabled = false },
            authors = { dir = "people" },
            created = { enabled = "no" },
            updated = false,
            bibtex = false,
        })
        keys = {}
        for _, ix in ipairs(partial) do
            keys[#keys + 1] = ix.def.key
        end
        assert(vim.deep_equal(keys, { "authors", "created" }), vim.inspect(keys))
        -- Each BibTeX indexer follows the normal rules inside the `bibtex` group.
        local bib = indexers.enabled({
            name = "index.norg",
            bibtex = { keyword = false, journal = { enabled = false }, type = { dir = "types" } },
        })
        keys = {}
        for _, ix in ipairs(bib) do
            keys[ix.def.key] = ix.dir
        end
        assert(keys["bibtex.keyword"] == nil and keys["bibtex.journal"] == nil)
        assert(keys["bibtex.type"] == "types" and keys["bibtex.publisher"] == "index/bibtex/publisher")
        assert(partial[1].dir == "people" and partial[1].config.fallback == "Unknown")
        assert(partial[1].config.title_formatter == indexers.default_title_formatter)
    end

    -- Directory validation.
    for _, dir in ipairs({ "", " ", ".", "a/..", "..", "../x", "a/../../x", "/abs", "~/x", 42 }) do
        assert(indexers.normalize_dir(dir) == nil, vim.inspect(dir))
    end
    assert(indexers.normalize_dir("./a//b/") == "a/b")
    local function errors_for(cfg)
        local result = {}
        for _, ix in ipairs(indexers.configured(cfg)) do
            result[ix.def.key] = ix.error ~= nil
        end
        return result
    end
    local function dirs(categories, authors, created, updated, name, keywords)
        return {
            name = name or "index.norg",
            categories = { dir = categories },
            authors = { dir = authors },
            created = { dir = created },
            updated = { dir = updated, enabled = updated ~= "off" },
            bibtex = { keyword = { dir = keywords or "k" } },
        }
    end
    local function errors_of(cfg)
        local result = errors_for(cfg)
        local keyword = result["bibtex.keyword"]
        for key, err in pairs(result) do
            if key:match("^bibtex%.") then
                -- Sibling directories under index/bibtex never conflict.
                assert(key == "bibtex.keyword" or not err, key)
                result[key] = nil
            end
        end
        result.bibtex_keyword = keyword
        return result
    end
    assert(vim.deep_equal(
        errors_of(dirs("c", "a", "x", "x")),
        { categories = false, authors = false, created = true, updated = true, bibtex_keyword = false }
    ))
    assert(vim.deep_equal(
        errors_of(dirs("c", "a", "x", "X/y")),
        { categories = false, authors = false, created = true, updated = true, bibtex_keyword = false }
    ))
    -- A disabled indexer does not conflict.
    assert(vim.deep_equal(
        errors_of(dirs("c", "a", "x", "off")),
        { categories = false, authors = false, created = false, updated = false, bibtex_keyword = false }
    ))
    assert(errors_of(dirs("c", "index.norg", "x", "u")).authors)
    assert(errors_of(dirs("c", "notes", "x", "u", "notes/index.norg")).authors)
    assert(vim.deep_equal(
        errors_of(dirs("c", "a", "x", "u", nil, "a/k")),
        { categories = false, authors = true, created = false, updated = false, bibtex_keyword = true }
    ))

    assert(errors_for({ name = "index.norg", bibtex = { journal = { dir = "index/bibtex" } } })["bibtex.journal"])
    assert(
        errors_for({ name = "index.norg", bibtex = { journal = { dir = "index/bibtex/keyword/j" } } })["bibtex.keyword"]
    )

    -- Date parsing.
    local created_def = indexers.list[3]
    local function date(value, granularity)
        return created_def.values({ created = value }, { granularity = granularity or "day" })
    end
    assert(vim.deep_equal(date("2025-3-5"), { { "2025", "03", "05" } }))
    assert(vim.deep_equal(date("2025/12/31T23:00"), { { "2025", "12", "31" } }))
    assert(vim.deep_equal(date("2025-3"), { { "2025", "03" } }))
    assert(vim.deep_equal(date("2025-03-05", "month"), { { "2025", "03" } }))
    local invalid_dates = { "2025-03-150", "2025-13-01", "2025-0-01", "2025-03-32", "2025-03-00", "20250", "2025-123" }
    for _, invalid in ipairs(invalid_dates) do
        assert(vim.deep_equal(date(invalid), {}), invalid)
    end

    -- File name encoding.
    local samples = {
        "plain name", "X/Y", "X_Y", "X=2FY", "a:b", "a]b", "[x]", "{y}", "*?", '"<>|', "a\\b", ".hidden", "a.b",
        "~1", "a~2", "50%", "a&b", "$x", "`c`", "(p)", " lead", "tab\tch",
    }
    local seen = {}
    for _, sample in ipairs(samples) do
        local encoded = indexers.encode_part(sample)
        assert(not encoded:find('[%%&$`/\\:%[%]{}*?"<>|~%c]'), encoded)
        assert(not encoded:match("^[.() ]"), encoded)
        assert(indexers.decode_part(encoded) == sample, sample)
        assert(indexers.decode_part(encoded .. "~3") == sample, sample)
        assert(not seen[encoded], encoded)
        seen[encoded] = true
    end
    assert(indexers.encode_part("Ada Lovelace") == "Ada Lovelace")
    assert(indexers.encode_part(".a.b") == "=2Ea.b")

    -- Entry sorting ties break on the lowercased title, then the norgname.
    local sorted = {
        { title = "b", norgname = "/1", created = "2025" },
        { title = "B", norgname = "/0", created = "2025" },
        { title = "a", norgname = "/2", created = "2025" },
        { title = "z", norgname = "/3", created = "2026" },
    }
    indexer_private.sort_entries({ config = { sort_by = "created", sort_direction = "descending" } }, sorted)
    assert(vim.deep_equal(vim.tbl_map(function(entry)
        return entry.norgname
    end, sorted), { "/3", "/2", "/0", "/1" }))

    -- Second workspace.
    local function read2(rel)
        local path = ws2 .. "/" .. rel
        return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or nil
    end
    local function has2(rel, line)
        local lines = read2(rel)
        return lines ~= nil and vim.tbl_contains(lines, line)
    end
    local function section2(title)
        local result, inside = nil, false
        for _, line in ipairs(read2("index.norg") or {}) do
            if line:match("^%*%*? ") then
                inside = line == "** " .. title
                result = inside and {} or result
            elseif inside and line ~= "" then
                table.insert(result, line)
            end
        end
        return result
    end
    config.categories.enabled = true
    config.categories.subcategory_separator = "."
    config.authors.fallback = "No/One"
    config.created.granularity = "week"
    config.updated.enabled = false

    -- An existing, non-empty directory without the marker is never touched.
    local since = #messages
    index(nil, "extra")
    index(nil, "extra")
    assert(count(vim.log.levels.ERROR, "`authors.dir`", since) == 1, vim.inspect(messages))
    assert(count(vim.log.levels.WARN, "`created.granularity`", since) == 1, vim.inspect(messages))
    assert(section2("Authors") == nil)
    assert(vim.deep_equal(vim.fn.readdir(ws2 .. "/index/authors"), { "mine.norg" }))
    -- Its notes are ordinary notes.
    assert(has2("index/categories/mine.norg", "** {:$/index/authors/mine:}[Mine]"))
    -- Generated directories get the marker.
    assert(vim.fn.filereadable(ws2 .. "/index/categories/" .. indexers.marker) == 1)
    assert(vim.fn.filereadable(ws2 .. "/index/created/" .. indexers.marker) == 1)

    -- An empty directory is fine.
    vim.fn.delete(ws2 .. "/index/authors/mine.norg")
    index(nil, "extra")
    assert(vim.fn.filereadable(ws2 .. "/index/authors/" .. indexers.marker) == 1)
    assert(vim.deep_equal(section2("Authors"), {
        "*** {:index/authors/Ada:}[Ada]",
        "*** {:index/authors/ada~2:}[ada]",
        "*** {:index/authors/Q=3A R=5D:}[Q: R\\]]",
        "*** {:index/authors/X=2FY:}[X/Y]",
        "*** {:index/authors/X_Y:}[X_Y]",
        "*** {:index/authors/No=2FOne:}[No/One]",
    }), vim.inspect(section2("Authors")))
    assert(has2("index/authors/Ada.norg", "** {:$/p1:}[T\\]x\\\\y]"))
    assert(has2("index/authors/ada~2.norg", "* ada"))
    assert(has2("index/authors/ada~2.norg", "** {:$/p2:}[p2]"))
    assert(has2("index/authors/Q=3A R=5D.norg", "* Q: R\\]"))
    assert(has2("index/authors/No=2FOne.norg", "** {:$/linked:}[Ext]"))
    -- Categories split on the configured separator; "/" stays inside a part.
    assert(has2("index.norg", "*** {:index/categories/a=2Fb:}[a/b]"))
    assert(has2("index/categories/a=2Fb.norg", "** {:a=2Fb/c:}[c]"))
    assert(has2("index/categories/a=2Fb/c.norg", "** {:$/p1:}[T\\]x\\\\y]"))
    assert(has2("index/categories/ext.norg", "** {:$/linked:}[Ext]"))
    assert(has2("index/categories/ext.norg", "** {:$/extdir/inner:}[Inner]"))
    assert(has2("index/authors/X=2FY.norg", "** {:$/alias:}[p4]"))
    assert(has2("index/authors/X=2FY.norg", "** {:$/p4:}[p4]"))
    -- Dates: 1-digit components are padded; invalid dates use the fallback; invalid granularity is "day".
    assert(has2("index/created/2025/03/05.norg", "** {:$/p1:}[T\\]x\\\\y]"))
    assert(has2("index/created/2025/03/05.norg", "** {:$/p4:}[p4]"))
    assert(has2("index/created/Unknown.norg", "** {:$/p2:}[p2]"))
    assert(has2("index/created/Unknown.norg", "** {:$/p3:}[p3]"))

    -- Every generated link parses with the Norg parser.
    local generated = vim.fs.find(function(name)
        return name:sub(-5) == ".norg"
    end, { path = ws2, type = "file", limit = math.huge })
    for _, path in ipairs(generated) do
        local source = table.concat(vim.fn.readfile(path), "\n") .. "\n"
        local tree = vim.treesitter.get_string_parser(source, "norg"):parse()[1]
        local links, errors = 0, 0
        local function walk(node)
            if node:type() == "ERROR" or node:missing() then
                errors = errors + 1
            elseif node:type() == "link_location" then
                links = links + 1
            end
            for child in node:iter_children() do
                walk(child)
            end
        end
        walk(tree:root())
        local _, expected = source:gsub("{:", "")
        assert(errors == 0 and links == expected, path .. "\n" .. source)
    end

    -- Search reads the real values back.
    local metadata2 = search_index.read(ws2, config)
    local function values2(path, key)
        return vim.tbl_map(function(text)
            return text.value
        end, (metadata2[path] or {})[key] or {})
    end
    assert(vim.deep_equal(values2("p1.norg", "authors"), { "Ada" }))
    assert(vim.deep_equal(values2("p2.norg", "authors"), { "ada" }))
    assert(vim.deep_equal(values2("p4.norg", "authors"), { "X/Y" }))
    assert(vim.deep_equal(values2("p5.norg", "authors"), { "Q: R]" }))
    assert(vim.deep_equal(values2("linked.norg", "authors"), { "No/One" }))
    assert(vim.deep_equal(values2("p1.norg", "categories"), { "a/b.c" }))
    assert(vim.deep_equal(values2("p1.norg", "created"), { "2025-03-05" }))

    -- A full rebuild deletes stale files from marked directories only.
    vim.fn.writefile({ "* stale" }, ws2 .. "/index/categories/stale.norg")
    index(nil, "extra")
    assert(not read2("index/categories/stale.norg"))

    -- Partial update, with the changed file given by its resolved path.
    local p3 = ws2 .. "/p3.norg"
    local p3_lines = vim.list_extend({ "@document.meta", "categories: q/r.s" }, vim.list_slice(vim.fn.readfile(p3), 2))
    vim.fn.writefile(p3_lines, p3)
    local real_p3 = assert(vim.uv.fs_realpath(p3))
    assert(real_p3 ~= p3, "the test workspace path should contain a symlink")
    index({ changed_files = { real_p3 } }, "extra")
    await("partial update", function()
        return has2("index/categories/q=2Fr/s.norg", "** {:$/p3:}[p3]")
    end)
    -- Affected keys come from the configured separator, so the parent bucket is written too.
    assert(has2("index/categories/q=2Fr.norg", "** {:q=2Fr/s:}[s]"))
    assert(has2("index.norg", "*** {:index/categories/q=2Fr:}[q/r]"))
    assert(vim.deep_equal(search_index.read(ws2, config)["p3.norg"].categories[1].value, "q/r.s"))
    assert(not has2("index/categories/Uncategorized.norg", "** {:$/p3:}[p3]"))

    -- Obsolete files are compared case-insensitively and deleted only from marked directories.
    local ix = vim.tbl_filter(function(item)
        return item.def.key == "authors"
    end, indexer_private.get_active_indexers(ws2))[1]
    local tree = indexer_private.build_tree(ix, {
        { title = "x", norgname = "/x", metadata = { author = "Ada" } },
    })
    vim.fn.writefile({ "* Ada" }, ws2 .. "/index/authors/Ada.norg")
    vim.fn.writefile({ "* Gone" }, ws2 .. "/index/authors/Gone.norg")
    indexer_private.delete_obsolete_bucket_files(ix, tree, { ada = true, Gone = true })
    assert(vim.fn.filereadable(ws2 .. "/index/authors/Ada.norg") == 1)
    assert(vim.fn.filereadable(ws2 .. "/index/authors/Gone.norg") == 0)
    vim.fn.writefile({ "* Gone" }, ws2 .. "/index/authors/Gone.norg")
    vim.fn.delete(ws2 .. "/index/authors/" .. indexers.marker)
    indexer_private.delete_obsolete_bucket_files(ix, tree, { Gone = true })
    assert(vim.fn.filereadable(ws2 .. "/index/authors/Gone.norg") == 1)
    -- Without the marker, the directory is no longer the indexer's.
    since = #messages
    index(nil, "extra")
    assert(count(vim.log.levels.ERROR, "`authors.dir`", since) == 0, "error notified twice")
    assert(vim.fn.filereadable(ws2 .. "/index/authors/Gone.norg") == 1)
    assert(section2("Authors") == nil)

    -- Invalid directories are reported and skipped without touching the workspace.
    config.authors.dir = "a/.."
    since = #messages
    index(nil, "extra")
    assert(count(vim.log.levels.ERROR, "`authors.dir` must be strictly inside the workspace", since) == 1)
    assert(section2("Authors") == nil)
    assert(read2("p1.norg") and read2("linked.norg"))
end

local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then
    io.stderr:write(err .. "\n")
    vim.cmd("cquit!")
end
print("indexer tests passed")
vim.cmd("qa!")
