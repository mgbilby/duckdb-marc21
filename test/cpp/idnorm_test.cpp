// Standalone tests for identifier and heading normalization:
//   g++ -std=c++17 -Wall -O2 -Isrc/include src/core/*.cpp test/cpp/idnorm_test.cpp -o idnorm_test && ./idnorm_test
#include "checks.hpp"

#include "marc/idnorm.hpp"

using namespace marc;

static void TestIsbn() {
	// ISBN-10 → 978 prefix with a recomputed EAN check digit.
	CHECK_EQ(NormalizeIsbn("0-306-40615-2"), std::string("9780306406157"));
	CHECK_EQ(NormalizeIsbn("0306406152"), std::string("9780306406157"));
	CHECK_EQ(NormalizeIsbn("043942089X"), std::string("9780439420891")); // X check digit
	CHECK_EQ(NormalizeIsbn("0-19-853453-1 (pbk.)"), std::string("9780198534532"));
	CHECK_EQ(NormalizeIsbn("ISBN 0 306 40615 2"), std::string("9780306406157"));
	CHECK_EQ(NormalizeIsbn("isbn-10: 0306406152"), std::string("9780306406157"));

	// ISBN-13 passes through unchanged once validated.
	CHECK_EQ(NormalizeIsbn("978-0-306-40615-7"), std::string("9780306406157"));
	CHECK_EQ(NormalizeIsbn("ISBN-13: 978 0 439 42089 1 (v. 1)"), std::string("9780439420891"));

	// Invalid checksums, X in the wrong place, wrong lengths.
	CHECK_EQ(NormalizeIsbn("0306406153"), std::string(""));
	CHECK_EQ(NormalizeIsbn("030640615X"), std::string(""));
	CHECK_EQ(NormalizeIsbn("9780306406150"), std::string(""));
	CHECK_EQ(NormalizeIsbn("978030640615X"), std::string(""));
	CHECK_EQ(NormalizeIsbn("12345"), std::string(""));
	CHECK_EQ(NormalizeIsbn(""), std::string(""));
	CHECK_EQ(NormalizeIsbn("no isbn here"), std::string(""));

	CHECK(IsbnIsValid("0306406152"));
	CHECK(IsbnIsValid("9780306406157"));
	CHECK(!IsbnIsValid("0306406153"));
	CHECK(!IsbnIsValid(""));
}

static void TestIssn() {
	CHECK_EQ(NormalizeIssn("0317-8471"), std::string("0317-8471"));
	CHECK_EQ(NormalizeIssn("03178471"), std::string("0317-8471"));
	CHECK_EQ(NormalizeIssn("2434561x"), std::string("2434-561X")); // X uppercased
	CHECK_EQ(NormalizeIssn("ISSN 0317-8471"), std::string("0317-8471"));
	CHECK_EQ(NormalizeIssn("ISSN: 2434-561X"), std::string("2434-561X"));

	CHECK_EQ(NormalizeIssn("0317-8472"), std::string("")); // bad check digit
	CHECK_EQ(NormalizeIssn("0317-847"), std::string(""));
	CHECK_EQ(NormalizeIssn("0317-847X1"), std::string(""));
	CHECK_EQ(NormalizeIssn("X3178471"), std::string("")); // X only allowed last
	CHECK_EQ(NormalizeIssn(""), std::string(""));
}

static void TestLccn() {
	CHECK_EQ(NormalizeLccn("n 78-890351"), std::string("n78890351"));
	CHECK_EQ(NormalizeLccn("  85000002 "), std::string("85000002"));
	CHECK_EQ(NormalizeLccn("85-2"), std::string("85000002")); // serial zero-padded to 6
	CHECK_EQ(NormalizeLccn("2001-000002"), std::string("2001000002"));
	CHECK_EQ(NormalizeLccn("n78-89035"), std::string("n78089035"));
	CHECK_EQ(NormalizeLccn("75-425165//r75"), std::string("75425165")); // '/' truncates
	CHECK_EQ(NormalizeLccn(" 79139101 /AC/r932"), std::string("79139101"));
	CHECK_EQ(NormalizeLccn("N78-890351"), std::string("n78890351")); // lowercased

	CHECK_EQ(NormalizeLccn("n78.89035"), std::string("")); // stray punctuation
	CHECK_EQ(NormalizeLccn("//r75"), std::string(""));
	CHECK_EQ(NormalizeLccn(""), std::string(""));
}

