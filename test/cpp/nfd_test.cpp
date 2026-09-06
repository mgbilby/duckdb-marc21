// Standalone tests for NfdNormalize / NfdNormalizeUtf8 (no DuckDB build):
//   g++ -std=c++17 -Wall -O2 -Isrc/include src/core/*.cpp test/cpp/nfd_test.cpp -o nfd_test
//   ./nfd_test
// All non-ASCII is written as \u escapes so no editor or transfer can
// re-normalise the expectations out from under the test.
#include "checks.hpp"
#include "marc/unicode_nfc.hpp"

using namespace marc;

int main() {
	// ---- Latin: composed to decomposed --------------------------------------
	// U+00E9 (e-acute) -> U+0065 U+0301
	CHECK_EQ(NfdNormalize(U"\u00E9"), std::u32string(U"e\u0301"));
	// Already-decomposed input is unchanged (idempotence).
	CHECK_EQ(NfdNormalize(U"e\u0301"), std::u32string(U"e\u0301"));
	// UTF-8 surface: 0xC3 0xA9 -> "e" + 0xCC 0x81.
	CHECK_EQ(NfdNormalizeUtf8("\xC3\xA9"), std::string("e\xCC\x81"));
	// Multi-mark: U+1EC7 (e-circumflex-dot-below) fully decomposes with
	// dot-below U+0323 (ccc 220) ordered before circumflex U+0302 (ccc 230).
	CHECK_EQ(NfdNormalize(U"\u1EC7"), std::u32string(U"e\u0323\u0302"));

	// ---- Horn (U+031B, ccc 216) and canonical ordering ----------------------
	// U+01A0 (O-horn) -> O + horn.
	CHECK_EQ(NfdNormalize(U"\u01A0"), std::u32string(U"O\u031B"));
	// U+1EDB (o-horn-acute) -> o + horn + acute U+0301 (216 before 230).
	CHECK_EQ(NfdNormalize(U"\u1EDB"), std::u32string(U"o\u031B\u0301"));
	// The same marks fed acute-first are reordered, not composed.
	CHECK_EQ(NfdNormalize(U"o\u0301\u031B"), std::u32string(U"o\u031B\u0301"));
	// Composed o-acute U+00F3 plus a following combining horn: decompose,
	// then order the horn before the acute.
	CHECK_EQ(NfdNormalize(U"\u00F3\u031B"), std::u32string(U"o\u031B\u0301"));

	// ---- Hangul: algorithmic syllable decomposition -------------------------
	// U+AC00 (GA) -> L U+1100 + V U+1161 (no trailing consonant).
	CHECK_EQ(NfdNormalize(U"\uAC00"), std::u32string(U"\u1100\u1161"));
	// U+D55C (HAN) -> U+1112 U+1161 U+11AB (LVT).
	CHECK_EQ(NfdNormalize(U"\uD55C"), std::u32string(U"\u1112\u1161\u11AB"));
	// Round trip through NFC restores the syllable.
	CHECK_EQ(NfcNormalize(NfdNormalize(U"\uD55C")), std::u32string(U"\uD55C"));

	// ---- ASCII passes through; NFD is a no-op on it -------------------------
	CHECK_EQ(NfdNormalizeUtf8("Whale watching, 1989."), std::string("Whale watching, 1989."));

	// ---- NFC(NFD(x)) == NFC(x) on a mixed string; NFD idempotent ------------
	{
		std::u32string mixed = U"Caf\u00E9 \uD55C\uAD6D \u1EDDi";
		CHECK_EQ(NfcNormalize(NfdNormalize(mixed)), NfcNormalize(mixed));
		CHECK_EQ(NfdNormalize(NfdNormalize(mixed)), NfdNormalize(mixed));
	}

	// ---- invalid UTF-8 is lossy-decoded to U+FFFD, like the NFC surface -----
	CHECK_EQ(NfdNormalizeUtf8("a\xFFz"), std::string("a\xEF\xBF\xBDz"));

	// ---- singleton decomposition: U+212B ANGSTROM SIGN -> A + ring U+030A ---
	CHECK_EQ(NfdNormalize(U"\u212B"), std::u32string(U"A\u030A"));

	return CHECKS_MAIN_RESULT();
}
