//! Minimal RFC 8259 JSON DOM shared by the Avram and MARC-in-JSON readers.
//! Extracted from avram.cpp unchanged in behaviour: full string escapes
//! (surrogate pairs included), 100-level depth cap, trailing-data rejection.
#pragma once

#include "marc/core.hpp"

#include <utility>

namespace marc {

struct JsonValue {
	enum class Type { NUL, BOOL, NUM, STR, ARR, OBJ };
	Type type = Type::NUL;
	bool boolean = false;
	std::string str; // STR content; for NUM the raw token text
	std::vector<JsonValue> arr;
	std::vector<std::pair<std::string, JsonValue>> obj; // insertion order kept

	const JsonValue *Get(std::string_view key) const {
		for (auto &kv : obj) {
			if (kv.first == key) {
				return &kv.second;
			}
		}
		return nullptr;
	}
};

// Parse a complete JSON text; anything but trailing whitespace after the value
// is an error.  MarcError messages read "<context>: malformed JSON at byte N".
JsonValue ParseJson(std::string_view text, std::string_view context = "json");

// Parse one value starting at `pos` (leading whitespace skipped); on return
// `pos` is just past the value.  Callers loop over this for NDJSON.
JsonValue ParseJsonValueAt(std::string_view text, size_t &pos, std::string_view context = "json");

// Escape `s` for inclusion inside a JSON string literal (no surrounding
// quotes).  Matches Python json.dumps(ensure_ascii=False): only `"`, `\` and
// C0 controls are escaped, controls without a shorthand as lowercase \u00xx.
std::string EscapeJsonString(std::string_view s);

} // namespace marc
