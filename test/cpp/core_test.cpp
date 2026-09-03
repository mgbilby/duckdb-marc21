// Standalone tests for the DuckDB-free core (no DuckDB build needed):
//   g++ -std=c++17 -Isrc/include src/core/*.cpp test/cpp/core_test.cpp -o core_test
//   ./core_test          (run from the repo root; reads test/data fixtures)
// Mirrors the semantics asserted by tools/marcref.py and the sqllogictests.
#include "marc/core.hpp"
#include "marc/query.hpp"

#include <cstdio>
#include <fstream>
#include <sstream>

static int failures = 0;
#define CHECK(cond)                                                                                                    \
	do {                                                                                                               \
		if (!(cond)) {                                                                                                 \
			std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                       \
			failures++;                                                                                                \
		}                                                                                                              \
	} while (0)
#define CHECK_EQ(a, b)                                                                                                 \
	do {                                                                                                               \
		auto va = (a);                                                                                                 \
		auto vb = (b);                                                                                                 \
		if (!(va == vb)) {                                                                                             \
			std::fprintf(stderr, "FAIL %s:%d: %s != %s\n", __FILE__, __LINE__, #a, #b);                                \
			failures++;                                                                                                \
		}                                                                                                              \
	} while (0)

using namespace marc;

static std::string BuildTestRecord(const std::vector<std::pair<std::string, std::string>> &fields) {
	std::string body, dir;
	for (auto &[tag, data] : fields) {
		size_t start = body.size();
		body += data;
		body.push_back(static_cast<char>(FT));
		char entry[13];
		std::snprintf(entry, sizeof(entry), "%s%04zu%05zu", tag.c_str(), body.size() - start, start);
		dir += entry;
	}
	dir.push_back(static_cast<char>(FT));
	size_t base = 24 + dir.size();
	size_t total = base + body.size() + 1;
	char leader[32];
	std::snprintf(leader, sizeof(leader), "%05zunam a22%05zu a 4500", total, base);
	std::string out(leader, 24);
	out += dir + body;
	out.push_back(static_cast<char>(RT));
	return out;
}

static std::string ReadFile(const std::string &path) {
	std::ifstream in(path, std::ios::binary);
	CHECK(in.good());
	std::ostringstream ss;
	ss << in.rdbuf();
	return ss.str();
}

static size_t FlatRowCount(const std::vector<Record> &recs) {
	size_t rows = 0;
	for (auto &r : recs) {
		for (auto &f : r.fields) {
			rows += f.is_control ? 1 : f.subfields.size();
		}
	}
	return rows;
}

static void TestIso2709Real() {
	auto raw = BuildTestRecord({{"001", "abc123"}, {"245", "10\x1f" "aTitle :\x1f" "bsub /"}});
	auto rec = ParseRecord(raw, Encoding::AUTO);
	CHECK_EQ(*rec.ControlNumber(), std::string("abc123"));
	CHECK_EQ(rec.fields.size(), 2u);
	CHECK_EQ(rec.fields[1].ind1, "1");
	CHECK_EQ(rec.fields[1].ind2, "0");
	CHECK_EQ(rec.fields[1].subfields.size(), 2u);
	CHECK_EQ(rec.fields[1].subfields[0].code, "a");
	CHECK_EQ(rec.fields[1].subfields[0].value, "Title :");
	CHECK_EQ(rec.fields[1].subfields[1].value, "sub /");

	// Splitter: newline between records, trailing fragment yielded.
	auto a = BuildTestRecord({{"001", "1"}});
	auto b = BuildTestRecord({{"001", "2"}});
	std::string stream = a + "\n" + b + "garbage";
	RecordSplitter split(stream);
	std::string_view part;
	CHECK(split.Next(part) && part == a);
	CHECK(split.Next(part) && part == b);
	CHECK(split.Next(part) && part == "garbage");
	CHECK(!split.Next(part));

	// Corrupt directory entry is an error.
	auto bad = BuildTestRecord({{"001", "1"}});
	bad[24 + 3] = 'X';
	try {
		ParseRecord(bad, Encoding::AUTO);
		CHECK(false);
	} catch (MarcError &e) {
		CHECK(std::string(e.what()).find("non-numeric directory entry") != std::string::npos);
	}
	try {
		ParseRecord("too short", Encoding::AUTO);
		CHECK(false);
	} catch (MarcError &) {
	}
}

static void TestMarc8() {
	CHECK_EQ(Marc8Decode("Hello, world."), "Hello, world.");
	// 0xE8 (diaeresis) precedes 'u' -> ü (U+00FC after NFC)
	CHECK_EQ(Marc8Decode(std::string("\x4d\xe8\x75\x6c\x6c\x65\x72", 7)), "M\xc3\xbcller");
	// 0xA1 = Ł, 0xB2 = ø, 0xA5 = Æ; acute 0xE2 before each base it modifies
	CHECK_EQ(Marc8Decode(std::string("\xa1\x6f\x64\xe2\x7a", 5)), "\xc5\x81od\xc5\xba");
	CHECK_EQ(Marc8Decode(std::string("\xa5\x72\xb2", 3)), "\xc3\x86r\xc3\xb8");
	CHECK_EQ(Marc8Decode(std::string("\xa1\xe2\x6f\x64\xe2\x7a", 6)), "\xc5\x81\xc3\xb3" "d\xc5\xba");
	// Dangling diacritic composes with the preceding base under NFC: a+acute=á
	CHECK_EQ(Marc8Decode(std::string("\x61\xe2", 2)), "\xc3\xa1");
	// Unknown bytes and unknown designations become U+FFFD
	CHECK_EQ(Marc8Decode(std::string("\x61\xff\x62", 3)), "a\xef\xbf\xbd" "b");
	CHECK_EQ(Marc8Decode(std::string("\x61\x1b\x28\x7a\x62", 5)), "a\xef\xbf\xbd" "b");
	// Full tables: G0/G1 designations across every LC set.
	// ESC ( N selects Basic Cyrillic G0; 'b' = U+0411; ESC s resumes ASCII
	CHECK_EQ(Marc8Decode(std::string("a\x1b(Nb\x1bsb", 8)), "a\xd0\x91" "b");
	// ESC ) S selects Basic Greek as G1; 0xE1 masks to 0x61 = U+03B1
	CHECK_EQ(Marc8Decode(std::string("x\x1b)S\xe1", 5)), "x\xce\xb1");
	// ESC $ 1 selects EACC (three bytes per char); 21 30 21 = U+4E00
	CHECK_EQ(Marc8Decode(std::string("\x1b$1\x21\x30\x21\x1bsA", 9)), "\xe4\xb8\x80" "A");
	// ESC ( 2 selects Basic Hebrew; 0x60 = U+05D0
	CHECK_EQ(Marc8Decode(std::string("\x1b(2\x60", 4)), "\xd7\x90");
	// ESC b selects subscripts; ESC s resumes: H2O with subscript two
	CHECK_EQ(Marc8Decode(std::string("H\x1b" "b2\x1bsO", 7)), "H\xe2\x82\x82O");
	// Split ligature (EB..EC): LC's preferred mapping is one spanning
	// U+0361 from EB, with EC mapping to nothing
	CHECK_EQ(Marc8Decode(std::string("\xeb\x74\xec\x73", 4)), "t\xcd\xa1s");
	// Truncated EACC sequence at end of string
	CHECK_EQ(Marc8Decode(std::string("\x1b$1\x21\x30", 5)), "\xef\xbf\xbd");
}

static void TestWriter() {
	Record rec;
	rec.leader = "00000nam a2200000 a 4500";
	Field f1;
	f1.tag = "001";
	f1.is_control = true;
	f1.control_value = "rec1";
	Field f2;
	f2.tag = "245";
	f2.ind1 = "1";
	f2.ind2 = "0";
	f2.subfields = {{"a", "\xc5\x81\xc3\xb3" "d\xc5\xba :"}, {"b", "a study /"}};
	rec.fields = {f1, f2};

	auto bytes = WriteRecord(rec);
	CHECK_EQ(std::stoul(bytes.substr(0, 5)), bytes.size());
	size_t base = std::stoul(bytes.substr(12, 5));
	CHECK_EQ(static_cast<uint8_t>(bytes[base - 1]), FT);
	CHECK_EQ(bytes[9], 'a');

	auto back = ParseRecord(bytes, Encoding::AUTO);
	CHECK_EQ(*back.ControlNumber(), std::string("rec1"));
	CHECK_EQ(back.fields[1].subfields[0].value, f2.subfields[0].value);

	Field big;
	big.tag = "520";
	big.subfields = {{"a", std::string(10000, 'x')}};
	rec.fields.push_back(big);
	try {
		WriteRecord(rec);
		CHECK(false);
	} catch (MarcError &) {
	}
}

static void TestBreaker() {
	const char *sample = "=LDR  00000nam a2200000 a 4500\n"
	                     "=001  rec1\n"
	                     "=245  10$aTitle :$bsub /\n"
	                     "\n"
	                     "=LDR  00000nam a2200000 a 4500\n"
	                     "=001  rec2\n"
	                     "=650  \\0$aCats{dollar}Dogs\n";
	auto recs = ParseBreaker(sample);
	CHECK_EQ(recs.size(), 2u);
	CHECK_EQ(*recs[0].ControlNumber(), std::string("rec1"));
	CHECK_EQ(recs[1].fields[1].ind1, " ");
	CHECK_EQ(recs[1].fields[1].ind2, "0");
	CHECK_EQ(recs[1].fields[1].subfields[0].value, "Cats$Dogs");
	for (auto &r : recs) {
		auto bytes = WriteRecord(r);
		auto back = ParseRecord(bytes, Encoding::AUTO);
		CHECK_EQ(back.fields.size(), r.fields.size());
	}
	try {
		ParseBreaker("=2!5  10$aX");
		CHECK(false);
	} catch (MarcError &) {
	}
}

static void TestMarcXml() {
	const char *sample =
	    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
	    "<marc:collection xmlns:marc=\"http://www.loc.gov/MARC21/slim\">\n"
	    " <marc:record>\n"
	    "  <marc:leader>00109nam a2200061 a 4500</marc:leader>\n"
	    "  <marc:controlfield tag=\"001\">rec1</marc:controlfield>\n"
	    "  <marc:datafield tag=\"245\" ind1=\"1\" ind2=\"0\">\n"
	    "   <marc:subfield code=\"a\">Tom &amp; Jerry &#x141;&#243;d&#378; :</marc:subfield>\n"
	    "   <marc:subfield code=\"b\">a study /</marc:subfield>\n"
	    "  </marc:datafield>\n"
	    " </marc:record>\n"
	    " <marc:record>\n"
	    "  <marc:leader>00047nam a2200037 a 4500</marc:leader>\n"
	    "  <marc:controlfield tag=\"001\">rec2</marc:controlfield>\n"
	    " </marc:record>\n"
	    "</marc:collection>\n";
	auto recs = ParseMarcXml(sample);
	CHECK_EQ(recs.size(), 2u);
	CHECK_EQ(*recs[0].ControlNumber(), std::string("rec1"));
	CHECK_EQ(recs[0].leader.size(), 24u);
	CHECK_EQ(recs[0].fields[1].ind1, "1");
	CHECK_EQ(recs[0].fields[1].subfields[0].value, "Tom & Jerry \xc5\x81\xc3\xb3" "d\xc5\xba :");
	CHECK_EQ(recs[0].fields[1].subfields[1].code, "b");
	try {
		ParseMarcXml("<record><controlfield>x</controlfield></record>");
		CHECK(false);
	} catch (MarcError &) {
	}
}

static void TestFixtures() {
	// Binary UTF-8 fixture: 3 records, 27 flat rows.
	auto utf8 = ReadFile("test/data/sample_utf8.mrc");
	std::vector<Record> recs;
	RecordSplitter split(utf8);
	std::string_view raw;
	while (split.Next(raw)) {
		recs.push_back(ParseRecord(raw, Encoding::AUTO));
	}
	CHECK_EQ(recs.size(), 3u);
	CHECK_EQ(FlatRowCount(recs), 27u);
	CHECK_EQ(*recs[0].ControlNumber(), std::string("ocm00000001"));

	// MARC-8 fixture decodes to the same strings the UTF-8 one carries.
	auto m8 = ReadFile("test/data/sample_marc8.mrc");
	RecordSplitter split8(m8);
	CHECK(split8.Next(raw));
	auto rec8 = ParseRecord(raw, Encoding::AUTO);
	CHECK_EQ(rec8.fields[1].subfields[0].value, "M\xc3\xbcller, Anna,");
	CHECK_EQ(rec8.fields[2].subfields[0].value, "\xc5\x81\xc3\xb3" "d\xc5\xba and the caf\xc3\xa9 :");

	// Text-format fixtures mirror sample_utf8.mrc.
	auto mrk = ParseBreaker(ReadFile("test/data/sample.mrk"));
	CHECK_EQ(mrk.size(), 3u);
	CHECK_EQ(FlatRowCount(mrk), 27u);
	auto xml = ParseMarcXml(ReadFile("test/data/sample.xml"));
	CHECK_EQ(xml.size(), 3u);
	CHECK_EQ(FlatRowCount(xml), 27u);
	CHECK_EQ(*xml[1].ControlNumber(), std::string("ocm00000002"));

	// Malformed fixture: records 1 and 3 parse, record 2 does not.
	auto mal = ReadFile("test/data/malformed.mrc");
	RecordSplitter splitm(mal);
	int ok = 0, err = 0;
	while (splitm.Next(raw)) {
		try {
			ParseRecord(raw, Encoding::AUTO);
			ok++;
		} catch (MarcError &) {
			err++;
		}
	}
	CHECK_EQ(ok, 2);
	CHECK_EQ(err, 1);
}

static Field CF(const char *tag, const char *value) {
	Field f;
	f.tag = tag;
	f.is_control = true;
	f.control_value = value;
	return f;
}

static Field DF(const char *tag, const char *i1, const char *i2, std::vector<Subfield> subs) {
	Field f;
	f.tag = tag;
	f.ind1 = i1;
	f.ind2 = i2;
	f.subfields = std::move(subs);
	return f;
}

static bool Contains(const std::vector<std::string> &v, const std::string &s) {
	for (auto &x : v) {
		if (x == s) {
			return true;
		}
	}
	return false;
}

static bool AvramParseThrows(const char *json) {
	try {
		ParseAvramSchema(json);
		return false;
	} catch (MarcError &) {
		return true;
	}
}

static void TestAvram() {
	const char *schema_json = R"({
		"title": "test schema \u00e9 \uD83D\uDE00",
		"count": -3.5e2,
		"url": ["http://example.org", null, true],
		"fields": {
			"001": {"required": true, "label": "control number"},
			"245": {
				"required": true,
				"indicator1": {"codes": {"0": {"label": "No added entry"}, "1": "Added entry"}},
				"indicator2": null,
				"subfields": {
					"a": {"required": true},
					"b": {},
					"c": {"repeatable": false}
				}
			},
			"650": {
				"repeatable": true,
				"indicator2": {"codes": {"0": "LCSH", "1": "children's", "7": "other"}},
				"subfields": {"a": {"required": true}, "x": {"repeatable": true}}
			},
			"500": {"repeatable": true}
		}
	})";
	auto schema = ParseAvramSchema(schema_json);
	CHECK_EQ(schema.fields.size(), 4u);
	CHECK(schema.fields.at("001").required);
	CHECK(!schema.fields.at("001").subfields.has_value());
	CHECK(schema.fields.at("245").ind1_codes.has_value());
	CHECK(!schema.fields.at("245").ind2_codes.has_value());

	Record good;
	good.leader = "00000nam a2200000 a 4500";
	good.fields = {CF("001", "rec1"), DF("245", "1", " ", {{"a", "Title :"}, {"c", "by X."}}),
	               DF("650", " ", "0", {{"a", "Cats"}, {"x", "Fiction"}, {"x", "History"}})};
	CHECK(AvramValidate(schema, good).empty());

	Record bad;
	bad.leader = good.leader;
	bad.fields = {DF("245", "2", "0", {{"q", "?"}, {"c", "one"}, {"c", "two"}}), DF("245", "1", " ", {{"a", "T"}}),
	              DF("650", " ", "9", {{"a", "Dogs"}}), DF("999", "0", "0", {{"z", "local"}})};
	auto viol = AvramValidate(schema, bad);
	CHECK_EQ(viol.size(), 7u);
	CHECK(Contains(viol, "001: required field missing"));
	CHECK(Contains(viol, "245: non-repeatable field occurs 2 times"));
	CHECK(Contains(viol, "245 ind1: '2' not one of [0,1]"));
	CHECK(Contains(viol, "245$q: not in schema"));
	CHECK(Contains(viol, "245$c: non-repeatable subfield occurs 2 times"));
	CHECK(Contains(viol, "245$a: required subfield missing"));
	CHECK(Contains(viol, "650 ind2: '9' not one of [0,1,7]"));

	// A control field never triggers indicator or subfield checks.
	Record ctrl;
	ctrl.leader = good.leader;
	ctrl.fields = {CF("001", "x"), CF("245", "weird but control"), CF("650", "also control")};
	auto cviol = AvramValidate(schema, ctrl);
	CHECK_EQ(cviol.size(), 0u);

	// An empty "fields" object accepts everything.
	CHECK(AvramValidate(ParseAvramSchema("{\"fields\": {}}"), bad).empty());

	CHECK(AvramParseThrows("{"));
	CHECK(AvramParseThrows("[]"));
	CHECK(AvramParseThrows("{\"fields\": 3}"));
	CHECK(AvramParseThrows("{\"fields\": {\"245\": {\"repeatable\": \"yes\"}}}"));
	CHECK(AvramParseThrows("{\"fields\": {\"245\": {\"indicator1\": {\"codes\": []}}}}"));
	CHECK(AvramParseThrows("{\"fields\": {\"245\": {\"subfields\": {\"a\": 1}}}}"));
	CHECK(AvramParseThrows("{\"fields\": {}} x"));
	CHECK(AvramParseThrows("{\"t\": \"\\q\", \"fields\": {}}"));
	CHECK(AvramParseThrows("{\"t\": \"\\uD83D\", \"fields\": {}}"));
	CHECK(AvramParseThrows("{\"n\": 1.., \"fields\": {}}"));
	CHECK(AvramParseThrows(""));
}

