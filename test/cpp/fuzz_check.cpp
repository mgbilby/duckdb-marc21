// Differential fuzz replay: cases from tools/gen_fuzz_cases.py through
// marc::Marc8Decode, compared to the marcref.py expected outputs.
//   g++ -std=c++17 -Isrc/include src/core/*.cpp test/cpp/fuzz_check.cpp -o fuzz_check
//   ./fuzz_check /tmp/fuzz/in.bin /tmp/fuzz/expected.txt
// File format: cases separated by "\n---\n"; within a case, backslash and
// newline are backslash-escaped.
#include "marc/core.hpp"

#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

static std::vector<std::string> LoadCases(const char *path) {
	std::ifstream in(path, std::ios::binary);
	if (!in.good()) {
		std::fprintf(stderr, "fuzz_check: cannot open %s\n", path);
		std::exit(2);
	}
	std::ostringstream ss;
	ss << in.rdbuf();
	std::string data = ss.str();

	std::vector<std::string> cases;
	const std::string sep = "\n---\n";
	size_t pos = 0;
	while (true) {
		size_t next = data.find(sep, pos);
		std::string chunk = data.substr(pos, next == std::string::npos ? next : next - pos);
		std::string unescaped;
		unescaped.reserve(chunk.size());
		for (size_t i = 0; i < chunk.size(); i++) {
			if (chunk[i] == '\\' && i + 1 < chunk.size()) {
				unescaped.push_back(chunk[i + 1] == 'n' ? '\n' : chunk[i + 1]);
				i++;
			} else {
				unescaped.push_back(chunk[i]);
			}
		}
		cases.push_back(std::move(unescaped));
		if (next == std::string::npos) {
			break;
		}
		pos = next + sep.size();
	}
	return cases;
}

static void PrintHex(const std::string &s) {
	for (unsigned char c : s) {
		std::fprintf(stderr, "%02X", c);
	}
	std::fprintf(stderr, "\n");
}

int main(int argc, char **argv) {
	if (argc != 3) {
		std::fprintf(stderr, "usage: %s <in.bin> <expected.txt>\n", argv[0]);
		return 2;
	}
	auto inputs = LoadCases(argv[1]);
	auto expected = LoadCases(argv[2]);
	if (inputs.size() != expected.size()) {
		std::fprintf(stderr, "fuzz_check: %zu inputs but %zu expected outputs\n", inputs.size(), expected.size());
		return 2;
	}
	int mismatches = 0;
	for (size_t i = 0; i < inputs.size(); i++) {
		std::string got = marc::Marc8Decode(inputs[i]);
		if (got != expected[i]) {
			mismatches++;
			std::fprintf(stderr, "MISMATCH case %zu\n  input:    ", i);
			PrintHex(inputs[i]);
			std::fprintf(stderr, "  expected: ");
			PrintHex(expected[i]);
			std::fprintf(stderr, "  got:      ");
			PrintHex(got);
		}
	}
	if (mismatches) {
		std::fprintf(stderr, "fuzz_check: %d/%zu mismatches\n", mismatches, inputs.size());
		return 1;
	}
	std::printf("fuzz_check: %zu cases match\n", inputs.size());
	return 0;
}
