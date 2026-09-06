# Uses the shared DuckDB extension build system (git submodules: duckdb,
# extension-ci-tools).  `make release` / `make debug` / `make test`.
PROJ_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

EXT_NAME=marc21
EXT_CONFIG=${PROJ_DIR}extension_config.cmake

include extension-ci-tools/makefiles/duckdb_extension.Makefile

# Convenience targets beyond the shared makefile
.PHONY: core_test
core_test:
	mkdir -p build
	for t in core z3950 z3950_socket; do \
		g++ -std=c++17 -Wall -O2 -pthread -Isrc/include src/core/*.cpp test/cpp/$${t}_test.cpp -o build/$${t}_test && \
		./build/$${t}_test || exit 1; done

# Differential fuzz replay: MARC-8 decoding vs an independent reference
# decoder.  The committed corpus in test/data/fuzz was produced by the
# generators in audit/tools; see audit/PROVENANCE.md.
.PHONY: fuzz_check
fuzz_check:
	mkdir -p build
	g++ -std=c++17 -Wall -O2 -pthread -Isrc/include src/core/*.cpp test/cpp/fuzz_check.cpp -o build/fuzz_check
	./build/fuzz_check test/data/fuzz/in.bin test/data/fuzz/expected.txt
