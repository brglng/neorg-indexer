local MODREV, SPECREV = "scm", "-1"
rockspec_format = "3.0"
package = "neorg-indexer"
version = MODREV .. SPECREV

description = {
    summary = "Index and search Neorg notes and BibTeX literatures by category, author, and date.",
    labels = { "neovim", "neorg" },
    homepage = "https://github.com/brglng/neorg-indexer",
}

dependencies = {
    "lua == 5.1",
    "tree-sitter-bibtex ~> 0.0.32",
}

source = {
    url = "git://github.com/brglng/neorg-indexer",
}

build = {
    type = "builtin",
}
