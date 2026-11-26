-- BibTeX literature tests. They need the tree-sitter parser for BibTeX: set NEORG_INDEXER_TEST_RTP
-- to a directory that contains `parser/bibtex.so` (e.g. the lib/lua/5.1 directory of a luarocks
-- tree where tree-sitter-bibtex is installed). Without the parser the tests are skipped.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
for _, path in ipairs(vim.split(vim.env.NEORG_INDEXER_TEST_RTP or "", ",", { trimempty = true })) do
    vim.opt.runtimepath:append(path)
end

local bibtex = require("neorg.modules.external.indexer.bibtex")
local indexers = require("neorg.modules.external.indexer.indexers")
if not bibtex.available() then
    print("literature tests skipped: tree-sitter parser for bibtex not found (set NEORG_INDEXER_TEST_RTP)")
    vim.cmd("qa!")
end

local root = vim.fn.tempname()

local function write(path, lines)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(lines, path)
end

local function parse_tests()
    local source = table.concat({
        "@comment{ignored}",
        '@preamble{"\\newcommand{\\x}{y}"}',
        '@string{ieee = "IEEE " # {Trans.}}',
        "@String{Pub = {Some {Publisher}}}",
        "@Article{doe2020,",
        '  Title = {Caf{\\\'e} and {\\"U}ber {Big}} # " Deal",',
        '  author = {Doe, John and {Smith and Co} and M{\\"u}ller, J\\"org AND others},',
        "  journal = ieee # { } # pub,",
        "  year = 2020, month = mar,",
        "  keywords = {a, b; c,, },",
        "  abstract = {An   abstract\n   on two lines},",
        "  pages = {1--2},",
        "}",
        "@book{second, title = {Second}}",
    }, "\n")
    local item = assert(bibtex.read(source, root .. "/doe2020.bib"))
    assert(item.citekey == "doe2020")
    assert(item.extra == 1)
    local meta = item.metadata
    assert(meta.kind == "literature" and meta.citekey == "doe2020")
    assert(meta.title == "Café and Über Big Deal", meta.title)
    assert(vim.deep_equal(meta.authors, { "John Doe", "Smith and Co", "Jörg Müller" }), vim.inspect(meta.authors))
    -- Keywords are kept as a raw field and not projected to categories.
    assert(meta.categories == nil, vim.inspect(meta.categories))
    assert(meta.bibtex.fields.keywords == "a, b; c,,", meta.bibtex.fields.keywords)
    assert(vim.deep_equal(bibtex.split_keywords(meta.bibtex.fields.keywords), { "a", "b", "c" }))
    assert(vim.deep_equal(bibtex.split_keywords(" x ;X, x;; y "), { "x", "X", "y" }))
    assert(vim.deep_equal(bibtex.split_keywords(nil), {}))
    assert(meta.description == "An abstract on two lines", meta.description)
    assert(meta.created == "2020-03" and meta.updated == "2020-03", meta.created)
    assert(meta.bibtex.type == "article" and meta.bibtex.key == "doe2020")
    local fields = meta.bibtex.fields
    assert(fields.journal == "IEEE Trans. Some Publisher", fields.journal)
    assert(fields.pages == "1–2", fields.pages)
    assert(fields.year == "2020")
    assert(item.pdf == nil)

    -- `date` takes precedence over year and month; editors are used without authors.
    item = assert(
        bibtex.read(
            "@misc{k, date = {2017-03-15}, year = {2016}, month = {7}, editor = {Last, First and Other One}}",
            root .. "/k.bib"
        )
    )
    assert(item.metadata.created == "2017-03-15" and item.metadata.updated == "2017-03-15")
    assert(vim.deep_equal(item.metadata.authors, { "First Last", "Other One" }))
    -- The citekey is the fallback title; a numeric month is padded.
    item = assert(bibtex.read("@misc{only-key, year = 1999, month = {7}}", root .. "/k.bib"))
    assert(item.metadata.title == "only-key" and item.metadata.created == "1999-07")
    assert(item.metadata.authors == nil or #item.metadata.authors == 0)
    -- No regular entry.
    assert(bibtex.read("@string{a = {b}}\n@comment{c}", root .. "/k.bib") == nil)
    assert(bibtex.read("", root .. "/k.bib") == nil)

    -- The PDF comes only from the `file` field: no same-name sibling lookup.
    write(root .. "/pdf/sib.bib", { "@misc{sib, file = {other.pdf}}" })
    write(root .. "/pdf/sib.pdf", { "%PDF" })
    write(root .. "/pdf/papers/z paper.pdf", { "%PDF" })
    write(root .. "/pdf/other.pdf", { "%PDF" })
    write(root .. "/pdf/upper.PDF", { "%PDF" })
    write(root .. "/pdf/notes.txt", { "text" })
    local dir = root .. "/pdf"
    assert(bibtex.find_pdf(dir .. "/sib.bib", { file = "other.pdf" }) == dir .. "/other.pdf")
    assert(bibtex.find_pdf(dir .. "/sib.bib", {}) == nil)
    assert(bibtex.find_pdf(dir .. "/sib.bib", nil) == nil)
    assert(bibtex.find_pdf(dir .. "/sib.bib", { file = "" }) == nil)
    -- Relative paths are resolved from the .bib directory; absolute and "~" paths are kept.
    assert(bibtex.find_pdf(dir .. "/papers/x.bib", { file = "../other.pdf" }) == dir .. "/other.pdf")
    assert(bibtex.find_pdf(root .. "/x.bib", { file = dir .. "/other.pdf" }) == dir .. "/other.pdf")
    local home = vim.fs.normalize("~")
    if vim.startswith(dir, home .. "/") then
        local tilde = "~" .. dir:sub(#home + 1) .. "/other.pdf"
        assert(bibtex.find_pdf(root .. "/x.bib", { file = tilde }) == dir .. "/other.pdf")
    end
    assert(vim.deep_equal(bibtex.pdf_candidates("/b/x.bib", { file = "~/a.pdf" }), { home .. "/a.pdf" }))
    -- JabRef/Zotero "Description:path:Type", with or without a description.
    assert(
        bibtex.find_pdf(dir .. "/x.bib", { file = "Full Text:papers/z paper.pdf:application/pdf" })
            == dir .. "/papers/z paper.pdf"
    )
    -- Multiple files: the first existing PDF; non-PDF files are skipped. The extension is
    -- case-insensitive.
    assert(
        bibtex.find_pdf(dir .. "/x.bib", { file = ":missing.pdf:PDF;:" .. dir .. "/other.pdf:PDF" })
            == dir .. "/other.pdf"
    )
    assert(bibtex.find_pdf(dir .. "/x.bib", { file = "notes.txt;upper.PDF;other.pdf" }) == dir .. "/upper.PDF")
    assert(bibtex.find_pdf(dir .. "/x.bib", { file = "notes.txt" }) == nil)
    assert(bibtex.find_pdf(dir .. "/x.bib", { file = "missing.pdf" }) == nil)
    -- Windows drive letters and escaped ":" are kept in the path.
    assert(
        vim.deep_equal(
            bibtex.pdf_candidates("/b/x.bib", { file = "Paper:C\\:\\\\papers\\\\a.pdf:PDF" }),
            { vim.fs.normalize("C:\\papers\\a.pdf") }
        ),
        vim.inspect(bibtex.pdf_candidates("/b/x.bib", { file = "Paper:C\\:\\\\papers\\\\a.pdf:PDF" }))
    )
    assert(
        vim.deep_equal(
            bibtex.pdf_candidates("/b/x.bib", { file = ":C:/papers/a.pdf:PDF" }),
            { vim.fs.normalize("C:/papers/a.pdf") }
        ),
        vim.inspect(bibtex.pdf_candidates("/b/x.bib", { file = ":C:/papers/a.pdf:PDF" }))
    )
    -- The `file` field is read verbatim from the .bib source.
    item = assert(bibtex.read("@misc{f, file = {:papers/z paper.pdf:PDF}}", dir .. "/f.bib"))
    assert(item.pdf == dir .. "/papers/z paper.pdf", vim.inspect(item.pdf))
    item = assert(bibtex.read("@misc{sib, title = {Sibling}}", dir .. "/sib.bib"))
    assert(item.pdf == nil)
end

local function run()
    local plugins = vim.env.NEORG_TEST_PLUGINS or (vim.fn.stdpath("data") .. "/lazy")
    for _, name in ipairs({ "neorg", "lua-utils.nvim", "nvim-nio", "nui.nvim", "pathlib.nvim" }) do
        vim.opt.runtimepath:append(plugins .. "/" .. name)
    end
    local rocks = vim.env.NEORG_TEST_ROCKS or (vim.fn.stdpath("data") .. "/lazy-rocks")
    for _, lang in ipairs({ "norg", "norg_meta" }) do
        local ok_lang, loaded = pcall(vim.treesitter.language.add, lang)
        if not ok_lang or not loaded then
            local parser = vim.fn.glob(rocks .. "/tree-sitter-*/lib/lua/5.1/parser/" .. lang .. ".so", false, true)[1]
            assert(parser, "tree-sitter parser not found: " .. lang)
            vim.treesitter.language.add(lang, { path = parser })
        end
    end

    parse_tests()

    local ws = root .. "/workspace"
    write(ws .. "/note.norg", {
        "@document.meta",
        "title: Lossless note",
        "categories: [",
        "  Lossless",
        "]",
        "authors: [",
        "  Sebastian J. Schlecht",
        "]",
        "created: 2017-03-15",
        "updated: 2018-01-02",
        "@end",
        "",
        "body",
    })
    -- The real-world sample, with its PDF next to it named by its `file` field.
    local sample = vim.fn.expand("~/github/brglng/mynorg/literature/schlecht2017lossless.bib")
    local sample_lines = vim.fn.filereadable(sample) == 1 and vim.fn.readfile(sample)
        or {
            "@article{schlecht2017lossless,",
            "  title = {On Lossless Feedback Delay Networks},",
            '  author = {Schlecht, Sebastian J. and Habets, Emanu{\\"e}l A. P.},',
            "  journal = {IEEE Transactions on Signal Processing},",
            "  date = {2017-03-15},",
            "  publisher = {Institute of Electrical and Electronics Engineers (IEEE)},",
            "  keywords = {Feedback Delay Network, Lossless, Diagonal Similarity, Artificial Reverberation},",
            "  file = {schlecht2017lossless.pdf},",
            "}",
        }
    write(ws .. "/literature/schlecht2017lossless.bib", sample_lines)
    write(ws .. "/literature/schlecht2017lossless.pdf", { "%PDF" })
    write(ws .. "/literature/other/doe]2020.bib", {
        "@article{doe]2020,",
        "  title = {A [bracketed] title},",
        "  author = {Doe, Jane},",
        "  keywords = {Lossless},",
        "  year = 2016, month = feb,",
        "}",
        "@misc{ignored, title = {Ignored}}",
    })
    write(ws .. "/literature/nokw.bib", { "@misc{nokw, title = {No keywords}, year = 2010}" })
    -- A same-name PDF next to a .bib file without a `file` field is not linked.
    write(ws .. "/literature/nokw.pdf", { "%PDF" })
    local fields_lines = {
        "@inproceedings{fields2021,",
        "  title = {Fields},",
        "  keywords = {Extra Field},",
        "  booktitle = {Proc. Conf.},",
        "  institution = {Inst},",
        "  journal = {J. Audio},",
        "  key = {SortKey},",
        "  organization = {Org},",
        "  publisher = {Institute of Electrical and Electronics Engineers (IEEE)},",
        "  school = {School},",
        "  type = {Technical Report},",
        "  language = {english},",
        "  journaltitle = {Journal Title},",
        "  location = {Berlin},",
        "  eventdate = {2020-05-01/2020-05-03},",
        "  pubstate = {inpress},",
        "  year = 2021,",
        "}",
    }
    write(ws .. "/literature/fields.bib", fields_lines)
    -- Generated index directories are not indexed.
    write(ws .. "/index/categories/.neorg-indexer", {})
    write(ws .. "/index/categories/stray.bib", { "@misc{stray, keywords = {Lossless}}" })

    local messages = {}
    vim.notify = function(message, level)
        table.insert(messages, { message = message, level = level })
    end
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
            ["core.dirman"] = { config = { workspaces = { lit = ws } } },
            ["core.integrations.treesitter"] = { config = { configure_parsers = false } },
            ["external.indexer"] = { config = { index_on_change = false } },
        },
    })
    local modules = require("neorg.core").modules
    local indexer = assert(modules.get_module("external.indexer"))
    local config = modules.get_module_config("external.indexer")
    local private = require("neorg.modules.external.indexer.module").private

    local function read(rel)
        local path = ws .. "/" .. rel
        return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or nil
    end
    local function await(description, predicate)
        assert(vim.wait(3000, predicate, 10), "timed out waiting for " .. description)
    end
    local function index(opts)
        local since = #messages
        indexer.index("lit", opts)
        await("index generation", function()
            return count(nil, "Index generated at", since) > 0
        end)
    end
    -- Heading lines of a generated file, without its title, parent link, and "Notes" heading.
    local function entries(rel)
        local result = {}
        for _, line in ipairs(assert(read(rel), rel)) do
            if line:match("^%*%* ") and not line:find("󰜱", 1, true) then
                table.insert(result, line)
            end
        end
        return result
    end

    -- Child headings of a section of the main index: a level-2 section, or, for the title of a
    -- BibTeX field section, a level-3 section under the "** BibTeX" group heading.
    local bibtex_titles = {}
    for _, field in ipairs(indexers.bibtex_fields) do
        bibtex_titles[field.title] = true
    end
    local function section(title)
        local level = bibtex_titles[title] and 3 or 2
        local result, group, inside = {}, false, false
        for _, line in ipairs(read("index.norg") or {}) do
            local stars = line:match("^(%*+) ")
            if stars and #stars <= level then
                if #stars <= 2 then
                    group = line == "** BibTeX"
                end
                inside = line == string.rep("*", level) .. " " .. title and (level == 2 or group)
            elseif inside and stars and #stars == level + 1 then
                table.insert(result, line)
            end
        end
        return result
    end
    -- Level-2 and level-3 headings of the main index.
    local function main_headings()
        return vim.tbl_filter(function(line)
            return line:match("^%*%*%*? ") ~= nil
        end, read("index.norg"))
    end
    local function has_marker(dir)
        return vim.fn.filereadable(dir .. "/.neorg-indexer") == 1
    end

    index()
    assert(count(vim.log.levels.WARN, "doe]2020.bib contains 2 BibTeX entries", 0) == 1, vim.inspect(messages))
    local schlecht = "{/ ../../literature/schlecht2017lossless.bib}[\\[schlecht2017lossless\\] "
        .. "On Lossless Feedback Delay Networks] {/ ../../literature/schlecht2017lossless.pdf}[\\[PDF\\]]"
    local doe = "{/ ../../literature/other/doe]2020.bib}[\\[doe\\]2020\\] A \\[bracketed\\] title]"
    local note = "{:$/note:}[Lossless note]"
    local nokw = "{/ ../../literature/nokw.bib}[\\[nokw\\] No keywords]"
    local fields = "{/ ../../literature/fields.bib}[\\[fields2021\\] Fields]"
    -- Exact lines, with and without a PDF: both brackets of the citekey prefix and of `[PDF]` are
    -- escaped.
    local literatures_lines = read("index/categories/Literatures.norg")
    assert(
        vim.tbl_contains(
            literatures_lines,
            [=[** {/ ../../literature/schlecht2017lossless.bib}[\[schlecht2017lossless\] ]=]
                .. [=[On Lossless Feedback Delay Networks] {/ ../../literature/schlecht2017lossless.pdf}[\[PDF\]]]=]
        ),
        vim.inspect(literatures_lines)
    )
    assert(
        vim.tbl_contains(literatures_lines, [=[** {/ ../../literature/nokw.bib}[\[nokw\] No keywords]]=]),
        vim.inspect(literatures_lines)
    )
    -- Brackets and backslashes in citekeys and titles are escaped.
    local formatted = private.format_entry_lines({ config = {} }, {
        {
            kind = "literature",
            rel = "literature/a.bib",
            abs_path = "/ws/literature/a.bib",
            citekey = "a[1]\\b",
            pdf = "/ws/literature/a.pdf",
            metadata = { title = "T [x]" },
        },
    }, 2, "index/categories/x.norg")
    assert(
        vim.deep_equal(formatted, {
            [=[** {/ ../../literature/a.bib}[\[a\[1\]\\b\] T \[x\]] {/ ../../literature/a.pdf}[\[PDF\]]]=],
        }),
        vim.inspect(formatted)
    )
    -- Links from files one directory deeper (under index/bibtex/<field>).
    local function deeper(link)
        return (link:gsub("{/ ", "{/ ../"))
    end
    -- Literatures have no categories: they are in the literature fallback bucket, sorted last
    -- like the fallback bucket.
    assert(vim.deep_equal(entries("index/categories/Lossless.norg"), { "** " .. note }))
    assert(
        vim.deep_equal(entries("index/categories/Literatures.norg"), {
            "** " .. doe,
            "** " .. fields,
            "** " .. nokw,
            "** " .. schlecht,
        }),
        vim.inspect(read("index/categories/Literatures.norg"))
    )
    assert(not read("index/categories/Uncategorized.norg"))
    assert(
        vim.deep_equal(section("Categories"), {
            "*** {:index/categories/Lossless:}[Lossless]",
            "*** {:index/categories/Literatures:}[Literatures]",
        }),
        vim.inspect(section("Categories"))
    )
    assert(not read("index/categories/Feedback Delay Network.norg"))
    -- BibTeX keywords: only literatures, with a fallback bucket for literatures without keywords.
    assert(
        vim.deep_equal(
            entries("index/bibtex/keyword/Lossless.norg"),
            { "** " .. deeper(doe), "** " .. deeper(schlecht) }
        ),
        vim.inspect(read("index/bibtex/keyword/Lossless.norg"))
    )
    assert(vim.deep_equal(entries("index/bibtex/keyword/Feedback Delay Network.norg"), { "** " .. deeper(schlecht) }))
    assert(vim.deep_equal(entries("index/bibtex/keyword/Unknown.norg"), { "** " .. deeper(nokw) }))
    assert(has_marker(ws .. "/index/bibtex/keyword"))
    assert(
        vim.deep_equal(section("Keywords"), {
            "**** {:index/bibtex/keyword/Artificial Reverberation:}[Artificial Reverberation]",
            "**** {:index/bibtex/keyword/Diagonal Similarity:}[Diagonal Similarity]",
            "**** {:index/bibtex/keyword/Extra Field:}[Extra Field]",
            "**** {:index/bibtex/keyword/Feedback Delay Network:}[Feedback Delay Network]",
            "**** {:index/bibtex/keyword/Lossless:}[Lossless]",
            "**** {:index/bibtex/keyword/Unknown:}[Unknown]",
        }),
        vim.inspect(section("Keywords"))
    )
    assert(
        vim.tbl_contains(read("index/bibtex/keyword/Lossless.norg"), "** {:../../../index:}[󰜱 index]"),
        vim.inspect(read("index/bibtex/keyword/Lossless.norg"))
    )
    assert(
        vim.deep_equal(entries("index/authors/Sebastian J. Schlecht.norg"), {
            "** " .. note,
            "** " .. schlecht,
        }),
        vim.inspect(read("index/authors/Sebastian J. Schlecht.norg"))
    )
    assert(vim.deep_equal(entries("index/authors/Emanuël A. P. Habets.norg"), { "** " .. schlecht }))
    assert(vim.deep_equal(entries("index/authors/Jane Doe.norg"), { "** " .. doe }))
    assert(
        vim.deep_equal(
            entries("index/created/2016/02.norg"),
            { "** " .. "{/ ../../../literature/other/doe]2020.bib}" .. "[\\[doe\\]2020\\] A \\[bracketed\\] title]" }
        ),
        vim.inspect(read("index/created/2016/02.norg"))
    )
    assert(
        vim.tbl_contains(
            read("index/created/2017/03/15.norg"),
            "** "
                .. "{/ ../../../../literature/"
                .. "schlecht2017lossless.bib}[\\[schlecht2017lossless\\] On Lossless Feedback Delay Networks] "
                .. "{/ ../../../../literature/schlecht2017lossless.pdf}[\\[PDF\\]]"
        ),
        vim.inspect(read("index/created/2017/03/15.norg"))
    )
    -- Literature links are found in generated files.
    local keyword_ix
    for _, ix in ipairs(private.get_active_indexers(vim.fs.normalize(ws))) do
        if ix.def.key == "bibtex.keyword" then
            keyword_ix = ix
        end
    end
    local found = private.find_buckets_for_targets(keyword_ix, {
        private.get_link_target("literature/other/doe]2020.bib"),
    })
    assert(vim.deep_equal(found, { Lossless = true }), vim.inspect(found))

    -- BibTeX field indexers: one value per literature (names with " and " are not split), under
    -- index/bibtex/<field>. `type` and `key` are fields, not the entry type and the citekey. The new
    -- field indexers have no fallback bucket by default.
    local field_values = {
        booktitle = "Proc. Conf.",
        institution = "Inst",
        journal = "J. Audio",
        key = "SortKey",
        organization = "Org",
        publisher = "Institute of Electrical and Electronics Engineers (IEEE)",
        school = "School",
        type = "Technical Report",
        language = "english",
        journaltitle = "Journal Title",
        location = "Berlin",
        pubstate = "inpress",
    }
    for name, value in pairs(field_values) do
        local rel = "index/bibtex/" .. name .. "/" .. value .. ".norg"
        local expected = { "** " .. deeper(fields) }
        if name == "publisher" then
            -- The sample has the same publisher.
            table.insert(expected, "** " .. deeper(schlecht))
        end
        assert(vim.deep_equal(entries(rel), expected), rel .. ": " .. vim.inspect(read(rel)))
        local files = vim.fn.glob(ws .. "/index/bibtex/" .. name .. "/*", false, true)
        assert(#files == (name == "journal" and 2 or 1), vim.inspect(files))
        assert(has_marker(ws .. "/index/bibtex/" .. name))
    end
    -- Event dates: the start of a range, as a date hierarchy.
    assert(
        vim.deep_equal(entries("index/bibtex/eventdate/2020/05/01.norg"), { "** {/ ../../../" .. fields:sub(4) }),
        vim.inspect(read("index/bibtex/eventdate/2020/05/01.norg"))
    )
    assert(not read("index/bibtex/eventdate/Unknown.norg"))
    -- The BibTeX field sections are level-3 headings under one "** BibTeX" heading, after Updated.
    local headings = vim.tbl_filter(function(line)
        return line:match("^%*%* ") ~= nil
    end, read("index.norg"))
    assert(
        vim.deep_equal(headings, {
            "** Categories",
            "** Authors",
            "** Created",
            "** Updated",
            "** BibTeX",
        }),
        vim.inspect(headings)
    )
    local bibtex_headings = {
        "** BibTeX",
        "*** Keywords",
        "*** Book Titles",
        "*** Institutions",
        "*** Journals",
        "*** Keys",
        "*** Organizations",
        "*** Publishers",
        "*** Schools",
        "*** Types",
        "*** Languages",
        "*** Journal Titles",
        "*** Locations",
        "*** Event Dates",
        "*** Publication States",
    }
    local main = main_headings()
    assert(vim.deep_equal(vim.list_slice(main, #main - #bibtex_headings + 1), bibtex_headings), vim.inspect(main))
    -- Exact lines of a section, with a blank line between grouped sections.
    local main_lines = read("index.norg")
    local first = assert(vim.fn.index(main_lines, "** BibTeX") + 1)
    assert(
        vim.deep_equal(vim.list_slice(main_lines, first, first + 10), {
            "** BibTeX",
            "",
            "*** Keywords",
            "**** {:index/bibtex/keyword/Artificial Reverberation:}[Artificial Reverberation]",
            "**** {:index/bibtex/keyword/Diagonal Similarity:}[Diagonal Similarity]",
            "**** {:index/bibtex/keyword/Extra Field:}[Extra Field]",
            "**** {:index/bibtex/keyword/Feedback Delay Network:}[Feedback Delay Network]",
            "**** {:index/bibtex/keyword/Lossless:}[Lossless]",
            "**** {:index/bibtex/keyword/Unknown:}[Unknown]",
            "",
            "*** Book Titles",
        }),
        vim.inspect(main_lines)
    )
    -- Per-field index files keep their own structure: the bucket title, then its entries.
    assert(vim.tbl_contains(read("index/bibtex/keyword/Lossless.norg"), "* Lossless"))
    assert(
        vim.deep_equal(section("Publishers"), {
            "**** {:index/bibtex/publisher/Institute of Electrical and Electronics Engineers (IEEE):}"
                .. "[Institute of Electrical and Electronics Engineers (IEEE)]",
        }),
        vim.inspect(section("Publishers"))
    )
    assert(
        vim.deep_equal(section("Event Dates"), { "**** {:index/bibtex/eventdate/2020:}[2020]" }),
        vim.inspect(section("Event Dates"))
    )
    config.bibtex.eventdate.granularity = "year"
    index()
    assert(vim.deep_equal(entries("index/bibtex/eventdate/2020.norg"), { "** " .. deeper(fields) }))
    assert(vim.fn.isdirectory(ws .. "/index/bibtex/eventdate/2020") == 0)
    config.bibtex.eventdate.granularity = "day"
    -- A fallback bucket for a new field indexer when configured.
    config.bibtex.journal.fallback = "No journal"
    index()
    assert(
        vim.deep_equal(entries("index/bibtex/journal/No journal.norg"), {
            "** " .. deeper(doe),
            "** " .. deeper(nokw),
        }),
        vim.inspect(read("index/bibtex/journal/No journal.norg"))
    )
    config.bibtex.journal.fallback = false
    index()
    assert(not read("index/bibtex/journal/No journal.norg"))

    -- Literature links are found in generated files.
    local keyword_ix
    for _, ix in ipairs(private.get_active_indexers(vim.fs.normalize(ws))) do
        if ix.def.key == "bibtex.keyword" then
            keyword_ix = ix
        end
    end
    local found = private.find_buckets_for_targets(keyword_ix, {
        private.get_link_target("literature/other/doe]2020.bib"),
    })
    assert(vim.deep_equal(found, { Lossless = true }), vim.inspect(found))

    -- Partial update after a .bib change.
    local doe_path = ws .. "/literature/other/doe]2020.bib"
    vim.fn.writefile({
        "@article{doe]2020, title = {Renamed}, author = {Doe, Jane}, keywords = {Moved},",
        "  file = {Full text:papers/doe.pdf:application/pdf}}",
    }, doe_path)
    -- A same-name PDF next to the .bib file is ignored.
    write(ws .. "/literature/other/doe]2020.pdf", { "%PDF" })
    index({ changed_files = { doe_path } })
    assert(vim.deep_equal(entries("index/bibtex/keyword/Lossless.norg"), { "** " .. deeper(schlecht) }))
    local moved = "** {/ ../../../literature/other/doe]2020.bib}[\\[doe\\]2020\\] Renamed]"
    assert(vim.deep_equal(entries("index/bibtex/keyword/Moved.norg"), { moved }))
    -- Creating and deleting the PDF named by the `file` field updates the entry.
    local pdf = ws .. "/literature/other/papers/doe.pdf"
    write(pdf, { "%PDF" })
    index({ changed_files = { pdf } })
    assert(
        vim.deep_equal(entries("index/bibtex/keyword/Moved.norg"), {
            moved .. " {/ ../../../literature/other/papers/doe.pdf}[\\[PDF\\]]",
        }),
        vim.inspect(read("index/bibtex/keyword/Moved.norg"))
    )
    vim.fn.delete(pdf)
    index({ changed_files = { pdf } })
    assert(
        vim.deep_equal(entries("index/bibtex/keyword/Moved.norg"), { moved }),
        vim.inspect(read("index/bibtex/keyword/Moved.norg"))
    )

    -- Removing the last literature of a keyword bucket deletes the bucket file; the literature
    -- moves to the fallback bucket.
    vim.fn.writefile({ "@article{doe]2020, title = {Renamed}, author = {Doe, Jane}, year = 2016}" }, doe_path)
    index({ changed_files = { doe_path } })
    assert(not read("index/bibtex/keyword/Moved.norg"))
    local doe_renamed = "{/ ../../literature/other/doe]2020.bib}[\\[doe\\]2020\\] Renamed]"
    assert(
        vim.deep_equal(
            entries("index/bibtex/keyword/Unknown.norg"),
            { "** " .. deeper(nokw), "** " .. deeper(doe_renamed) }
        ),
        vim.inspect(read("index/bibtex/keyword/Unknown.norg"))
    )
    assert(not vim.tbl_contains(section("Keywords"), "**** {:index/bibtex/keyword/Moved:}[Moved]"))

    -- A partial update after a .bib change updates the field indexes.
    local fields_path = ws .. "/literature/fields.bib"
    vim.fn.writefile(
        { "@misc{fields2021, title = {Fields}, keywords = {Extra Field}, journal = {J. Other}}" },
        fields_path
    )
    index({ changed_files = { fields_path } })
    assert(not read("index/bibtex/journal/J. Audio.norg"))
    -- Field indexes that lose their last bucket lose their section, and get it back with their
    -- first bucket.
    local only_fields = { "Book Titles", "Institutions", "Keys", "Organizations", "Schools", "Types" }
    vim.list_extend(only_fields, { "Languages", "Journal Titles", "Locations", "Event Dates", "Publication States" })
    for _, title in ipairs(only_fields) do
        assert(not vim.tbl_contains(main_headings(), "*** " .. title), vim.inspect(main_headings()))
    end
    assert(vim.tbl_contains(main_headings(), "** BibTeX"))
    assert(vim.tbl_contains(main_headings(), "*** Journals"))
    assert(not read("index/bibtex/school/School.norg"))
    assert(has_marker(ws .. "/index/bibtex/school"))
    assert(vim.deep_equal(entries("index/bibtex/journal/J. Other.norg"), { "** " .. deeper(fields) }))
    assert(
        vim.deep_equal(
            entries("index/bibtex/publisher/Institute of Electrical and Electronics Engineers (IEEE).norg"),
            { "** " .. deeper(schlecht) }
        )
    )
    fields_lines[6] = "  journal = {J. Other},"
    vim.fn.writefile(fields_lines, fields_path)
    index({ changed_files = { fields_path } })
    assert(vim.deep_equal(entries("index/bibtex/journal/J. Other.norg"), { "** " .. deeper(fields) }))
    assert(vim.deep_equal(entries("index/bibtex/type/Technical Report.norg"), { "** " .. deeper(fields) }))
    for _, title in ipairs(only_fields) do
        assert(vim.tbl_contains(main_headings(), "*** " .. title), vim.inspect(main_headings()))
    end
    assert(vim.deep_equal(section("Schools"), { "**** {:index/bibtex/school/School:}[School]" }))
    assert(
        vim.deep_equal(section("Journals"), {
            "**** {:index/bibtex/journal/IEEE Transactions on Signal Processing:}[IEEE Transactions on Signal Processing]",
            "**** {:index/bibtex/journal/J. Other:}[J. Other]",
        }),
        vim.inspect(section("Journals"))
    )

    -- Keywords that differ only by case get collision suffixes; duplicates in one literature are
    -- listed once.
    local coll_path = ws .. "/literature/coll.bib"
    write(coll_path, { "@misc{coll, title = {Collision}, keywords = {lossless; Extra, lossless}}" })
    index({ changed_files = { coll_path } })
    local coll = "{/ ../../../literature/coll.bib}[\\[coll\\] Collision]"
    assert(vim.deep_equal(entries("index/bibtex/keyword/Lossless.norg"), { "** " .. deeper(schlecht) }))
    assert(
        vim.deep_equal(entries("index/bibtex/keyword/lossless~2.norg"), { "** " .. coll }),
        vim.inspect(read("index/bibtex/keyword/lossless~2.norg"))
    )
    assert(vim.deep_equal(entries("index/bibtex/keyword/Extra.norg"), { "** " .. coll }))
    assert(vim.tbl_contains(section("Keywords"), "**** {:index/bibtex/keyword/lossless~2:}[lossless]"))
    vim.fn.delete(coll_path)
    index({ changed_files = { coll_path } })
    assert(not read("index/bibtex/keyword/lossless~2.norg") and not read("index/bibtex/keyword/Extra.norg"))

    -- `fallback = false` leaves literatures without keywords out.
    config.bibtex.keyword.fallback = false
    index()
    assert(not read("index/bibtex/keyword/Unknown.norg"))
    assert(not vim.tbl_contains(section("Keywords"), "**** {:index/bibtex/keyword/Unknown:}[Unknown]"))
    config.bibtex.keyword.fallback = "Unknown"

    -- Inline indexes in the main index.
    config.bibtex.keyword.per_value_index = false
    config.bibtex.journal.per_value_index = false
    config.bibtex.eventdate.per_period_index = false
    index()
    -- Levels deeper than the deepest Norg heading (6) become nested list items: the event date
    -- day is a level-6 heading and its literatures are list items.
    local inline_fields = "{/ literature/fields.bib}[\\[fields2021\\] Fields]"
    assert(vim.deep_equal(section("Event Dates"), { "**** 2020" }), vim.inspect(section("Event Dates")))
    main_lines = read("index.norg")
    first = vim.fn.index(main_lines, "*** Event Dates") + 1
    assert(
        vim.deep_equal(vim.list_slice(main_lines, first, first + 5), {
            "*** Event Dates",
            "**** 2020",
            "***** 2020-05",
            "****** 2020-05-01",
            "- " .. inline_fields,
            "",
        }),
        vim.inspect(main_lines)
    )
    local inline = section("Keywords")
    assert(vim.tbl_contains(inline, "**** Lossless"), vim.inspect(read("index.norg")))
    assert(vim.tbl_contains(inline, "**** Unknown"))
    assert(
        vim.deep_equal(section("Journals"), { "**** IEEE Transactions on Signal Processing", "**** J. Other" }),
        vim.inspect(section("Journals"))
    )
    assert(
        vim.tbl_contains(
            read("index.norg"),
            "***** {/ literature/schlecht2017lossless.bib}[\\[schlecht2017lossless\\] "
                .. "On Lossless Feedback Delay Networks] {/ literature/schlecht2017lossless.pdf}[\\[PDF\\]]"
        ),
        vim.inspect(read("index.norg"))
    )
    assert(not vim.tbl_contains(read("index.norg"), "***** " .. note))
    local inline_metadata = require("neorg.modules.external.indexer.search_index").read(vim.fs.normalize(ws), config)
    assert(
        vim.deep_equal(
            inline_metadata["literature/nokw.bib"]["bibtex.keyword"],
            { { value = "Unknown", lower = "unknown" } }
        ),
        vim.inspect(inline_metadata["literature/nokw.bib"])
    )
    assert(
        vim.deep_equal(
            inline_metadata["literature/fields.bib"]["bibtex.journal"],
            { { value = "J. Other", lower = "j. other" } }
        ),
        vim.inspect(inline_metadata["literature/fields.bib"])
    )
    assert(
        vim.deep_equal(
            inline_metadata["literature/fields.bib"]["bibtex.eventdate"],
            { { value = "2020-05-01", lower = "2020-05-01" } }
        ),
        vim.inspect(inline_metadata["literature/fields.bib"])
    )
    -- Per-file field indexes are still read next to inline ones.
    assert(inline_metadata["literature/fields.bib"]["bibtex.school"] ~= nil)
    config.bibtex.keyword.per_value_index = true
    config.bibtex.journal.per_value_index = true
    config.bibtex.eventdate.per_period_index = true

    -- Disabled with `false` or `enabled = false`: no section and no files.
    local keyword_config = config.bibtex.keyword
    for _, disabled in ipairs({ false, { enabled = false } }) do
        config.bibtex.keyword = disabled
        index()
        headings = main_headings()
        assert(not vim.tbl_contains(headings, "*** Keywords"), vim.inspect(headings))
        assert(vim.tbl_contains(headings, "*** Journals"), vim.inspect(headings))
        local disabled_metadata =
            require("neorg.modules.external.indexer.search_index").read(vim.fs.normalize(ws), config)
        assert(disabled_metadata["literature/nokw.bib"]["bibtex.keyword"] == nil)
    end
    config.bibtex.keyword = keyword_config
    -- `bibtex = false` disables all BibTeX field indexers: no "** BibTeX" heading either.
    local bibtex_config = config.bibtex
    config.bibtex = false
    index()
    headings = vim.tbl_filter(function(line)
        return line:match("^%*%* ") ~= nil
    end, read("index.norg"))
    assert(
        vim.deep_equal(headings, { "** Categories", "** Authors", "** Created", "** Updated" }),
        vim.inspect(headings)
    )
    config.bibtex = bibtex_config
    index()
    assert(read("index/bibtex/keyword/Lossless.norg") and read("index/bibtex/keyword/Unknown.norg"))

    -- Literature fallback bucket: `false` uses the fallback bucket; a custom name; the same name as
    -- the fallback shares its bucket.
    write(ws .. "/plain.norg", { "@document.meta", "title: Plain", "@end" })
    config.categories.literature_fallback = false
    index()
    assert(not read("index/categories/Literatures.norg"))
    -- Entries are sorted by title.
    local lit_lines = { "** " .. fields, "** " .. nokw, "** " .. schlecht, "** " .. doe_renamed }
    local all_lines =
        { "** " .. fields, "** " .. nokw, "** " .. schlecht, "** {:$/plain:}[Plain]", "** " .. doe_renamed }
    assert(
        vim.deep_equal(entries("index/categories/Uncategorized.norg"), all_lines),
        vim.inspect(read("index/categories/Uncategorized.norg"))
    )
    config.categories.literature_fallback = "Papers"
    index()
    assert(
        vim.deep_equal(entries("index/categories/Papers.norg"), lit_lines),
        vim.inspect(read("index/categories/Papers.norg"))
    )
    assert(vim.deep_equal(entries("index/categories/Uncategorized.norg"), { "** {:$/plain:}[Plain]" }))
    assert(
        vim.deep_equal(section("Categories"), {
            "*** {:index/categories/Lossless:}[Lossless]",
            "*** {:index/categories/Papers:}[Papers]",
            "*** {:index/categories/Uncategorized:}[Uncategorized]",
        }),
        vim.inspect(section("Categories"))
    )
    config.categories.literature_fallback = "Uncategorized"
    index()
    assert(
        vim.deep_equal(entries("index/categories/Uncategorized.norg"), all_lines),
        vim.inspect(read("index/categories/Uncategorized.norg"))
    )
    vim.fn.delete(ws .. "/plain.norg")
    config.categories.literature_fallback = "Literatures"
    index()
    assert(read("index/categories/Literatures.norg") and not read("index/categories/Uncategorized.norg"))

    -- Inline mode renders literatures relative to the main index.
    config.authors.per_author_index = false
    index()
    assert(
        vim.tbl_contains(read("index.norg"), "**** {/ literature/other/doe]2020.bib}[\\[doe\\]2020\\] Renamed]"),
        vim.inspect(read("index.norg"))
    )
    config.authors.per_author_index = true
    index()

    -- Search: literatures are mixed with notes.
    local search_notes = require("neorg.modules.external.indexer.search_notes")
    local search_index = require("neorg.modules.external.indexer.search_index")
    local query = require("neorg.modules.external.indexer.search_query")
    local metadata = search_index.read(vim.fs.normalize(ws), config)
    local lit_authors = vim.tbl_map(function(value)
        return value.value
    end, metadata["literature/schlecht2017lossless.bib"].authors)
    table.sort(lit_authors)
    assert(vim.deep_equal(lit_authors, { "Emanuël A. P. Habets", "Sebastian J. Schlecht" }), vim.inspect(lit_authors))
    local items
    search_notes.scan(vim.fs.normalize(ws), search_index.generated_paths(config, vim.fs.normalize(ws)), function()
        return true
    end, function(result)
        items = result
    end, metadata)
    await("scan", function()
        return items ~= nil
    end)
    local by_path = {}
    for _, item in ipairs(items) do
        by_path[item.relative] = item
    end
    assert(not by_path["index/categories/stray.bib"])
    local lit = assert(by_path["literature/schlecht2017lossless.bib"])
    assert(lit.kind == "literature" and lit.citekey == "schlecht2017lossless")
    assert(lit.title.value == "[schlecht2017lossless] On Lossless Feedback Delay Networks")
    assert(lit.pdf == vim.fs.normalize(ws) .. "/literature/schlecht2017lossless.pdf")
    assert(by_path["note.norg"].kind == "note")
    local function matching(prompt, content)
        local groups = assert(query.parse(prompt))
        local result = {}
        for _, item in ipairs(items) do
            local rows = query.match(item, groups, content)
            for _, row in ipairs(rows or {}) do
                table.insert(result, item.relative .. ":" .. (row.lnum or ""))
            end
        end
        return result
    end
    assert(
        vim.deep_equal(matching("lossless", false), {
            "literature/schlecht2017lossless.bib:",
            "note.norg:",
        }),
        vim.inspect(matching("lossless", false))
    )
    assert(vim.deep_equal(matching("schlecht2017", false), { "literature/schlecht2017lossless.bib:" }))
    local lnum
    for i, line in ipairs(sample_lines) do
        if not lnum and line:find("Diagonal Similarity", 1, true) then
            lnum = i
        end
    end
    assert(
        vim.deep_equal(matching("content:similarity", true), {
            "literature/schlecht2017lossless.bib:" .. lnum,
        }),
        vim.inspect(matching("content:similarity", true))
    )
    assert(vim.deep_equal(matching("author:habets", false), { "literature/schlecht2017lossless.bib:" }))
    -- Literatures have no categories: they are in the literature fallback bucket.
    assert(vim.deep_equal(matching("category:lossless", false), { "note.norg:" }))
    assert(
        vim.deep_equal(matching("category:Literatures", false), {
            "literature/fields.bib:",
            "literature/nokw.bib:",
            "literature/other/doe]2020.bib:",
            "literature/schlecht2017lossless.bib:",
        }),
        vim.inspect(matching("category:Literatures", false))
    )
    assert(vim.deep_equal(matching("category:uncategorized", false), {}))
    -- BibTeX keyword filters and their aliases.
    for _, prompt in ipairs({ "keyword:lossless", "keywords:LOSS", "bibtex_keyword:lossless", 'keyword:"diagonal sim"' }) do
        assert(
            vim.deep_equal(matching(prompt, false), { "literature/schlecht2017lossless.bib:" }),
            prompt .. ": " .. vim.inspect(matching(prompt, false))
        )
    end
    assert(vim.deep_equal(matching("keyword:unknown", false), {
        "literature/nokw.bib:",
        "literature/other/doe]2020.bib:",
    }))
    assert(vim.deep_equal(matching("lossless -keyword:lossless", false), { "note.norg:" }))
    assert(vim.deep_equal(matching("-keywords:o", false), { "literature/fields.bib:", "note.norg:" }))
    assert(vim.deep_equal(matching("keyword:moved", false), {}))
    local keyword_rows =
        query.match(by_path["literature/schlecht2017lossless.bib"], assert(query.parse("keywords:lossless")), false)
    local keyword_hit = keyword_rows[1].hits[1]
    assert(keyword_hit.label == "keywords" and keyword_hit.text == "Lossless", vim.inspect(keyword_hit))
    assert(vim.deep_equal(matching("keyword:moved created:2016", false), {}))
    -- BibTeX field filters: `bibtex_<field>:` and short aliases, except for `type` and `key`.
    for _, prompt in ipairs({
        "journal:other",
        "bibtex_type:technical",
        "bibtex_key:sortkey",
        "booktitle:proc",
        "bibtex_journal:other",
        "bibtex_booktitle:conf",
        "institution:inst",
        "organization:org",
        "school:school",
        "language:english",
        "journaltitle:title",
        "location:berlin",
        "pubstate:inpress",
        "bibtex_pubstate:press",
        "eventdate:2020-05",
        "eventdate:2020/05/01",
        "bibtex_eventdate:2020",
        "keyword:extra",
    }) do
        assert(
            vim.deep_equal(matching(prompt, false), { "literature/fields.bib:" }),
            prompt .. ": " .. vim.inspect(matching(prompt, false))
        )
    end
    for _, prompt in ipairs({ "type:technical", "key:sortkey", "TYPE:x", "bibtex_citekey:x", "bibtex_file:x" }) do
        assert(query.parse(prompt) == nil, prompt)
    end
    assert(
        vim.deep_equal(
            matching('publisher:"electrical and"', false),
            { "literature/fields.bib:", "literature/schlecht2017lossless.bib:" }
        ),
        vim.inspect(matching('publisher:"electrical and"', false))
    )
    assert(
        vim.deep_equal(
            matching("bibtex_publisher:IEEE", false),
            { "literature/fields.bib:", "literature/schlecht2017lossless.bib:" }
        ),
        vim.inspect(matching("bibtex_publisher:IEEE", false))
    )
    assert(vim.deep_equal(matching("bibtex_type:inproceedings", false), {}))
    assert(vim.deep_equal(matching("bibtex_key:fields2021", false), {}))
    assert(vim.deep_equal(matching("eventdate:2020-05-03", false), {}))
    assert(vim.deep_equal(matching("fields -journal:other", false), {}))
    assert(vim.deep_equal(matching("renamed -journal:other", false), { "literature/other/doe]2020.bib:" }))
    local type_hit =
        query.match(by_path["literature/fields.bib"], assert(query.parse("bibtex_type:report")), false)[1].hits[1]
    assert(type_hit.label == "bibtex_type" and type_hit.text == "Technical Report", vim.inspect(type_hit))
    local journal_hit =
        query.match(by_path["literature/fields.bib"], assert(query.parse("journal:other")), false)[1].hits[1]
    assert(journal_hit.label == "journal" and journal_hit.text == "J. Other", vim.inspect(journal_hit))
    local date_hit =
        query.match(by_path["literature/fields.bib"], assert(query.parse("eventdate:2020")), false)[1].hits[1]
    assert(date_hit.label == "eventdate" and date_hit.text == "2020-05-01", vim.inspect(date_hit))
    assert(vim.deep_equal(matching("created:2017-03", false), {
        "literature/schlecht2017lossless.bib:",
        "note.norg:",
    }))

    -- Telescope picker: the open_pdf action and its mapping.
    vim.opt.runtimepath:append(plugins .. "/plenary.nvim")
    vim.opt.runtimepath:append(plugins .. "/telescope.nvim")
    local picker_module = require("neorg.modules.external.indexer.search_picker")
    assert(vim.deep_equal(picker_module.mapping_keys(nil), { i = "<C-o>", n = "<C-o>" }))
    assert(vim.deep_equal(picker_module.mapping_keys("<C-p>"), { i = "<C-p>", n = "<C-p>" }))
    assert(vim.deep_equal(picker_module.mapping_keys({ n = "gp" }), { n = "gp" }))
    assert(vim.deep_equal(picker_module.mapping_keys(false), {}))
    local opened = {}
    vim.ui.open = function(path)
        table.insert(opened, path)
    end
    local dirman = assert(modules.get_module("core.dirman"))
    assert(dirman.set_workspace("lit"))
    local state = require("telescope.actions.state")
    local actions = require("telescope.actions")
    local function open_picker(prompt)
        local picker = assert(indexer.search({ previewer = false }))
        picker:set_prompt(prompt)
        await("results for " .. prompt, function()
            return picker.manager and picker.manager:num_results() == 1
        end)
        return picker
    end
    local function mapping(buf, mode, lhs)
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
            if map.lhs == lhs or vim.keycode(map.lhs) == vim.keycode(lhs) then
                return map
            end
        end
    end

    local picker = open_picker("title:schlecht2017")
    assert(state.get_selected_entry().value.kind == "literature")
    local display = state.get_selected_entry().display(state.get_selected_entry())
    assert(
        display == "literature/schlecht2017lossless.bib:[schlecht2017lossless] On Lossless Feedback Delay Networks",
        display
    )
    assert(mapping(picker.prompt_bufnr, "i", "<C-O>") and mapping(picker.prompt_bufnr, "n", "<C-O>"))
    picker_module.actions.open_pdf(picker.prompt_bufnr)
    assert(vim.deep_equal(opened, { lit.pdf }), vim.inspect(opened))
    actions.close(picker.prompt_bufnr)

    -- No PDF, and notes: a warning and nothing opened.
    picker = open_picker("title:renamed")
    local since = #messages
    picker_module.actions.open_pdf(picker.prompt_bufnr)
    assert(count(vim.log.levels.WARN, "no PDF found", since) == 1)
    actions.close(picker.prompt_bufnr)
    -- A same-name PDF next to a .bib file without a `file` field is not opened.
    picker = open_picker("title:keywords")
    since = #messages
    picker_module.actions.open_pdf(picker.prompt_bufnr)
    assert(count(vim.log.levels.WARN, "no PDF found", since) == 1)
    actions.close(picker.prompt_bufnr)
    picker = open_picker("title:note")
    since = #messages
    picker_module.actions.open_pdf(picker.prompt_bufnr)
    assert(count(vim.log.levels.WARN, "is not a literature", since) == 1)
    assert(#opened == 1)
    -- <CR> opens the .bib file at the matched line.
    actions.close(picker.prompt_bufnr)
    picker = open_picker("content:similarity")
    actions.select_default(picker.prompt_bufnr)
    assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) == vim.uv.fs_realpath(lit.path))
    assert(vim.api.nvim_win_get_cursor(0)[1] == lnum)

    -- Configurable mappings.
    config.search.mappings.open_pdf = { i = "<C-y>" }
    picker = open_picker("title:schlecht2017")
    assert(mapping(picker.prompt_bufnr, "i", "<C-Y>") and not mapping(picker.prompt_bufnr, "n", "<C-Y>"))
    local map = mapping(picker.prompt_bufnr, "i", "<C-O>")
    assert(not map or map.desc ~= "Open the PDF of the literature")
    actions.close(picker.prompt_bufnr)
    config.search.mappings.open_pdf = false
    picker = open_picker("title:schlecht2017")
    for _, mode in ipairs({ "i", "n" }) do
        for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(picker.prompt_bufnr, mode)) do
            assert(keymap.desc ~= "Open the PDF of the literature", keymap.lhs)
        end
    end
    actions.close(picker.prompt_bufnr)
end

local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then
    io.stderr:write(err .. "\n")
    vim.cmd("cquit!")
end
print("literature tests passed")
vim.cmd("qa!")