static bool SpecThrows(const Record &rec, const char *spec, const char *needle = nullptr) {
	try {
		MarcSpecEvaluate(rec, spec);
		return false;
	} catch (MarcError &e) {
		return !needle || std::string(e.what()).find(needle) != std::string::npos;
	}
}

static void TestMarcSpec() {
	using SV = std::vector<std::string>;
	Record rec;
	rec.leader = "01234nam a2200000 a 4500";
	std::string f008(40, ' ');
	f008.replace(0, 6, "200101");
	f008.replace(35, 3, "eng");
	f008[39] = 'd';
	rec.fields = {CF("001", "rec9"),
	              CF("008", f008.c_str()),
	              DF("245", "1", "0", {{"a", "Title :"}, {"b", "sub /"}}),
	              DF("650", " ", "0", {{"a", "Cats"}, {"x", "Fiction"}}),
	              DF("650", " ", "0", {{"a", "Dogs"}}),
	              DF("650", " ", "7", {{"a", "Birds"}, {"a", "Owls"}})};

	// Leader and character positions/ranges (byte positions).
	CHECK(MarcSpecEvaluate(rec, "LDR") == (SV {rec.leader}));
	CHECK(MarcSpecEvaluate(rec, "LDR/6") == (SV {"a"}));
	CHECK(MarcSpecEvaluate(rec, "LDR/0-4") == (SV {"01234"}));
	CHECK(MarcSpecEvaluate(rec, "LDR/7-#") == (SV {"m a2200000 a 4500"}));
	CHECK(MarcSpecEvaluate(rec, "LDR/#") == (SV {"0"}));
	CHECK(MarcSpecEvaluate(rec, "LDR/#-1") == (SV {"00"}));
	CHECK(MarcSpecEvaluate(rec, "LDR/30").empty());

	// Control fields.
	CHECK(MarcSpecEvaluate(rec, "001") == (SV {"rec9"}));
	CHECK(MarcSpecEvaluate(rec, "008/35-37") == (SV {"eng"}));
	CHECK(MarcSpecEvaluate(rec, "008/#") == (SV {"d"}));
	CHECK(MarcSpecEvaluate(rec, "008/38-#") == (SV {" d"}));
	CHECK(MarcSpecEvaluate(rec, "00.") == (SV {"rec9", f008}));

	// Data fields, subfields, indices.
	CHECK(MarcSpecEvaluate(rec, "245") == (SV {"Title : sub /"}));
	CHECK(MarcSpecEvaluate(rec, "245$a") == (SV {"Title :"}));
	CHECK(MarcSpecEvaluate(rec, "245$a$b") == (SV {"Title :", "sub /"}));
	CHECK(MarcSpecEvaluate(rec, "245$z").empty());
	CHECK(MarcSpecEvaluate(rec, "6..") == (SV {"Cats Fiction", "Dogs", "Birds Owls"}));
	CHECK(MarcSpecEvaluate(rec, "2.5$b") == (SV {"sub /"}));
	CHECK(MarcSpecEvaluate(rec, "650[0]$a") == (SV {"Cats"}));
	CHECK(MarcSpecEvaluate(rec, "650[1]$a") == (SV {"Dogs"}));
	CHECK(MarcSpecEvaluate(rec, "650[#]$a") == (SV {"Birds", "Owls"}));
	CHECK(MarcSpecEvaluate(rec, "650[#]$a[1]") == (SV {"Owls"}));
	CHECK(MarcSpecEvaluate(rec, "650[#]$a[#]") == (SV {"Owls"}));
	CHECK(MarcSpecEvaluate(rec, "650[0-1]$a") == (SV {"Cats", "Dogs"}));
	CHECK(MarcSpecEvaluate(rec, "650[0-#]$x") == (SV {"Fiction"}));
	CHECK(MarcSpecEvaluate(rec, "650[5]$a").empty());
	CHECK(MarcSpecEvaluate(rec, "999").empty());

	// Wildcard over everything: control values plus joined data fields.
	auto all = MarcSpecEvaluate(rec, "...");
	CHECK_EQ(all.size(), 6u);
	CHECK_EQ(all.front(), std::string("rec9"));
	CHECK_EQ(all.back(), std::string("Birds Owls"));

	// Indicators.
	CHECK(MarcSpecEvaluate(rec, "245^1") == (SV {"1"}));
	CHECK(MarcSpecEvaluate(rec, "245^2") == (SV {"0"}));
	CHECK(MarcSpecEvaluate(rec, "650^2") == (SV {"0", "0", "7"}));
	CHECK(MarcSpecEvaluate(rec, "650[1-#]^2") == (SV {"0", "7"}));

	// Well-formed combinations that select nothing.
	CHECK(MarcSpecEvaluate(rec, "245/0-3").empty()); // charspec on a data field
	CHECK(MarcSpecEvaluate(rec, "001^1").empty());   // indicator on a control field
	CHECK(MarcSpecEvaluate(rec, "001$a").empty());   // subfield on a control field

	// Invalid specs throw.
	CHECK(SpecThrows(rec, ""));
	CHECK(SpecThrows(rec, "24"));
	CHECK(SpecThrows(rec, "24!"));
	CHECK(SpecThrows(rec, "2455"));
	CHECK(SpecThrows(rec, "245{245$a}", "subspecs not supported"));
	CHECK(SpecThrows(rec, "245$a{245$b}", "subspecs not supported"));
	CHECK(SpecThrows(rec, "LDR[0]"));
	CHECK(SpecThrows(rec, "LDR$a"));
	CHECK(SpecThrows(rec, "LDR^1"));
	CHECK(SpecThrows(rec, "245$"));
	CHECK(SpecThrows(rec, "245$a-c"));
	CHECK(SpecThrows(rec, "245$a/0-3"));
	CHECK(SpecThrows(rec, "245^3"));
	CHECK(SpecThrows(rec, "245^"));
	CHECK(SpecThrows(rec, "245["));
	CHECK(SpecThrows(rec, "245[]"));
	CHECK(SpecThrows(rec, "245[1-]"));
	CHECK(SpecThrows(rec, "245[1"));
	CHECK(SpecThrows(rec, "008/"));
}

