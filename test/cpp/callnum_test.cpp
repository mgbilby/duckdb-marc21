// Standalone tests for the call-number module:
//   g++ -std=c++17 -Wall -O2 -Isrc/include src/core/*.cpp test/cpp/callnum_test.cpp -o callnum_test && ./callnum_test
#include "checks.hpp"

#include "marc/callnum.hpp"

#include <algorithm>
#include <random>
#include <string>
#include <vector>

using namespace marc;

// ---- ParseLcc --------------------------------------------------------------

static void TestParseLcc() {
	LccParts p = ParseLcc("QA76.73.J38 S25 2004");
	CHECK(p.valid);
	CHECK_EQ(p.klass, std::string("QA"));
	CHECK_EQ(p.number, std::string("76"));
	CHECK_EQ(p.decimal, std::string("73"));
	CHECK_EQ(p.cutters.size(), size_t(2));
	CHECK_EQ(p.cutters[0], std::string("J38"));
	CHECK_EQ(p.cutters[1], std::string("S25"));
	CHECK_EQ(p.year, std::string("2004"));
	CHECK(p.rest.empty());

	p = ParseLcc("E184.5 .J5");
	CHECK(p.valid);
	CHECK_EQ(p.klass, std::string("E"));
	CHECK_EQ(p.number, std::string("184"));
	CHECK_EQ(p.decimal, std::string("5"));
	CHECK_EQ(p.cutters.size(), size_t(1));
	CHECK_EQ(p.cutters[0], std::string("J5"));
	CHECK(p.year.empty());

	// Work letter attaches to the year, lowercased.
	p = ParseLcc("QA76 .A1 1990B");
	CHECK(p.valid);
	CHECK_EQ(p.year, std::string("1990b"));

	// Lowercase input normalizes.
	p = ParseLcc("qa76.9 .a25");
	CHECK(p.valid);
	CHECK_EQ(p.klass, std::string("QA"));
	CHECK_EQ(p.decimal, std::string("9"));
	CHECK_EQ(p.cutters[0], std::string("A25"));

	// Whatever follows the year lands in rest verbatim.
	p = ParseLcc("KF4550 .A7 1999 no. 3");
	CHECK(p.valid);
	CHECK_EQ(p.number, std::string("4550"));
	CHECK_EQ(p.year, std::string("1999"));
	CHECK_EQ(p.rest, std::string("no. 3"));

	// A non-year digit run also falls through to rest.
	p = ParseLcc("PZ7.G73 12345");
	CHECK(p.valid);
	CHECK_EQ(p.rest, std::string("12345"));
}

static void TestParseLccInvalid() {
	CHECK(!ParseLcc("").valid);
	CHECK(!ParseLcc("QA").valid);          // no class number
	CHECK(!ParseLcc("76.5").valid);        // no class letters
	CHECK(!ParseLcc("ABCD123").valid);     // four class letters
	CHECK(!ParseLcc("B123456").valid);     // class number over 4 digits
	CHECK(!ParseLcc("hello world").valid); // not a call number
	CHECK_EQ(LccSortKey(""), std::string(""));
	CHECK_EQ(LccSortKey("813.54"), std::string("")); // Dewey is not LCC
	CHECK_EQ(LccSortKey("hello world"), std::string(""));
}

// ---- LccSortKey ordering ---------------------------------------------------

static void TestLccSortKeyTraps() {
	// The classic traps, pairwise.
	CHECK(LccSortKey("QA76.73") < LccSortKey("QA76.9"));
	CHECK(LccSortKey("QA76.9") < LccSortKey("QA279.5"));
	CHECK(LccSortKey("PZ7") < LccSortKey("PZ76"));
	CHECK(LccSortKey("P90") < LccSortKey("PA25"));
	CHECK(LccSortKey("QA76") < LccSortKey("QA76.5"));
	CHECK(LccSortKey("QA1.C4") < LccSortKey("QA1.C45"));
	CHECK(LccSortKey("QA1.C45") < LccSortKey("QA1.C5"));
	CHECK(LccSortKey("QA76 .A1 1990") < LccSortKey("QA76 .A1 1990b"));
	CHECK(LccSortKey("QA76.73.J38 S25 1996") < LccSortKey("QA76.73.J38 S25 2004"));
	// A date right after the class number files before any cutter.
	CHECK(LccSortKey("B72 1988") < LccSortKey("B72 .A5"));
}

