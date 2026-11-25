# neorg-indexer

Automatic category index generation and optional Telescope note search for Neorg.

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
                    },
                    categories = {
                        enabled = true,
                        dir = "index/categories",
                        fallback = "Uncategorized",
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
                },
            },
        },
    },
}
```

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
main index (`index.norg` by default) has one section per enabled indexer:

```norg
* Index

** Categories
*** {:index/categories/a:}[a]
*** {:index/categories/f:}[f]

** Authors
*** {:index/authors/Ada Lovelace:}[Ada Lovelace]

** Created
*** {:index/created/2025:}[2025]

** Updated
*** {:index/updated/2025:}[2025]
```

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

| Query | Matches |
|-------|---------|
| `roadmap draft \| title:"release plan"` | Both plain terms, or the title phrase. |
| `title:roadmap content:"next steps"` | The title and the body respectively. |
| `roadmap -draft -category:archive` | Notes matching `roadmap` but not `draft` or the `archive` category. |
| `-content:"work in progress"` | Notes without the phrase in their body, even if unqualified terms are configured to search titles only. |
| `author:"Ada Lovelace" category:research` | The `author`/`authors` and `category`/`categories` indexes. |
| `created:2025-03 updated:2025/04` | Notes created in March 2025 and updated in April 2025. |
| `created:2025-03-15` | Notes created on 2025-03-15. |

Metadata filters (`category:`, `author:`, `created:`, `updated:`) match the
generated indexes, not the notes' `@document.meta`. Run `:Neorg indexer` first,
or keep `index_on_change` enabled, so the indexes are current. A filter for a
disabled indexer, or in a workspace without indexes (such as `default`), matches
nothing. Other `key:` filters, such as `status:`, are not supported and make the
query invalid.

`created:` and `updated:` match a substring of the indexed date bucket, such as
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
| `index_on_change` | boolean | `true` | When `true`, regenerate indexes when workspace `.norg` files change. |

`categories.name`, `categories.index_on_launch`, and `categories.index_on_change`
were moved to the top level. The old keys are ignored with a warning.

### Search options

Set these options in `config.search`:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `search_content` | boolean | `true` | Let unqualified terms match the note body as well as the title. Set to `false` for title-only unqualified terms. Explicit `content:` queries always search the body. |
| `include_generated` | boolean | `false` | Also search the main index file (`config.name`) and `.norg` files under each indexer's `dir` that holds generated files (see [Index directories](#index-directories)). All paths are relative to the workspace. |

### Indexer options

Each indexer is configured in its own table: `config.categories`,
`config.authors`, `config.created`, and `config.updated`. These options are
shared by all indexers. Every indexer is enabled when its table is omitted
from the configuration. Set the table to `false` (e.g. `authors = false`) or
set `enabled = false` in it to disable the indexer. Omitted options take their
defaults.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | boolean | `true` | Only the value `false` disables the indexer (as does setting the whole table to `false`). When disabled, the indexer has no section in the main index and writes no files. Its existing directory is left untouched; if it holds generated files, they are still not indexed as notes or searched. |
| `dir` | string | `"index/"` followed by the indexer name (e.g. `"index/authors"`) | Root directory for the indexer's files, relative to the workspace root. See [Index directories](#index-directories) for the rules. |
| `fallback` | string or `false` | `"Uncategorized"` for categories, `"Unknown"` otherwise | Bucket for notes without a value. It always sorts last. Set to `false` to leave such notes out of this index. |
| `sort_by` | string | `"alphabetical"`; `"created"`/`"updated"` for the date indexers | Sort note entries by `alphabetical`, `created`, or `updated`. Ties are broken by case-insensitive title, then by note path. |
| `sort_direction` | string | `"ascending"`; `"descending"` for the date indexers | Sort entries and child buckets in `ascending` or `descending` order. |
| `title_formatter` | function | `function(meta) return meta.title end` | Format a note title from its normalized metadata table. |

#### Categories

Values come from the `categories` metadata field.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
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

Each part of a bucket path (a category level, an author name, a date component, or
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

When a per-file option (`per_subcategory_index`, `per_author_index`, or
`per_period_index`) is `false`, the indexer's hierarchy is rendered in the main
index. Buckets start at heading level 3 and notes are one level below their
bucket, while Norg has only six heading levels. Inline mode therefore suits
shallow hierarchies: categories up to three levels deep fit, and dates with
`granularity = "day"` already use all six levels. Deeper trees are not clamped
and produce headings beyond level 6. Per-file indexes are recommended for deep
category trees and for dates with `granularity = "day"`.
