# neorg-indexer

Automatic category index generation and optional Telescope note search for Neorg,
with BibTeX literatures indexed alongside notes.

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

Add the following to your Neorg plugin configuration:

```lua
{
    "nvim-neorg/neorg",
    dependencies = {
        "brglng/neorg-indexer",
    },
    opts = {
        load = {
            ["core.defaults"] = {},
            ["external.indexer"] = {
                config = {
                    name = "index.norg",
                    index_on_launch = false,
                    index_on_change = true,
                    search = {
                        search_content = true,
                        include_generated = false,
                        mappings = {
                            open_pdf = "<C-o>",
                        },
                    },
                    categories = {
                        enabled = true,
                        dir = "index/categories",
                        fallback = "Uncategorized",
                        literature_fallback = "Literatures",
                        subcategory_separator = "/",
                        per_subcategory_index = true,
                        list_subcategory_notes = false,
                        sort_by = "alphabetical",
                        sort_direction = "ascending",
                    },
                    authors = {
                        enabled = true,
                        dir = "index/authors",
                        fallback = "Unknown",
                        per_author_index = true,
                        sort_by = "alphabetical",
                        sort_direction = "ascending",
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
                    },
                    -- `bibtex = false` disables all BibTeX field indexers.
                    bibtex = {
                        keyword = {
                            enabled = true,
                            dir = "index/bibtex/keyword",
                            fallback = "Unknown",
                            per_value_index = true,
                            sort_by = "alphabetical",
                            sort_direction = "ascending",
                        },
                        -- Same options as `keyword`, with `dir = "index/bibtex/<field>"`
                        -- and `fallback = false`:
                        booktitle = {},
                        institution = {},
                        journal = {},
                        key = {},
                        organization = {},
                        publisher = {},
                        school = {},
                        type = {},
                        language = {},
                        journaltitle = {},
                        location = {},
                        pubstate = {},
                        -- A date hierarchy like `created`:
                        eventdate = {
                            dir = "index/bibtex/eventdate",
                            fallback = false,
                            granularity = "day",
                            per_period_index = true,
                            list_subperiod_notes = false,
                            sort_by = "alphabetical",
                            sort_direction = "descending",
                        },
                    },
                },
            },
        },
    },
}
```

