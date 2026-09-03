# Uses the shared DuckDB extension build system (git submodules: duckdb,
# extension-ci-tools).  `make release` / `make debug` / `make test`.
PROJ_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

EXT_NAME=marc21
EXT_CONFIG=${PROJ_DIR}extension_config.cmake

include extension-ci-tools/makefiles/duckdb_extension.Makefile

# Convenience targets beyond the shared makefile
.PHONY: core_test
core_test:
	for t in core z3950 z3950_socket; do \
		g++ -std=c++17 -Wall -O2 -pthread -Isrc/include src/core/*.cpp test/cpp/$${t}_test.cpp -o build/$${t}_test && \
		./build/$${t}_test || exit 1; done