static void TestMarc8Encoder() {
	// Exact byte expectations, derived once from the ANSEL table.
	auto hex = [](const std::string &s) {
		std::string h;
		char buf[3];
		for (unsigned char c : s) {
			std::snprintf(buf, sizeof(buf), "%02X", c);
			h += buf;
		}
		return h;
	};
	CHECK_EQ(EncodeMarc8("Hello, world."), "Hello, world.");
	CHECK_EQ(hex(EncodeMarc8("M\xc3\xbcller")), "4DE8756C6C6572");
	CHECK_EQ(hex(EncodeMarc8("\xc5\x81\xc3\xb3" "d\xc5\xba")), "A1E26F64E27A");
	// Spanning U+0361: EB before the first letter, EC before the second
	CHECK_EQ(hex(EncodeMarc8("t\xcd\xa1s")), "EB74EC73");
	CHECK_EQ(hex(EncodeMarc8("\xc3\x86r\xc3\xb8")), "A572B2");
	// Round trips: decode(encode(s)) == s for everything ANSEL-representable
	for (const char *s : {"Hello, world.", "M\xc3\xbcller", "\xc5\x81\xc3\xb3" "d\xc5\xba", "t\xcd\xa1s",
	                      "\xc3\x86r\xc3\xb8", "Na\xc3\xafve art", "caf\xc3\xa9"}) {
		CHECK_EQ(Marc8Decode(EncodeMarc8(s)), std::string(s));
	}
	// Non-Latin scripts get native G0 escape designations (ESC ( F single
	// byte, ESC $ 1 for EACC, ASCII restored with ESC ( B); round trips
	// exactly, matching unicode_to_marc8 byte-for-byte.
	CHECK_EQ(EncodeMarc8("\xe6\x97\xa5\xe6\x9c\xac"), std::string("\x1b\x24\x31\x21\x42\x73\x21\x43\x69\x1b\x28\x42", 12));
	CHECK_EQ(EncodeMarc8("\xd0\x92\xd1\x80\xd0\xb5\xd0\xbc\xd1\x8f"),
	         std::string("\x1b\x28\x4e\x77\x52\x45\x4d\x51\x1b\x28\x42", 11));
	CHECK_EQ(EncodeMarc8("\xd7\x90\xd7\x91"), std::string("\x1b\x28\x32\x60\x61\x1b\x28\x42", 8));
	// Hangul: NFD jamo are recomposed to the EACC precomposed syllables
	CHECK_EQ(EncodeMarc8("\xed\x95\x9c\xea\xb5\xad\xec\x96\xb4"),
	         std::string("\x1b\x24\x31\x6f\x5c\x65\x6f\x49\x6f\x6f\x55\x44\x1b\x28\x42", 15));
	for (auto s2 : {"\xd0\x92\xd1\x80\xd0\xb5\xd0\xbc\xd1\x8f \xd0\xbd\xd0\xbe\xd1\x87\xd1\x8c",
	                "\xce\xb1\xce\xb2\xce\xb3", "\xe6\x97\xa5\xe6\x9c\xac\xe3\x81\xae\xe6\xad\xb4\xe5\x8f\xb2",
	                "\xed\x95\x9c\xea\xb5\xad\xec\x96\xb4", "t\xcd\xa1\xce\xb1",
	                "mixed \xd0\x9a\xd0\xb8\xd1\x80 and \xe6\xbc\xa2\xe5\xad\x97 text"}) {
		CHECK_EQ(Marc8Decode(EncodeMarc8(s2)), std::string(s2));
	}
	// Characters in no LC set still fall back to NCR: the literal "&#x...;"
	// survives the round trip; consumers un-NCR downstream.
	CHECK_EQ(EncodeMarc8("x\xcc\xb8y"), "x&#x338;y");
	// Spanning mark with no following encodable base: NCR, never a bare EB
	CHECK_EQ(hex(EncodeMarc8("t\xcd\xa1")), "742623783336313B"); // "t&#x361;"

	Record rec;
	rec.leader = "00000nam a2200000 a 4500";
	Field f;
	f.tag = "245";
	f.ind1 = "1";
	f.ind2 = "0";
	f.subfields = {{"a", "\xc5\x81\xc3\xb3" "d\xc5\xba and the caf\xc3\xa9 :"}, {"b", "\xc3\x86r\xc3\xb8 /"}};
	rec.fields = {f};
	auto bytes = WriteRecordMarc8(rec);
	CHECK_EQ(bytes[9], ' '); // leader/09 blank = MARC-8
	auto back = ParseRecord(bytes, Encoding::AUTO);
	CHECK_EQ(back.fields[0].subfields[0].value, f.subfields[0].value);
	CHECK_EQ(back.fields[0].subfields[1].value, f.subfields[1].value);
}

int main() {
	TestIso2709Real();
	TestMarc8();
	TestWriter();
	TestMarc8Encoder();
	TestBreaker();
	TestMarcXml();
	TestFixtures();
	TestAvram();
	TestMarcSpec();
	if (failures == 0) {
		std::printf("core_test: all checks passed\n");
		return 0;
	}
	std::printf("core_test: %d failure(s)\n", failures);
	return 1;
}
