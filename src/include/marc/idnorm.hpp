//! Identifier and heading normalization for matching and deduplication.
//! Deliberately DuckDB-free like core.hpp; every function is pure and every
//! string is UTF-8.  Invalid identifiers normalize to "" rather than
//! throwing — bad data is a per-row condition, not a query error.
#pragma once

#include "marc/core.hpp"

namespace marc {

// ---- idnorm.cpp ------------------------------------------------------------

// ISBN → canonical 13-digit form.  Strips an "ISBN"/"ISBN-10"/"ISBN-13"
// label, hyphens and spaces, and anything from the first other character on
// (trailing qualifiers like "(pbk.)").  Validates the check digit; a valid
// ISBN-10 is converted to 978-prefixed ISBN-13 with a recomputed check
// digit.  Returns "" when invalid.
std::string NormalizeIsbn(std::string_view s);
bool IsbnIsValid(std::string_view s);

// ISSN → "9999-999X" form with the check digit validated; "" when invalid.
std::string NormalizeIssn(std::string_view s);

// LC's published LCCN normalization: trim and remove all blanks, drop a '/'
// and everything after it, and at the first '-' zero-pad the serial to six
// digits and drop the hyphen ("n 78-890351" → "n78890351").  Letters are
// lowercased.  Light validation only: a result that is empty or contains a
// character outside [a-z0-9] yields "".
std::string NormalizeLccn(std::string_view s);

// OCLC number → bare digits: strips an "(OCoLC)" label, an ocm/ocn/on
// prefix, and leading zeros.  "" when what remains is empty or not all
// digits.
std::string NormalizeOclc(std::string_view s);

// NACO-style comparison form for headings, implemented from the published
// Authority File Comparison Rule's description.  Built for deterministic
// match keys, not exhaustive fidelity; the exact subset is documented at
// the top of idnorm.cpp (commas → space is the famous special case).
std::string NacoNormalize(std::string_view s);

// Practical dedupe key — OUR recipe, not a copied one:
//   NacoNormalize(245 $a and $b joined, first 40 code points)
//   + "|" + first valid NormalizeIsbn among 020$a
//   + "|" + first run of four digits in the first 260/264 $c.
// Missing parts are empty; "" when all three are.  See idnorm.cpp.
std::string MatchKey(const Record &rec);

} // namespace marc