static void TestLccShelfOrder() {
	const std::vector<std::string> shelf = {
	    "B72 1988",
	    "BF637.C45 M67 2006",
	    "E184.5 .J5",
	    "PZ7 .A1",
	    "PZ7.G318",
	    "PZ7.G73 1998",
	    "PZ76.3 .B4",
	    "QA1 .C4",
	    "QA1 .C45",
	    "QA1 .C5",
	    "QA76 .A1 1990",
	    "QA76 .A1 1990b",
	    "QA76.5 .H34",
	    "QA76.73.C15 K47 1988",
	    "QA76.73.J38 S25 1996",
	    "QA76.73.J38 S25 2004",
	    "QA76.9.A25 S54",
	    "QA279.5 .K78",
	    "Z699 .A1",
	};
	std::vector<std::string> shuffled = shelf;
	std::mt19937 rng(42);
	std::shuffle(shuffled.begin(), shuffled.end(), rng);
	std::sort(shuffled.begin(), shuffled.end(),
	          [](const std::string &a, const std::string &b) { return LccSortKey(a) < LccSortKey(b); });
	CHECK(shuffled == shelf);
	// Keys are non-empty and strictly increasing over the shelf list.
	for (size_t i = 0; i < shelf.size(); i++) {
		CHECK(!LccSortKey(shelf[i]).empty());
		if (i > 0) {
			CHECK(LccSortKey(shelf[i - 1]) < LccSortKey(shelf[i]));
		}
	}
}

// ---- DdcSortKey ------------------------------------------------------------

static void TestDdcSortKey() {
	CHECK_EQ(DdcSortKey("5"), std::string("005"));
	CHECK_EQ(DdcSortKey("813.54"), std::string("813.54"));
	CHECK_EQ(DdcSortKey("j398.2"), std::string("398.2"));    // audience prefix stripped
	CHECK_EQ(DdcSortKey("R 641.5"), std::string("641.5"));   // collection prefix stripped
	CHECK_EQ(DdcSortKey("813.54  F553w"), std::string("813.54 F553W"));
	CHECK_EQ(DdcSortKey("Fic"), std::string(""));  // no class number
	CHECK_EQ(DdcSortKey("1234"), std::string("")); // integer part over 3 digits
	CHECK_EQ(DdcSortKey(""), std::string(""));

	const std::vector<std::string> order = {
	    "004", "005.1", "005.133", "51", "398.2", "813 F553", "813.5", "813.54 F553", "813.54 G12", "813.6",
	};
	std::vector<std::string> shuffled = order;
	std::mt19937 rng(7);
	std::shuffle(shuffled.begin(), shuffled.end(), rng);
	std::sort(shuffled.begin(), shuffled.end(),
	          [](const std::string &a, const std::string &b) { return DdcSortKey(a) < DdcSortKey(b); });
	CHECK(shuffled == order);
}

// ---- CutterValid -----------------------------------------------------------

static void TestCutterValid() {
	CHECK(CutterValid(".C45"));
	CHECK(CutterValid("C4"));
	CHECK(CutterValid("Kf4")); // double-letter cutter
	CHECK(CutterValid(".Zw55"));
	CHECK(!CutterValid(""));
	CHECK(!CutterValid("C"));      // no digits
	CHECK(!CutterValid("45"));     // no letters
	CHECK(!CutterValid(".C45x"));  // trailing work letter
	CHECK(!CutterValid("ABC4"));   // three letters
	CHECK(!CutterValid(".C4 5"));  // embedded space
	CHECK(!CutterValid("..C45"));  // double dot
}

int main() {
	TestParseLcc();
	TestParseLccInvalid();
	TestLccSortKeyTraps();
	TestLccShelfOrder();
	TestDdcSortKey();
	TestCutterValid();
	return CHECKS_MAIN_RESULT();
}
