// Standalone tests for the key-collision clustering keys:
//   g++ -std=c++17 -Wall -O2 -Isrc/include src/core/*.cpp test/cpp/cluster_test.cpp -o cluster_test && ./cluster_test
#include "checks.hpp"

#include "marc/cluster.hpp"

using namespace marc;

template <class F>
static bool ThrowsMarc(F fn) {
	try {
		fn();
	} catch (const MarcError &) {
		return true;
	}
	return false;
}

static void TestFingerprint() {
	// Trim, lowercase, punctuation stripped, tokens sorted and de-duped.
	CHECK_EQ(Fingerprint("  Tom Cruise  "), std::string("cruise tom"));
	CHECK_EQ(Fingerprint("Cruise, Tom"), std::string("cruise tom"));
	CHECK_EQ(Fingerprint("CRUISE tom!!"), std::string("cruise tom"));
	CHECK_EQ(Fingerprint("Tom tom Cruise"), std::string("cruise tom"));

	// The point of the keyer: variant headings collide on one key.
	CHECK_EQ(Fingerprint("Paris, France"), Fingerprint("France - Paris"));
	CHECK(Fingerprint("Paris, Texas") != Fingerprint("Paris, France"));

	// Diacritics fold to ASCII via the NACO engine; the specials fold too.
	CHECK_EQ(Fingerprint("Gödel, Escher, Bach"), std::string("bach escher godel"));
	CHECK_EQ(Fingerprint("Łódź"), std::string("lodz"));
	CHECK_EQ(Fingerprint("Ærø"), std::string("aero"));
	CHECK_EQ(Fingerprint("straße"), std::string("strasse"));
	CHECK_EQ(Fingerprint("café"), Fingerprint("cafe"));

	// The symbols NACO retains (& ♭ ♯) are punctuation here and drop, and
	// the space they leave behind does not create empty tokens.
	CHECK_EQ(Fingerprint("Trains & Boats & Planes"), std::string("boats planes trains"));
	CHECK_EQ(Fingerprint("B♭ minor"), std::string("b minor"));

	// Digits survive; unknown scripts pass through uncased.
	CHECK_EQ(Fingerprint("Route 66"), std::string("66 route"));
	CHECK_EQ(Fingerprint("日本の歴史"), std::string("日本の歴史"));

	// Degenerate inputs.
	CHECK_EQ(Fingerprint(""), std::string(""));
	CHECK_EQ(Fingerprint("!!! ... ---"), std::string(""));
	CHECK_EQ(Fingerprint("   a   "), std::string("a"));
}

static void TestNgramFingerprint() {
	// Whitespace removed entirely, sorted unique n-grams concatenated:
	// "tomcruise" bigrams sort to cr is mc om ru se to ui.
	CHECK_EQ(NgramFingerprint("Tom Cruise", 2), std::string("crismcomrusetoui"));
	// Case and punctuation do not matter; word ORDER does (the grams span
	// the joined string, so "cruisetom" brings an et gram "tomcruise" lacks).
	CHECK_EQ(NgramFingerprint("TOM-cruise!", 2), NgramFingerprint("Tom Cruise", 2));
	CHECK(NgramFingerprint("Cruise, Tom", 2) != NgramFingerprint("Tom Cruise", 2));
	// Repeated n-grams collapse: "banana" → an ba na.
	CHECK_EQ(NgramFingerprint("banana", 2), std::string("anbana"));

	// 1-grams are the sorted unique characters.
	CHECK_EQ(NgramFingerprint("banana", 1), std::string("abn"));

	// Diacritic folding happens before gramming.
	CHECK_EQ(NgramFingerprint("Gödel", 2), NgramFingerprint("Godel", 2));

	// A cleaned string shorter than n comes back whole (documented deviation
	// from OpenRefine, which would return "" and collide all short values).
	CHECK_EQ(NgramFingerprint("ab", 3), std::string("ab"));
	CHECK_EQ(NgramFingerprint("a b!", 3), std::string("ab"));
	CHECK_EQ(NgramFingerprint("abc", 3), std::string("abc"));
	CHECK_EQ(NgramFingerprint("", 2), std::string(""));
	CHECK_EQ(NgramFingerprint("...", 2), std::string(""));

	CHECK(ThrowsMarc([&] { NgramFingerprint("abc", 0); }));
}

int main() {
	TestFingerprint();
	TestNgramFingerprint();
	return CHECKS_MAIN_RESULT();
}
