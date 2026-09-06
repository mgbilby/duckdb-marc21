// Standalone tests for the targeted $0/$1 write-back module:
//   g++ -std=c++17 -Wall -O2 -Isrc/include src/core/*.cpp test/cpp/authlink_test.cpp -o authlink_test && ./authlink_test
#include "checks.hpp"

#include "marc/authlink.hpp"

#include <string>

using namespace marc;

static Field CF(const std::string &tag, const std::string &value) {
	Field f;
	f.tag = tag;
	f.is_control = true;
	f.control_value = value;
	return f;
}

static Field DF(const std::string &tag, const std::string &ind1, const std::string &ind2,
                std::vector<Subfield> subs) {
	Field f;
	f.tag = tag;
	f.ind1 = ind1;
	f.ind2 = ind2;
	f.subfields = std::move(subs);
	return f;
}

static Record Rec(std::vector<Field> fields) {
	Record r;
	r.leader = "00000nam a2200000 a 4500";
	r.fields = std::move(fields);
	return r;
}

static const char *URI = "http://id.loc.gov/authorities/names/n79021164";

// ---- SetLinkedUri ----------------------------------------------------------

static void TestSetExactMatch() {
	Record r = Rec({
	    CF("001", "cn1"),
	    DF("100", "1", " ", {{"a", "Twain, Mark,"}, {"d", "1835-1910."}}),
	    DF("650", " ", "0", {{"a", "Cooking."}}),
	});
	Record out = SetLinkedUri(r, "100", "Twain, Mark, 1835-1910", URI, '0');
	CHECK_EQ(out.fields[1].subfields.size(), size_t(3));
	CHECK_EQ(out.fields[1].subfields[2].code, std::string("0"));
	CHECK_EQ(out.fields[1].subfields[2].value, std::string(URI));
	// Other fields untouched; input untouched.
	CHECK_EQ(out.fields[2].subfields.size(), size_t(1));
	CHECK_EQ(r.fields[1].subfields.size(), size_t(2));
}

static void TestNacoEquivalence() {
	// Diacritics, case, commas and terminal punctuation are all folded by
	// the NACO comparison, so a plain-ASCII candidate label matches the
	// diacritic-bearing field (and vice versa).
	Record r = Rec({
	    DF("100", "1", " ", {{"a", "G\xC3\xB6" "del, Kurt."}}), // Gödel
	});
	Record out = SetLinkedUri(r, "100", "godel kurt", URI, '0');
	CHECK_EQ(out.fields[0].subfields.size(), size_t(2));
	CHECK_EQ(out.fields[0].subfields[1].code, std::string("0"));

	// Multi-subfield heading joins with spaces before comparison.
	Record r2 = Rec({
	    DF("600", "1", "0", {{"a", "\xC5\x81" "ukasiewicz, Jan,"}, {"d", "1878-1956"}}), // Łukasiewicz
	});
	out = SetLinkedUri(r2, "600", "Lukasiewicz, Jan, 1878-1956", URI, '0');
	CHECK_EQ(out.fields[0].subfields.size(), size_t(3));
	CHECK_EQ(out.fields[0].subfields[2].value, std::string(URI));
}

static void TestHeadingJoinExclusions() {
	// $w, $0-$9 never contribute to the heading; an existing $0 therefore
	// does not block the match, and gets replaced IN PLACE (position kept).
	Record r = Rec({
	    DF("650", " ", "0",
	       {{"a", "Cooking"}, {"0", "http://old.example/1"}, {"2", "fast"}}),
	});
	Record out = SetLinkedUri(r, "650", "Cooking", URI, '0');
	CHECK_EQ(out.fields[0].subfields.size(), size_t(3));
	CHECK_EQ(out.fields[0].subfields[1].code, std::string("0"));
	CHECK_EQ(out.fields[0].subfields[1].value, std::string(URI));
	CHECK_EQ(out.fields[0].subfields[2].code, std::string("2")); // order kept

	// Duplicate old links collapse to the one replacement.
	Record dup = Rec({
	    DF("650", " ", "0",
	       {{"a", "Cooking"}, {"0", "http://old.example/1"}, {"0", "http://old.example/2"}}),
	});
	out = SetLinkedUri(dup, "650", "Cooking", URI, '0');
	CHECK_EQ(out.fields[0].subfields.size(), size_t(2));
	CHECK_EQ(out.fields[0].subfields[1].value, std::string(URI));

	// A $w tracing control does not change the heading ("X" is still "X").
	Record traced = Rec({
	    DF("400", "1", " ", {{"w", "nne"}, {"a", "Clemens, Samuel"}}),
	});
	out = SetLinkedUri(traced, "400", "Clemens, Samuel", URI, '0');
	CHECK_EQ(out.fields[0].subfields.size(), size_t(3));
	CHECK_EQ(out.fields[0].subfields[2].code, std::string("0"));
}

