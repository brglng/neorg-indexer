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
                    search = {
                        search_content = true,
                        include_generated = false,
                    },
                    categories = {
                        name = "index.norg",
                        dir = "categories",
                        index_on_launch = false,
                        index_on_change = true,
                        subcategory_separator = "/",
                        per_subcategory_index = true,
                        list_subcategory_notes = true,
                        sort_by = "alphabetical",
                        sort_direction = "ascending",
                        title_formatter = function(meta)
                            return meta.title
                        end,
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

Run `:Neorg indexer` to generate the index for the current workspace.

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
use the category index, a database, or an external grep tool. Generated category
indexes are excluded by default; see [Search options](#search-options) to include
them. Reopen the picker to pick up changes on disk. Use Telescope's usual open
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
| `author:"Ada Lovelace" category:research` | The `author`/`authors` and `category`/`categories` metadata fields. |
| `status:active project:"New Website"` | Arbitrary scalar metadata or individual list items. |
| `created:2025-03 updated:2025/04` | Notes created in March 2025 and updated in April 2025. |
| `created:2025/03/15` | Notes with `2025-03-15` or `2025/03/15` in their `created` timestamp. |

`created:` and `updated:` search the stored timestamp as a substring, without
time zone conversion. Use either `-` or `/` between date components.

To open the picker from Lua, optionally without a preview:

```lua
require("neorg.core").modules.get_module("external.indexer").search({ previewer = false })
```

## Configuration

Set these options under `load["external.indexer"].config` in your Neorg setup.

### Search options

Set these options in `config.search`:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `search_content` | boolean | `true` | Let unqualified terms match the note body as well as the title. Set to `false` for title-only unqualified terms. Explicit `content:` queries always search the body. |
| `include_generated` | boolean | `false` | Also search the file at `config.categories.name` and `.norg` files under `config.categories.dir`. Both paths are relative to the workspace. |

### Category index options

Set these options in `config.categories`:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `name` | string | `"index.norg"` | Name of the main category index file. |
| `dir` | string | `"categories"` | Root directory for per-subcategory index files, relative to the workspace root. |
| `index_on_launch` | boolean | `false` | When `true`, generate indexes when the module is loaded. |
| `index_on_change` | boolean | `true` | When `true`, regenerate indexes when workspace `.norg` files change. |
| `subcategory_separator` | string | `"/"` | Separator for hierarchical values in the `categories` metadata field, such as `"a/b/c"`. |
| `per_subcategory_index` | boolean | `true` | When `true`, write each subcategory index to a separate file. When `false`, render the hierarchy in the main index. |
| `list_subcategory_notes` | boolean | `true` | When `true`, add a `Notes` heading containing descendant notes. When `false`, list only direct notes under each category. |
| `sort_by` | string | `"alphabetical"` | Sort note entries by `alphabetical`, `created`, or `updated`. |
| `sort_direction` | string | `"ascending"` | Sort entries in `ascending` or `descending` order. |
| `title_formatter` | function | `function(meta) return meta.title end` | Format a note title from its normalized metadata table. |

The indexer does not have a separate metadata-injection option. Generated index metadata follows `core.esupports.metagen`'s `type` setting:

- `"none"` does not create metadata. Existing metadata is preserved.
- `"auto"` creates metadata when an index file does not already have it.
- `"empty"` creates metadata only for new index files.

When existing metadata is regenerated, the metagen `update_date` setting controls whether its `updated` field is refreshed.

## Subcategory Index Structure

When `per_subcategory_index` is enabled, category index files are organized under `dir`:

- **All categories**: `<dir>/<path>/<category_name>.norg`

For example, given files with categories `a/b/c`, `a/b/d`, `a/e`, and `f`:

```text
categories/
├── a/
│   ├── b/
│   │   ├── c.norg          # index for category "a/b/c"
│   │   └── d.norg          # index for category "a/b/d"
│   ├── b.norg              # index for category "a/b"
│   └── e.norg              # index for category "a/e"
├── a.norg                  # index for category "a"
└── f.norg                  # index for category "f"
```

Each category index links to its child indexes and its parent. When `list_subcategory_notes` is enabled, it also lists all descendant notes under a separate `Notes` heading.