static void TestOclc() {
	CHECK_EQ(NormalizeOclc("(OCoLC)ocm00012345"), std::string("12345"));
	CHECK_EQ(NormalizeOclc("(OCoLC)00012345"), std::string("12345"));
	CHECK_EQ(NormalizeOclc("ocn123456789"), std::string("123456789"));
	CHECK_EQ(NormalizeOclc("on9990001234"), std::string("9990001234"));
	CHECK_EQ(NormalizeOclc("ocm4434412"), std::string("4434412"));
	CHECK_EQ(NormalizeOclc("  12345  "), std::string("12345"));
	CHECK_EQ(NormalizeOclc("(ocolc)ON0055"), std::string("55"));

	CHECK_EQ(NormalizeOclc("0"), std::string(""));
	CHECK_EQ(NormalizeOclc("(OCoLC)ocm12345abc"), std::string(""));
	CHECK_EQ(NormalizeOclc("DLC12345"), std::string(""));
	CHECK_EQ(NormalizeOclc(""), std::string(""));
}

static void TestNaco() {
	CHECK_EQ(NacoNormalize("Séguin, Marc"), std::string("SEGUIN MARC"));      // é, comma → space
	CHECK_EQ(NacoNormalize("Dvořák, Antonín"), std::string("DVORAK ANTONIN"));
	CHECK_EQ(NacoNormalize("O'Brien"), std::string("OBRIEN"));                     // apostrophe deleted
	CHECK_EQ(NacoNormalize("Smith-Jones"), std::string("SMITHJONES"));             // hyphen deleted
	CHECK_EQ(NacoNormalize("  multiple   spaces  "), std::string("MULTIPLE SPACES"));
	CHECK_EQ(NacoNormalize("Æthelred"), std::string("AETHELRED"));            // Æ → AE
	CHECK_EQ(NacoNormalize("Łódź"), std::string("LODZ"));           // Ł ó ź
	CHECK_EQ(NacoNormalize("Straße"), std::string("STRASSE"));                // ß → SS
	CHECK_EQ(NacoNormalize("C++ & #1"), std::string("C & 1"));                     // & retained
	CHECK_EQ(NacoNormalize("ʻAbd al-Raḥmān"), std::string("ABD ALRAHMAN"));
	CHECK_EQ(NacoNormalize("Brontë sisters..."), std::string("BRONTE SISTERS"));
	CHECK_EQ(NacoNormalize("music ♯ and ♭"), std::string("MUSIC ♯ AND ♭"));
	CHECK_EQ(NacoNormalize("\"quoted\" (parens)"), std::string("QUOTED PARENS"));
	CHECK_EQ(NacoNormalize("no. 5, op. 12"), std::string("NO 5 OP 12"));
	CHECK_EQ(NacoNormalize(""), std::string(""));
	CHECK_EQ(NacoNormalize(", ,"), std::string(""));

	// Precomposed and decomposed inputs produce the same key.
	CHECK_EQ(NacoNormalize("Séguin"), NacoNormalize("Séguin"));
}

static Field DataField(const std::string &tag, std::vector<Subfield> subs) {
	Field f;
	f.tag = tag;
	f.subfields = std::move(subs);
	return f;
}

static void TestMatchKey() {
	Record rec;
	rec.leader = "00000nam a2200000 a 4500";
	rec.fields.push_back(DataField("020", {{"a", "invalid"}}));
	rec.fields.push_back(DataField("020", {{"a", "0-306-40615-2 (pbk.)"}}));
	rec.fields.push_back(DataField("245", {{"a", "The great cookbook :"}, {"b", "recipes & lore."}, {"c", "by A."}}));
	rec.fields.push_back(DataField("264", {{"c", "c2001."}}));
	CHECK_EQ(MatchKey(rec), std::string("THE GREAT COOKBOOK RECIPES & LORE|9780306406157|2001"));

	// 260$c works as the date source too; first valid ISBN wins.
	Record r260;
	r260.leader = rec.leader;
	r260.fields.push_back(DataField("245", {{"a", "Title"}}));
	r260.fields.push_back(DataField("260", {{"c", "[1987?]"}}));
	CHECK_EQ(MatchKey(r260), std::string("TITLE||1987"));

	// Title part truncates to 40 code points.
	Record longt;
	longt.leader = rec.leader;
	longt.fields.push_back(
	    DataField("245", {{"a", "abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij"}}));
	std::string key = MatchKey(longt);
	CHECK_EQ(key, std::string("ABCDEFGHIJ ABCDEFGHIJ ABCDEFGHIJ ABCDEFG||"));

	Record empty;
	CHECK_EQ(MatchKey(empty), std::string(""));

	// A control-ish record with no 245/020/26X still yields "".
	Record ctrl;
	ctrl.leader = rec.leader;
	Field f001;
	f001.tag = "001";
	f001.is_control = true;
	f001.control_value = "x1";
	ctrl.fields.push_back(f001);
	CHECK_EQ(MatchKey(ctrl), std::string(""));
}

int main() {
	TestIsbn();
	TestIssn();
	TestLccn();
	TestOclc();
	TestNaco();
	TestMatchKey();
	return CHECKS_MAIN_RESULT();
}