static void TestMultipleOccurrencesAndTagpat() {
	// Every matching occurrence is linked; a same-tag field with a different
	// heading is not; the '.' wildcard spans 1XX/6XX/7XX-style groups.
	Record r = Rec({
	    DF("650", " ", "0", {{"a", "Cooking."}}),
	    DF("650", " ", "0", {{"a", "Baking."}}),
	    DF("650", " ", "0", {{"a", "Cooking"}}),
	    DF("700", "1", " ", {{"a", "Cooking."}}), // different tag family
	});
	Record out = SetLinkedUri(r, "6..", "Cooking", URI, '0');
	CHECK_EQ(out.fields[0].subfields.size(), size_t(2));
	CHECK_EQ(out.fields[1].subfields.size(), size_t(1)); // Baking untouched
	CHECK_EQ(out.fields[2].subfields.size(), size_t(2));
	CHECK_EQ(out.fields[3].subfields.size(), size_t(1)); // 700 outside 6..
}

static void TestCode1AndNoMatch() {
	Record r = Rec({
	    CF("008", "970101s1997    nyu           000 0 eng d"),
	    DF("100", "1", " ", {{"a", "Twain, Mark"}}),
	});
	// $1 (real-world object) goes to the same canonical spot.
	Record out = SetLinkedUri(r, "100", "Twain, Mark", "http://www.wikidata.org/entity/Q7245", '1');
	CHECK_EQ(out.fields[1].subfields.size(), size_t(2));
	CHECK_EQ(out.fields[1].subfields[1].code, std::string("1"));

	// No heading match: byte-for-byte no-op.
	out = SetLinkedUri(r, "100", "Dickens, Charles", URI, '0');
	CHECK_EQ(out.fields[1].subfields.size(), size_t(1));

	// No tag match: no-op, and control fields never match a wildcard.
	out = SetLinkedUri(r, "0..", "Twain, Mark", URI, '0');
	CHECK_EQ(out.fields[0].control_value, r.fields[0].control_value);
	CHECK_EQ(out.fields[1].subfields.size(), size_t(1));

	// An all-punctuation heading (empty NACO form) links nothing.
	Record punct = Rec({DF("650", " ", "0", {{"a", "..."}})});
	out = SetLinkedUri(punct, "650", "***", URI, '0');
	CHECK_EQ(out.fields[0].subfields.size(), size_t(1));
}

static void TestSetErrors() {
	Record r = Rec({DF("100", "1", " ", {{"a", "X"}})});
	bool threw = false;
	try {
		SetLinkedUri(r, "65", "X", URI, '0');
	} catch (const MarcError &) {
		threw = true;
	}
	CHECK(threw);

	threw = false;
	try {
		SetLinkedUri(r, "100", "X", URI, '2');
	} catch (const MarcError &e) {
		threw = true;
		CHECK(std::string(e.what()).find("'0' or '1'") != std::string::npos);
	}
	CHECK(threw);
}

// ---- ClearLinkedUris -------------------------------------------------------

static void TestClear() {
	Record r = Rec({
	    DF("100", "1", " ", {{"a", "Twain, Mark"}, {"0", URI}, {"1", "http://w.example/q"}}),
	    DF("650", " ", "0", {{"a", "Cooking"}, {"0", "http://id.example/1"}}),
	    DF("650", " ", "0", {{"a", "Baking"}, {"0", "http://id.example/2"}, {"0", "http://id.example/3"}}),
	});
	// Clear $0 on 6.. only: both 650 links go (duplicates included), the
	// 100's $0 and everyone's $1 stay.
	Record out = ClearLinkedUris(r, "6..", '0');
	CHECK_EQ(out.fields[0].subfields.size(), size_t(3));
	CHECK_EQ(out.fields[1].subfields.size(), size_t(1));
	CHECK_EQ(out.fields[2].subfields.size(), size_t(1));

	// Clear $1 everywhere.
	out = ClearLinkedUris(out, "...", '1');
	CHECK_EQ(out.fields[0].subfields.size(), size_t(2));
	CHECK_EQ(out.fields[0].subfields[1].code, std::string("0"));

	// Input untouched throughout.
	CHECK_EQ(r.fields[0].subfields.size(), size_t(3));

	bool threw = false;
	try {
		ClearLinkedUris(r, "6..", 'w');
	} catch (const MarcError &) {
		threw = true;
	}
	CHECK(threw);
}

static void TestRoundTripThroughSetAndClear() {
	// set → clear → set is stable and idempotent per occurrence.
	Record r = Rec({DF("650", " ", "0", {{"a", "Cooking"}}), DF("650", " ", "0", {{"a", "Cooking"}})});
	Record linked = SetLinkedUri(r, "650", "Cooking", URI, '0');
	Record relinked = SetLinkedUri(linked, "650", "Cooking", URI, '0');
	CHECK_EQ(relinked.fields[0].subfields.size(), size_t(2));
	CHECK_EQ(relinked.fields[1].subfields.size(), size_t(2));
	Record cleared = ClearLinkedUris(relinked, "650", '0');
	CHECK_EQ(cleared.fields[0].subfields.size(), size_t(1));
	CHECK_EQ(cleared.fields[1].subfields.size(), size_t(1));
}

int main() {
	TestSetExactMatch();
	TestNacoEquivalence();
	TestHeadingJoinExclusions();
	TestMultipleOccurrencesAndTagpat();
	TestCode1AndNoMatch();
	TestSetErrors();
	TestClear();
	TestRoundTripThroughSetAndClear();
	return CHECKS_MAIN_RESULT();
}