The plugin ships a rockspec (`neorg-indexer-scm-1.rockspec`) that depends on
`tree-sitter-bibtex`. lazy.nvim with luarocks support (its default `rocks`
settings, using hererocks when needed) installs the BibTeX parser automatically,
the same way Neorg gets `tree-sitter-norg`. Without lazy.nvim's rocks support,
install the parser with `:TSInstall bibtex` from nvim-treesitter. The parser is
only needed for [literatures](#literatures); without it, `.bib` files are skipped
with one error message and notes still work.

The `core.esupports.metagen` configuration controls metadata generated for index files. For example:

```lua
["core.esupports.metagen"] = {
    config = {
        type = "auto", -- "auto", "empty", or "none"
    },
},
```

## Usage

Run `:Neorg indexer` to generate the indexes for the current workspace. The
main index (`index.norg` by default) has one section per enabled indexer that
has buckets. The sections of the [BibTeX field indexers](#bibtex-field-indexers)
are grouped as level-3 headings under one `** BibTeX` heading:

```norg
* Index

** Categories
*** {:index/categories/a:}[a]
*** {:index/categories/f:}[f]
*** {:index/categories/Literatures:}[Literatures]

** Authors
*** {:index/authors/Ada Lovelace:}[Ada Lovelace]

** Created
*** {:index/created/2025:}[2025]

** Updated
*** {:index/updated/2025:}[2025]

** BibTeX

*** Keywords
**** {:index/bibtex/keyword/Lossless:}[Lossless]

*** Journals
**** {:index/bibtex/journal/IEEE Transactions on Audio, Speech, and Language Processing:}[IEEE Transactions on Audio, Speech, and Language Processing]

*** Publishers
**** {:index/bibtex/publisher/Institute of Electrical and Electronics Engineers (IEEE):}[Institute of Electrical and Electronics Engineers (IEEE)]
```

The `BibTeX` group comes after `Updated`, with its sections in this order:
Keywords, Book Titles, Institutions, Journals, Keys, Organizations, Publishers,
Schools, Types, Languages, Journal Titles, Locations, Event Dates, and
Publication States. A section whose index has no buckets (such as `Schools`
above) is not listed, for any indexer; it appears again once its index gets a
bucket. The `** BibTeX` heading is listed only while one of its sections is (it
is absent when the workspace has no literatures). If no index has buckets, the
main index only keeps its `* Index` heading. The per-value index files under
`index/bibtex/<field>/` are standalone: their top heading is the bucket value.

### Literatures

Each `.bib` file in the workspace is a literature, indexed and searched together
with the notes. The same files are considered as for notes: the whole workspace
including symlinks, but not the main index or generated index directories.

Keep one BibTeX entry per file and name the file after the citekey, for example
`literature/schlecht2017lossless.bib`. Only the first regular entry of a file is
used (`@comment`, `@preamble`, and `@string` are not entries); if a file has more
entries, a warning is logged and the rest are ignored. Files without an entry
are skipped. `@string` macros of the same file, month macros (`jan`..`dec`), `#`
concatenation, and common LaTeX accents (such as `{\"e}` → `ë`) are expanded,
and field names are case-insensitive.

The entry is projected onto the metadata used for notes:

| BibTeX field | Metadata | Notes |
|--------------|----------|-------|
| `title` | `title` | Falls back to the citekey. |
| `author` (else `editor`) | `authors` | Split on ` and ` outside braces; `Last, First` becomes `First Last`; `others` is dropped. |
| `abstract` | `description` | |
| `date`, else `year` and `month` | `created` and `updated` | For example `2017-03-15`, or `2017-03` from `year = 2017, month = mar`. |
| `file` | (none) | The [PDF](#pdf) of the literature. |

Literatures have no categories: they are in the categories `literature_fallback`
bucket (`Literatures` by default, see [Categories](#categories)).

These raw fields are indexed by their own [BibTeX field indexers](#bibtex-field-indexers)
and searched with the listed filters:

| BibTeX field | Indexer | Filters |
|--------------|---------|---------|
| `keywords` | `bibtex.keyword` | `keyword:`, `keywords:`, `bibtex_keyword:` |
| `booktitle` | `bibtex.booktitle` | `booktitle:`, `bibtex_booktitle:` |
| `institution` | `bibtex.institution` | `institution:`, `bibtex_institution:` |
| `journal` | `bibtex.journal` | `journal:`, `bibtex_journal:` |
| `key` (not the citekey) | `bibtex.key` | `bibtex_key:` |
| `organization` | `bibtex.organization` | `organization:`, `bibtex_organization:` |
| `publisher` | `bibtex.publisher` | `publisher:`, `bibtex_publisher:` |
| `school` | `bibtex.school` | `school:`, `bibtex_school:` |
| `type` (not the entry type) | `bibtex.type` | `bibtex_type:` |
| `language` | `bibtex.language` | `language:`, `bibtex_language:` |
| `journaltitle` | `bibtex.journaltitle` | `journaltitle:`, `bibtex_journaltitle:` |
| `location` | `bibtex.location` | `location:`, `bibtex_location:` |
| `eventdate` | `bibtex.eventdate` | `eventdate:`, `bibtex_eventdate:` |
| `pubstate` | `bibtex.pubstate` | `pubstate:`, `bibtex_pubstate:` |

All other fields, such as `address`, `annote`, `chapter`, `crossref`, `edition`,
`howpublished`, `note`, `number`, `pages`, `series`, `volume`, `doi`, `url`,
`urldate`, `isbn`, `issn`, `eprint`, `archiveprefix`/`eprinttype`,
`primaryclass`/`eprintclass`, `subtitle`, and `addendum`, are kept raw only. All
fields (including the projected and indexed ones), the entry type, and the
citekey are kept in the metadata (`meta.citekey`, `meta.kind = "literature"`, and
`meta.bibtex = { type = ..., key = ..., fields = { ... } }`, with lowercase field
names), so a `title_formatter` can use them, but only the indexed ones are
searchable by metadata.

#### PDF

The PDF of a literature comes only from the `file` field of its entry; a PDF
next to the `.bib` file is not used otherwise. Supported values:

- a plain path, such as `file = {schlecht2017lossless.pdf}`;
- several files separated by `;`, of which the first with a `.pdf` extension
  (any case) that exists is used;
- JabRef/Zotero items `Description:path:Type`, such as
  `file = {:papers/x.pdf:PDF;Slides:x.pptx:PowerPoint}`. JabRef escapes (`\:`,
  `\;`, `\\`) are unescaped, and a Windows drive letter (`C:\papers\x.pdf`) is
  kept as part of the path on a best-effort basis.

Paths may be absolute, start with `~`, or be relative to the directory of the
`.bib` file. A literature without a `file` field, or whose files do not exist,
has no PDF.

In index files a literature has the same heading level as a note, and links to
its `.bib` file and PDF:

```norg
** {/ ../../literature/schlecht2017lossless.bib}[\[schlecht2017lossless\] On Lossless Feedback Delay Networks] {/ ../../literature/schlecht2017lossless.pdf}[\[PDF\]]
```

The description starts with `[citekey]`, and the `[PDF]` link is only present
when a PDF is found. Their brackets, and `[`, `]`, and `\` in citekeys and titles,
are escaped with `\` so that they are displayed literally. Neorg resolves relative `{/ path}` links from the directory
of the file that contains them and does not expand `$/` in file links, so the
paths are relative to the index file.

With `index_on_change`, changes to `.bib` files update the indexes (including the
BibTeX field indexes) like changes to notes, and adding, removing, or renaming a
PDF updates the literatures whose `file` field names it, adding or removing their
`[PDF]` link.

### Live note search

Install `nvim-telescope/telescope.nvim` and its dependency `nvim-lua/plenary.nvim`
for search. For example, add this spec to your lazy.nvim plugins:

```lua
{
    "nvim-telescope/telescope.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    lazy = true,
}
```

Run `:Neorg indexer-search` and type in the picker. Search reads saved `.norg`
files recursively in the current Dirman workspace (the current working directory
for the `default` workspace). It ignores unsaved edits and symlinks, and does not
use a database or an external grep tool. Titles and body text come from the notes;
metadata filters read the generated indexes (see below). Generated indexes are
excluded from the results by default; see [Search options](#search-options) to
include them. Reopen the picker to pick up changes on disk. Use Telescope's usual open
and split mappings.

Search uses case-insensitive literal substrings. Spaces are AND; `|` is OR and
binds less tightly. Prefix a term or filter with `-` (no space) to exclude
notes that match it from that OR branch. A query with only exclusions returns
notes that pass them. Use double quotes for phrases, literal pipes, or a literal
leading `-`, and `\"` for a literal quote inside a phrase. Empty or incomplete
queries show no results. Plain terms match titles or body text outside
`@document.meta`, preferring the title when both match; notes without a title use
the filename stem. AND terms can match on different lines of the same note.
Each matching body line from a successful group gets one result, shown as
`path/to/file.norg:42:full line text`. Previewing or opening that result jumps to
line 42. Groups that match without the body get a `path/to/file.norg:title` result
with no line number. Matched metadata appears after the path, for example
`notes/a.norg:[authors: Ada]:42:line text`. Notes with title matches rank first,
with ties ordered by workspace-relative path and body lines in file order.

Literatures appear among the notes. Their title is `[citekey] title`, so plain
terms and `title:` match the citekey too, and their body is the text of the `.bib`
file, for example `literature/x.bib:12:  keywords = {Lossless},`. Metadata
filters match literatures through the generated indexes. Opening a literature
opens its `.bib` file (at the matched line). Press `<C-o>` (insert and normal
mode, see `search.mappings.open_pdf`) to open the PDF of the selected literature
with the system default application (`vim.ui.open`); it warns when the
literature has no PDF. The action is also
available as `require("neorg.modules.external.indexer.search_picker").actions.open_pdf`
for custom Telescope mappings.

| Query | Matches |
|-------|---------|
| `roadmap draft \| title:"release plan"` | Both plain terms, or the title phrase. |
| `title:roadmap content:"next steps"` | The title and the body respectively. |
| `roadmap -draft -category:archive` | Notes matching `roadmap` but not `draft` or the `archive` category. |
| `-content:"work in progress"` | Notes without the phrase in their body, even if unqualified terms are configured to search titles only. |
| `author:"Ada Lovelace" category:research` | The `author`/`authors` and `category`/`categories` indexes. |
| `keyword:lossless -keywords:draft` | The BibTeX keyword index (`keyword`, `keywords`, or `bibtex_keyword`). |
| `journal:"signal processing" bibtex_type:phdthesis` | The BibTeX journal and type indexes; see [Literatures](#literatures) for all BibTeX filters. |
| `eventdate:2020-05` | Literatures whose event (or event range) starts in May 2020. |
| `created:2025-03 updated:2025/04` | Notes created in March 2025 and updated in April 2025. |
| `created:2025-03-15` | Notes created on 2025-03-15. |

Metadata filters (`category:`, `author:`, `created:`, `updated:`, and the
[BibTeX filters](#literatures)) match the generated indexes, not the notes' `@document.meta`. Run `:Neorg indexer` first,
or keep `index_on_change` enabled, so the indexes are current. A filter for a
disabled indexer, or in a workspace without indexes (such as `default`), matches
nothing. Other `key:` filters, such as `status:`, are not supported and make the
query invalid. The BibTeX `type` and `key` fields have no short filters (`type:`
and `key:` are invalid); use `bibtex_type:` and `bibtex_key:`. Matched metadata of a
literature is labeled with the filter name, for example `[journal: …]`,
`[keywords: …]`, or `[bibtex_type: …]`.

`created:`, `updated:`, and `eventdate:` match a substring of the indexed date bucket, such as
`2025-03-15`. Use either `-` or `/` between date components. Time of day is not
indexed and cannot be searched. With a coarser `granularity`, only coarser
queries match: with `granularity = "month"`, `created:2025-03` matches but
`created:2025-03-15` does not. Notes without a parseable date are in the
`fallback` bucket, so `created:unknown` finds them by default.

To open the picker from Lua, optionally without a preview:

```lua
require("neorg.core").modules.get_module("external.indexer").search({ previewer = false })
```

## Configuration

Set these options under `load["external.indexer"].config` in your Neorg setup.

### General options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `name` | string | `"index.norg"` | Name of the main index file, relative to the workspace root. |
| `index_on_launch` | boolean | `false` | When `true`, generate indexes when the module is loaded. |
| `index_on_change` | boolean | `true` | When `true`, regenerate indexes when workspace `.norg` or `.bib` files (or the PDFs of literatures) change. |

`categories.name`, `categories.index_on_launch`, and `categories.index_on_change`
were moved to the top level. The old keys are ignored with a warning.

### Search options

Set these options in `config.search`:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `search_content` | boolean | `true` | Let unqualified terms match the note body as well as the title. Set to `false` for title-only unqualified terms. Explicit `content:` queries always search the body. |
| `include_generated` | boolean | `false` | Also search the main index file (`config.name`) and `.norg` files under each indexer's `dir` that holds generated files (see [Index directories](#index-directories)). All paths are relative to the workspace. |
| `mappings.open_pdf` | string, table, or `false` | `"<C-o>"` | Picker key that opens the PDF of the selected literature. A string maps the key in insert and normal mode; a table such as `{ i = "<C-o>", n = "gp" }` maps each mode separately (modes without a key are not mapped); `false` disables the mapping. |

### Indexer options

Each indexer is configured in its own table: `config.categories`,
`config.authors`, `config.created`, `config.updated`, and the
[BibTeX field indexers](#bibtex-field-indexers) in `config.bibtex` (such as
`config.bibtex.journal`). These options are shared by all indexers. Every indexer is enabled when its table is omitted
from the configuration. Set the table to `false` (e.g. `authors = false`) or
set `enabled = false` in it to disable the indexer. Omitted options take their
defaults.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `true` | Only the value `false` disables the indexer (as does setting the whole table to `false`). When disabled, the indexer has no section in the main index and writes no files. Its existing directory is left untouched; if it holds generated files, they are still not indexed as notes or searched. |
| `dir` | string | `"index/"` followed by the indexer name (e.g. `"index/authors"`, `"index/bibtex/journal"`) | Root directory for the indexer's files, relative to the workspace root. See [Index directories](#index-directories) for the rules. |
| `fallback` | string or `false` | `"Uncategorized"` for categories, `false` for BibTeX fields other than `keyword`, `"Unknown"` otherwise | Bucket for notes without a value. It always sorts last. Set to `false` to leave such notes out of this index. |
| `sort_by` | string | `"alphabetical"`; `"created"`/`"updated"` for `created`/`updated` | Sort note entries by `alphabetical`, `created`, or `updated`. Ties are broken by case-insensitive title, then by note path. |
| `sort_direction` | string | `"ascending"`; `"descending"` for the date indexers (including `bibtex.eventdate`) | Sort entries and child buckets in `ascending` or `descending` order. |
| `title_formatter` | function | `function(meta) return meta.title end` | Format a note title from its normalized metadata table. |

#### Categories

Values come from the `categories` metadata field.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `literature_fallback` | string or `false` | `"Literatures"` | Bucket for [literatures](#literatures), which have no categories. Like `fallback`, it sorts last (after other categories; if both are used, the two are ordered by name). If it equals `fallback`, notes and literatures share the bucket. Set to `false` to treat literatures like notes without categories (`fallback`). Search it with `category:literatures`. |
| `subcategory_separator` | string | `"/"` | Separator for hierarchical values, such as `"a/b/c"`. |
| `per_subcategory_index` | boolean | `true` | When `true`, write each category index to a separate file. When `false`, render the hierarchy in the main index. |
| `list_subcategory_notes` | boolean | `false` | When `true`, add a `Notes` heading containing descendant notes. When `false`, list only direct notes under each category. |

#### Authors

Values come from the `authors` (or `author`) metadata field, as a string or a
list. Authors are not hierarchical.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `per_author_index` | boolean | `true` | When `true`, write each author index to a separate file. When `false`, list authors and their notes in the main index. |

#### Created and updated

Values come from the `created` and `updated` metadata fields. A timestamp must
start with `YYYY-MM-DD`, `YYYY-MM`, or `YYYY`, with `-` or `/` as the
separator. The month and day may have one or two digits and are zero-padded
(`2025-3-5` is filed under `2025/03/05`). Anything may follow the date if it
does not start with a digit, such as a time (`2025-03-05T10:00:00+0000`). The
month must be 1–12 and the day 1–31; otherwise, as with `2025-13-01` or
`2025-03-150`, the note goes to the `fallback` bucket.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `granularity` | string | `"day"` | Finest bucket: `"year"`, `"month"`, or `"day"`. Any other value logs a warning and uses `"day"`. |
| `per_period_index` | boolean | `true` | When `true`, write each period index to a separate file. When `false`, render the hierarchy in the main index. |
| `list_subperiod_notes` | boolean | `false` | When `true`, add a `Notes` heading containing the notes of all subperiods. |

#### BibTeX field indexers

Each indexer in `config.bibtex` indexes one raw field of
[literatures](#literatures) (see the table there for the fields and filters).
`bibtex = false` disables all of them; otherwise each follows the usual rules
(omitted or a table: enabled; `false` or `enabled = false`: disabled). Only
literatures are indexed: notes are never listed, and `fallback` applies only to
literatures without the field. Values keep their original spelling; values that
differ only in case get separate buckets (see [File names](#file-names)).

The flat indexers (all except `eventdate`) are not hierarchical. `keyword` splits
the `keywords` field on `,` or `;`, trims the keywords, drops empty ones, and lists
a literature once per keyword. The other fields have one value per literature,
which is never split: `publisher = {Institute of Electrical and Electronics
Engineers (IEEE)}` is one publisher.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `per_value_index` | boolean | `true` | When `true`, write each value's index to a separate file. When `false`, list values and their literatures in the main index. |

`eventdate` is a date hierarchy with the options of
[Created and updated](#created-and-updated) (`granularity`, `per_period_index`,
`list_subperiod_notes`) and the same date parsing. For a range such as
`2020-05-01/2020-05-03`, the start date is used. Its default `sort_by` is
`"alphabetical"`.

The indexer does not have a separate metadata-injection option. Generated index metadata follows `core.esupports.metagen`'s `type` setting:

- `"none"` does not create metadata. Existing metadata is preserved.
- `"auto"` creates metadata when an index file does not already have it.
- `"empty"` creates metadata only for new index files.

When existing metadata is regenerated, the metagen `update_date` setting controls whether its `updated` field is refreshed.

## Index File Structure

### Index directories

Each enabled indexer's `dir` must be a non-empty relative path strictly inside
the workspace (`""`, `"."`, `".."`, `"a/.."`, and absolute paths are invalid).
It must not equal, contain, or be inside another enabled indexer's `dir` or the
main index file (`name`). An indexer with an invalid `dir` logs an error once
and is skipped: it writes and deletes nothing.

The indexer writes a marker file, `.neorg-indexer`, into each directory it
generates. A full rebuild deletes and recreates a directory only when it contains
the marker, and partial updates delete obsolete files only from marked
directories. A missing or empty directory is used as is. If the directory exists,
is not empty, and has no marker (for example, your own `index/authors` folder), the
indexer logs an error once and skips that index rather than overwrite your files;
the notes in it are indexed as ordinary notes.

Earlier versions wrote category indexes to `categories/` by default and without a
marker. That directory is no longer used by default, so its old files would be
indexed as ordinary notes: delete it before indexing, or keep it by setting
`categories.dir = "categories"` and creating an empty `.neorg-indexer` file in it.

A configured indexer directory that contains the marker is treated as generated
even when the indexer is disabled: its files are not indexed as notes, do not
trigger re-indexing, and are excluded from search unless `include_generated` is
set.

### File names

Each part of a bucket path (a category level, an author name, a BibTeX value, a date component, or
a fallback name) becomes a file or directory name. Characters that are unsafe in
file names or Norg links are encoded as `=` followed by two uppercase hexadecimal
digits of the byte: `=`, `~`, `%`, `&`, `$`, `` ` ``, `/`, `\`, `:`, `[`, `]`,
`{`, `}`, `*`, `?`, `"`, `<`, `>`, `|`, control characters, and a leading `.`,
`(`, `)`, or space. For example, author `X/Y` is written to `index/authors/X=2FY.norg`,
and with `subcategory_separator = "."`, category `a/b.c` is written to
`index/categories/a=2Fb/c.norg`.

Names that differ only in case (such as authors `Ada` and `ada`) would collide
on case-insensitive file systems, so sibling names are compared
case-insensitively. In sorted order of the original names, the first keeps its
name and the others get a `~2`, `~3`, … suffix: `index/authors/Ada.norg` and
`index/authors/ada~2.norg`. Headings and link descriptions always show the real value
(with `]` and `\` escaped by a backslash), and search reads the value from the
heading or the decoded path.

When per-file indexes are enabled, each indexer writes its files under its `dir`.
Each index links to its child indexes and its parent; top-level indexes link back
to the main index.

For example, given notes with categories `a/b/c`, `a/b/d`, `a/e`, and `f`:

```text
index/categories/
├── a/
│   ├── b/
│   │   ├── c.norg          # index for category "a/b/c"
│   │   └── d.norg          # index for category "a/b/d"
│   ├── b.norg              # index for category "a/b"
│   └── e.norg              # index for category "a/e"
├── a.norg                  # index for category "a"
└── f.norg                  # index for category "f"
```

When `list_subcategory_notes` is enabled, each category index also lists all
descendant notes under a separate `Notes` heading.

Author indexes are flat:

```text
index/authors/
├── Ada Lovelace.norg       # heading "Ada Lovelace"
├── X=2FY.norg              # heading "X/Y"
└── Unknown.norg            # notes without authors
```

The flat BibTeX field indexes list only literatures, each under its own
directory in `index/bibtex/`:

```text
index/bibtex/
├── keyword/
│   ├── Lossless.norg       # heading "Lossless"
│   ├── lossless~2.norg     # heading "lossless"
│   └── Unknown.norg        # literatures without keywords
├── journal/
│   └── IEEE Transactions on Audio, Speech, and Language Processing.norg
├── type/
│   └── phdthesis.norg      # BibTeX `type` field, not the entry type
└── eventdate/
    ├── 2020/
    │   ├── 05/
    │   │   └── 01.norg     # heading "2020-05-01"
    │   └── 05.norg         # heading "2020-05"
    └── 2020.norg           # heading "2020"
```

Categories put literatures in a flat `Literatures.norg` bucket.

Date indexes are nested by year, month, and day, down to `granularity`. Headings
and links show the full date prefix:

```text
index/created/
├── 2025/
│   ├── 03/
│   │   └── 15.norg         # heading "2025-03-15"
│   └── 03.norg             # heading "2025-03"
├── 2025.norg               # heading "2025"
└── Unknown.norg            # notes without a parseable date
```

### Inline mode

When a per-file option (`per_subcategory_index`, `per_author_index`,
`per_value_index` of a BibTeX field, or
`per_period_index`) is `false`, the indexer's hierarchy is rendered in the main
index. Buckets start at heading level 3 (level 4 for the BibTeX field indexers,
which are under the `** BibTeX` heading) and notes are one level below their
bucket, while Norg has only six heading levels. Levels beyond 6 become nested
unordered list items under the deepest heading: level 7 is `-`, level 8 is `--`,
and so on. For example, `bibtex.eventdate` with `per_period_index = false` and
`granularity = "day"`:

```norg
** BibTeX

*** Event Dates
**** 2020
***** 2020-05
****** 2020-05-01
- {/ literature/fields.bib}[\[fields2021\] Fields]
```

Inline mode therefore reads best with shallow hierarchies: categories up to three
levels deep and dates (except BibTeX event dates by day) are headings all the
way down. Per-file indexes are recommended for deep category trees.
