# Extension config for building `marc21` in-tree with DuckDB.
#
# core_functions first: the embedded macro bodies reach for array_to_string,
# jaro_winkler_similarity, list_aggregate, list_contains, list_filter,
# list_sort and list_transform -- roughly 200 call sites, list_filter alone
# more than a hundred -- and all of them live in that extension rather than
# in the engine.  Released DuckDB binaries link it statically; a bare
# extension-template build does not, so marc21 would bind its macros against
# a catalog that has none of them.
duckdb_extension_load(core_functions)

# json is not a dependency: marc21 loads and runs without it, and the
# JSON-emitting macros build their text with plain string functions for
# exactly that reason.  It is built here so the three suites that check the
# composition can run -- marc_jsonld, marc_bibframe and marc_reconcile read
# the extension's own output back with ->, ->>, json_valid, json_exists,
# json_array_length and read_json.  Without it those files skip, and the
# claim that the emitted JSON is well formed goes untested.
duckdb_extension_load(json)

duckdb_extension_load(marc21
    SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR}
    LOAD_TESTS
)
