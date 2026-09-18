# neorg-indexer

Automatic category index generation for Neorg.

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

## Configuration

All current indexing options are grouped under `config.categories`, leaving room for future indexers based on other metadata fields.

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
