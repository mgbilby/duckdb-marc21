// Standalone tests for the MicroLIF reader (no DuckDB build needed):
//   g++ -std=c++17 -Wall -O2 -Isrc/include src/core/*.cpp test/cpp/microlif_test.cpp -o microlif_test
//   ./microlif_test      (run from the repo root; reads test/data/sample.lif)
#include "checks.hpp"
#include "marc/formats.hpp"

#include <fstream>
#include <sstream>

using namespace marc;

static std::string ReadFile(const std::string &path) {
	std::ifstream in(path, std::ios::binary);
	std::ostringstream ss;
	ss << in.rdbuf();
	return ss.str();
}

int main() {
	// ---- header variant: LDR line, control field, data fields ---------------
	{
		auto recs = ParseMicroLif("LDR00000nam  2200000 a 4500\n"
		                          "0011234\n"
		                          "008890201s1989    xxu           000 0 eng d\n"
		                          "020  _a0716717972\n"
		                          "1001 _aBerger, Melvin.\n"
		                          "24514_aThe whale watchers' guide /_cby Melvin Berger.`\n");
		CHECK_EQ(recs.size(), size_t(1));
		const Record &r = recs[0];
		CHECK_EQ(r.leader.size(), size_t(24));
		CHECK_EQ(r.leader.substr(0, 12), "00000nam  22");
		CHECK_EQ(r.fields.size(), size_t(5));
		CHECK(r.fields[0].is_control);
		CHECK_EQ(r.fields[0].control_value, "1234");
		CHECK_EQ(r.fields[1].tag, "008");
		CHECK_EQ(r.fields[1].control_value.substr(0, 6), "890201");
		CHECK_EQ(r.fields[2].tag, "020");
		CHECK_EQ(r.fields[2].ind1, " ");
		CHECK_EQ(r.fields[2].ind2, " ");
		CHECK_EQ(r.fields[2].subfields.size(), size_t(1));
		CHECK_EQ(r.fields[2].subfields[0].code, "a");
		CHECK_EQ(r.fields[2].subfields[0].value, "0716717972");
		CHECK_EQ(r.fields[3].ind1, "1");
		CHECK_EQ(r.fields[3].ind2, " ");
		CHECK_EQ(r.fields[4].tag, "245");
		CHECK_EQ(r.fields[4].ind1, "1");
		CHECK_EQ(r.fields[4].ind2, "4");
		CHECK_EQ(r.fields[4].subfields.size(), size_t(2));
		CHECK_EQ(r.fields[4].subfields[0].code, "a");
		CHECK_EQ(r.fields[4].subfields[0].value, "The whale watchers' guide /");
		CHECK_EQ(r.fields[4].subfields[1].code, "c");
		CHECK_EQ(r.fields[4].subfields[1].value, "by Melvin Berger.");
	}

	// ---- no-header variant: no LDR, backtick separators, two records --------
	{
		auto recs = ParseMicroLif("245 0_aFirst title.\n"
		                          "`\n"
		                          "245 0_aSecond title.\n"
		                          "650 0_aDucks._xBehavior.`\n");
		CHECK_EQ(recs.size(), size_t(2));
		CHECK_EQ(recs[0].leader, "00000nam a2200000 a 4500"); // synthesised
		CHECK_EQ(recs[0].fields.size(), size_t(1));
		CHECK_EQ(recs[0].fields[0].subfields[0].value, "First title.");
		CHECK_EQ(recs[1].fields.size(), size_t(2));
		CHECK_EQ(recs[1].fields[1].subfields.size(), size_t(2));
		CHECK_EQ(recs[1].fields[1].subfields[1].code, "x");
		CHECK_EQ(recs[1].fields[1].subfields[1].value, "Behavior.");
	}

	// ---- vendor banner first line is skipped; CRLF endings ------------------
	{
		auto recs = ParseMicroLif("HEADR0100019890201     Vendor & Co.\r\n"
		                          "LDR00000nam  2200000 a 4500\r\n"
		                          "24510_aCarriage returns everywhere.`\r\n");
		CHECK_EQ(recs.size(), size_t(1));
		CHECK_EQ(recs[0].fields.size(), size_t(1));
		CHECK_EQ(recs[0].fields[0].subfields[0].value, "Carriage returns everywhere.");
	}

	// ---- tolerance: '\' blank indicators and implied $a ---------------------
	{
		auto recs = ParseMicroLif("245\\4A marker-less title_h[videorecording]`\n");
		CHECK_EQ(recs.size(), size_t(1));
		const Field &f = recs[0].fields[0];
		CHECK_EQ(f.ind1, " ");
		CHECK_EQ(f.ind2, "4");
		CHECK_EQ(f.subfields.size(), size_t(2));
		CHECK_EQ(f.subfields[0].code, "a"); // implied
		CHECK_EQ(f.subfields[0].value, "A marker-less title");
		CHECK_EQ(f.subfields[1].code, "h");
		CHECK_EQ(f.subfields[1].value, "[videorecording]");
	}

	// Underscore is a marker only before [a-z0-9]; digits are valid codes.
	{
		auto recs = ParseMicroLif("500  _aSee file a_1: yes, but a__ stays: a_ B.`\n");
		const Field &f = recs[0].fields[0];
		// "_1" is a marker; "__" and "_ " and "_B" keep their underscores.
		CHECK_EQ(f.subfields.size(), size_t(2));
		CHECK_EQ(f.subfields[0].code, "a");
		CHECK_EQ(f.subfields[0].value, "See file a");
		CHECK_EQ(f.subfields[1].code, "1");
		CHECK_EQ(f.subfields[1].value, ": yes, but a__ stays: a_ B.");
	}

	// ---- blank lines between records; terminator with no trailing newline ---
	{
		auto recs = ParseMicroLif("\n245 0_aA.`\n\n\n245 0_aB.`");
		CHECK_EQ(recs.size(), size_t(2));
		CHECK_EQ(recs[1].fields[0].subfields[0].value, "B.");
	}

	// ---- record without any terminator at EOF still flushes -----------------
	{
		auto recs = ParseMicroLif("245 0_aUnterminated.\n");
		CHECK_EQ(recs.size(), size_t(1));
	}

	// ---- LDR mid-file starts a new record (header variant, no backticks) ----
	{
		auto recs = ParseMicroLif("LDR00000nam  2200000 a 4500\n"
		                          "245 0_aOne.\n"
		                          "LDR00000cam  2200000 a 4500\n"
		                          "245 0_aTwo.\n");
		CHECK_EQ(recs.size(), size_t(2));
		CHECK_EQ(recs[1].leader[5], 'c');
		CHECK_EQ(recs[1].fields[0].subfields[0].value, "Two.");
	}

	// ---- short leader padded to 24; UTF-8 value NFC-normalised --------------
	{
		// e + COMBINING ACUTE (0xCC 0x81) must compose to U+00E9.
		auto recs = ParseMicroLif("LDR00000nam\n100 1_aRene\xCC\x81, Jean.`\n");
		CHECK_EQ(recs[0].leader.size(), size_t(24));
		CHECK_EQ(recs[0].fields[0].subfields[0].value, "Ren\xC3\xA9, Jean.");
	}

	// ---- garbage line mid-file raises with the line number ------------------
	{
		bool threw = false;
		try {
			ParseMicroLif("245 0_aOk.\n?? not a field\n");
		} catch (MarcError &e) {
			threw = true;
			CHECK(std::string(e.what()).find("line 2") != std::string::npos);
		}
		CHECK(threw);
	}

	// ---- the committed fixture parses ---------------------------------------
	{
		auto recs = ParseMicroLif(ReadFile("test/data/sample.lif"));
		CHECK_EQ(recs.size(), size_t(2));
		CHECK_EQ(recs[0].fields.size(), size_t(7));
		CHECK(recs[0].ControlNumber() != nullptr);
		CHECK_EQ(*recs[0].ControlNumber(), "MLIF0001");
		// 245 of record 1: title + $c
		bool found = false;
		for (auto &f : recs[0].fields) {
			if (f.tag == "245") {
				found = true;
				CHECK_EQ(f.subfields[0].value, "The whale watchers' guide /");
			}
		}
		CHECK(found);
		// record 2 is the no-header variant with an accented value.
		CHECK_EQ(recs[1].leader, "00000nam a2200000 a 4500");
		for (auto &f : recs[1].fields) {
			if (f.tag == "100") {
				CHECK_EQ(f.subfields[0].value, "Cousteau, Am\xC3\xA9lie.");
			}
		}
	}

	return CHECKS_MAIN_RESULT();
}
