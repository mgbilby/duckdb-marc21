# Extension config for building `marc21` in-tree with DuckDB.
duckdb_extension_load(marc21
    SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR}
    LOAD_TESTS
)
