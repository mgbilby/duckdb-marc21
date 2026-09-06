//! Key-collision clustering keys (see cluster.hpp for the API contracts).
//! Written from the published description of OpenRefine's fingerprint and
//! ngram-fingerprint keyers: fix whitespace, lowercase, remove punctuation
//! and control characters, normalize extended western characters to their
//! ASCII representation, then split/sort/de-dupe/re-join (fingerprint) or
//! collect sorted unique n-grams of the space-less text (ngram-fingerprint).
//!
//! The character normalization is NacoNormalize (idnorm.cpp): full NFD with
//! combining marks dropped, the non-decomposing Latin specials folded
//! (Æ→AE, Ø→O, ß→SS, Ł→L, ...), punctuation and symbols deleted, whitespace
//! collapsed.  Reusing it keeps one diacritic-folding engine in the code
//! base.  Documented deviations from OpenRefine's exact behaviour:
//!   * NACO turns a comma into a space where OpenRefine deletes punctuation
//!     with no replacement — so "Smith,John" keys as "john smith" here and
//!     "smithjohn" there.  For headings (whose commas separate tokens) the
//!     space is the more useful reading;
//!   * the symbols NACO retains (& ♭ ♯) are dropped afterwards to honour
//!     "remove all punctuation";
//!   * non-Latin letters (Greek, Cyrillic, CJK) pass through without case
//!     folding — NACO's own documented simplification;
//!   * NgramFingerprint returns a too-short cleaned string whole instead of
//!     "" (see cluster.hpp).
#include "marc/cluster.hpp"
#include "marc/idnorm.hpp"

#include <algorithm>
#include <vector>

namespace marc {

namespace {

// Shared normalization: NacoNormalize, then drop its retained symbols and
// lowercase the ASCII uppercase it produced.  Tokens stay space-separated
// (NACO already collapsed and trimmed runs of whitespace).
std::u32string FingerprintBase(std::string_view s) {
	std::u32string out;
	for (char32_t cp : Utf8DecodeLossy(NacoNormalize(s))) {
		if (cp == U'&' || cp == 0x266D || cp == 0x266F) {
			continue;
		}
		if (cp >= U'A' && cp <= U'Z') {
			cp = cp - U'A' + U'a';
		}
		out.push_back(cp);
	}
	// Dropping a retained symbol can leave a doubled/leading/trailing space
	// ("a & b" → "a  b"); re-collapse so tokenization stays clean.
	std::u32string collapsed;
	for (char32_t cp : out) {
		if (cp == U' ' && (collapsed.empty() || collapsed.back() == U' ')) {
			continue;
		}
		collapsed.push_back(cp);
	}
	while (!collapsed.empty() && collapsed.back() == U' ') {
		collapsed.pop_back();
	}
	return collapsed;
}

} // namespace

std::string Fingerprint(std::string_view s) {
	std::vector<std::u32string> tokens;
	std::u32string cur;
	for (char32_t cp : FingerprintBase(s)) {
		if (cp == U' ') {
			if (!cur.empty()) {
				tokens.push_back(std::move(cur));
				cur.clear();
			}
		} else {
			cur.push_back(cp);
		}
	}
	if (!cur.empty()) {
		tokens.push_back(std::move(cur));
	}
	std::sort(tokens.begin(), tokens.end());
	tokens.erase(std::unique(tokens.begin(), tokens.end()), tokens.end());
	std::u32string joined;
	for (auto &t : tokens) {
		if (!joined.empty()) {
			joined.push_back(U' ');
		}
		joined += t;
	}
	return Utf8Encode(joined);
}

std::string NgramFingerprint(std::string_view s, size_t n) {
	if (n == 0) {
		throw MarcError("ngram fingerprint size must be at least 1");
	}
	std::u32string base;
	for (char32_t cp : FingerprintBase(s)) {
		if (cp != U' ') {
			base.push_back(cp);
		}
	}
	if (base.size() < n) {
		return Utf8Encode(base);
	}
	std::vector<std::u32string> grams;
	grams.reserve(base.size() - n + 1);
	for (size_t i = 0; i + n <= base.size(); i++) {
		grams.push_back(base.substr(i, n));
	}
	std::sort(grams.begin(), grams.end());
	grams.erase(std::unique(grams.begin(), grams.end()), grams.end());
	std::u32string joined;
	for (auto &g : grams) {
		joined += g;
	}
	return Utf8Encode(joined);
}

} // namespace marc
