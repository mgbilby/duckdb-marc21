// Shared assertion macros for the standalone core test binaries.  Each
// test/cpp/*_test.cpp is its own program:
//   g++ -std=c++17 -Wall -O2 -Isrc/include src/core/*.cpp test/cpp/<name>_test.cpp -o <name>_test
#pragma once

#include <cstdio>

static int failures = 0;
#define CHECK(cond)                                                                                                    \
	do {                                                                                                               \
		if (!(cond)) {                                                                                                 \
			std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                       \
			failures++;                                                                                                \
		}                                                                                                              \
	} while (0)
#define CHECK_EQ(a, b)                                                                                                 \
	do {                                                                                                               \
		auto va = (a);                                                                                                 \
		auto vb = (b);                                                                                                 \
		if (!(va == vb)) {                                                                                             \
			std::fprintf(stderr, "FAIL %s:%d: %s != %s\n", __FILE__, __LINE__, #a, #b);                                \
			failures++;                                                                                                \
		}                                                                                                              \
	} while (0)

#define CHECKS_MAIN_RESULT()                                                                                           \
	(failures == 0 ? (std::printf("all checks passed\n"), 0) : (std::printf("%d failure(s)\n", failures), 1))
