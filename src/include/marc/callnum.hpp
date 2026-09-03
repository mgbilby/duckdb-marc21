//! Call-number parsing and collation keys: LC Classification, Dewey
//! Decimal, and Cutter numbers.  Deliberately DuckDB-free and Record-free —
//! plain string functions the orchestrator binds to SQL scalars later.
//! Implemented from the published structure of LC call numbers and Cutter
//! tables; no external MARC tooling code consulted.  Invalid input yields
//! an empty key / valid=false rather than throwing — bad data is a per-row
//! condition, not a query error.
#pragma once

#include <string>
#include <string_view>
#include <vector>

namespace marc {

// ---- callnum.cpp -----------------------------------------------------------

// A parsed LC call number, e.g. "QA76.73.J38 S25 2004":
//   klass "QA", number "76", decimal "73", cutters {"J38","S25"},
//   year "2004", rest "".
// Grammar (documented in callnum.cpp): 1-3 class letters (uppercased), a
// 1-4 digit class number, an optional decimal, then any mix of cutters
// (one letter + digits, '.' and spaces optional) until an optional year
// (exactly four digits, optional single work letter, e.g. "1990b"); once a
// year is seen — or a token fits neither shape — the remainder lands in
// `rest` verbatim.  valid=false (all parts empty) when the class letters
// or class number are missing or malformed.
struct LccParts {
	std::string klass;
	std::string number;
	std::string decimal;
	std::vector<std::string> cutters;
	std::string year;
	std::string rest;
	bool valid;
};

LccParts ParseLcc(std::string_view s);

// Collation-safe key: plain lexicographic ORDER BY of keys equals correct
// LC shelf order.  Layout (documented in callnum.cpp):
//   class letters space-padded to 3, integer part zero-padded to 4, '.' +
//   decimal digits (positional), then ' ' + each cutter (letter + digits,
//   compared positionally), ' ' + year, ' ' + rest.
// Invalid call numbers key to "".
std::string LccSortKey(std::string_view s);

// Dewey collation key: "813.54 F553w" → "813.54 F553W".  A leading run of
// letters (audience/collection prefixes like 'j' or 'R', with any following
// '.'/spaces) is stripped — the prefix does not affect class order.  The
// integer part must be 1-3 digits (zero-padded to 3); decimals stay
// positional after '.'; any remaining item/cutter text is appended
// uppercased with whitespace collapsed.  Anything else (no digits, integer
// part over 3 digits) keys to "".
std::string DdcSortKey(std::string_view s);

// Cutter shape check: optional leading '.', one or two ASCII letters, then
// one or more digits, nothing after (work letters are not part of the
// cutter proper).  ".C45", "C4" and "Kf4" pass; "C", "45", ".C45x" fail.
bool CutterValid(std::string_view s);

} // namespace marc
