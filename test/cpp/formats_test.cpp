// Standalone tests for the format cores (no DuckDB build needed):
//   g++ -std=c++17 -Wall -O2 -Isrc/include src/core/*.cpp test/cpp/formats_test.cpp -o formats_test
//   ./formats_test       (run from the repo root; reads test/data/sample.json)
// Mirrors the semantics of parse_marcjson / record_to_marcjson /
// parse_alephseq in tools/marcref.py.
#include "checks.hpp"
#include "marc/formats.hpp"
#include "marc/json.hpp"

#include <fstream>
#include <sstream>

using namespace marc;

static std::string ReadFile(const std::string &path) {
	std::ifstream in(path, std::ios::binary);
	std::ostringstream ss;
	ss << in.rdbuf();
	return ss.str();
}

static Field Control(const std::string &tag, const std::string &value) {
	Field f;
	f.tag = tag;
	f.is_control = true;
	f.control_value = value;
	return f;
}

static Field Data(const std::string &tag, const std::string &i1, const std::string &i2,
                  std::vector<std::pair<std::string, std::string>> subs) {
	Field f;
	f.tag = tag;
	f.ind1 = i1;
	f.ind2 = i2;
	for (auto &[code, value] : subs) {
		f.subfields.push_back(Subfield {code, value});
	}
	return f;
}

static bool RecordsEqual(const Record &a, const Record &b) {
	if (a.leader != b.leader || a.fields.size() != b.fields.size()) {
		return false;
	}
	for (size_t i = 0; i < a.fields.size(); i++) {
		const Field &x = a.fields[i], &y = b.fields[i];
		if (x.tag != y.tag || x.is_control != y.is_control) {
			return false;
		}
		if (x.is_control) {
			if (x.control_value != y.control_value) {
				return false;
			}
			continue;
		}
		if (x.ind1 != y.ind1 || x.ind2 != y.ind2 || x.subfields.size() != y.subfields.size()) {
			return false;
		}
		for (size_t k = 0; k < x.subfields.size(); k++) {
			if (x.subfields[k].code != y.subfields[k].code || x.subfields[k].value != y.subfields[k].value) {
				return false;
			}
		}
	}
	return true;
}

static const char *LDR = "00000nam a2200000 a 4500";

// Multi-script record: Latin with diacritics, Japanese, Cyrillic, Hebrew,
// an astral (4-byte UTF-8) code point, and characters JSON/XML must escape.
static Record MultiScriptRecord() {
	Record r;
	r.leader = LDR;
	r.fields.push_back(Control("001", "fmt-0001"));
	r.fields.push_back(Control("008", "200101s2020    xx            000 0 eng d"));
	r.fields.push_back(Data("100", "1", " ", {{"a", "Müller, Anna,"}, {"e", "author."}}));
	r.fields.push_back(Data("245", "1", "0", {{"a", "Łódź & the \"river\" <study> /"}, {"c", "Anna Müller."}}));
	r.fields.push_back(Data("880", "0", "0", {{"6", "245-01"}, {"a", "日本の歴史"}}));
	r.fields.push_back(Data("880", "0", "1", {{"a", "Время и река"}, {"b", "עברית"}}));
	r.fields.push_back(Data("500", " ", " ", {{"a", "Astral: 𝄞 clef; price $9.99 \\ done."}}));
	r.fields.push_back(Data("246", "3", " ", {})); // data field with no subfields
	return r;
}

// ---- shared JSON DOM -------------------------------------------------------

static bool JsonThrows(const char *text) {
	try {
		ParseJson(text);
	} catch (const MarcError &) {
		return true;
	}
	return false;
}

static void TestJsonDom() {
	JsonValue v = ParseJson(R"( {"a": [1, -2.5e3, "x\n\u00e9\uD83D\uDE00"], "b": true, "c": null} )");
	CHECK(v.type == JsonValue::Type::OBJ);
	CHECK_EQ(v.obj.size(), size_t(3));
	CHECK_EQ(v.obj[0].first, std::string("a"));
	const JsonValue *a = v.Get("a");
	CHECK(a && a->type == JsonValue::Type::ARR && a->arr.size() == 3);
	CHECK(a->arr[0].type == JsonValue::Type::NUM);
	CHECK_EQ(a->arr[1].str, std::string("-2.5e3"));
	CHECK_EQ(a->arr[2].str, std::string("x\né😀"));
	CHECK(v.Get("b")->boolean);
	CHECK(v.Get("c")->type == JsonValue::Type::NUL);
	CHECK(v.Get("missing") == nullptr);

	CHECK(JsonThrows(""));
	CHECK(JsonThrows("{"));
	CHECK(JsonThrows("{} x"));
	CHECK(JsonThrows("\"\\q\""));
	CHECK(JsonThrows("\"\\uD83D\""));
	CHECK(JsonThrows("\"\\uDC00\""));
	CHECK(JsonThrows("-"));
	CHECK(JsonThrows("1..2"));
	CHECK(JsonThrows("tru"));
	CHECK(JsonThrows(std::string(102, '[').c_str())); // depth cap

	// Streaming entry point used by the NDJSON reader.
	size_t pos = 0;
	std::string two = " {\"x\":1}\n[2] ";
	JsonValue first = ParseJsonValueAt(two, pos);
	CHECK(first.type == JsonValue::Type::OBJ);
	JsonValue second = ParseJsonValueAt(two, pos);
	CHECK(second.type == JsonValue::Type::ARR);
	CHECK_EQ(two.substr(pos), std::string(" "));

	CHECK_EQ(EscapeJsonString("a\"b\\c/d\n\t\r\b\f\x01é😀"),
	         std::string("a\\\"b\\\\c/d\\n\\t\\r\\b\\f\\u0001é😀"));
}

// ---- MARC-in-JSON ----------------------------------------------------------

static bool MarcJsonThrows(const std::string &text) {
	try {
		ParseMarcJson(text);
	} catch (const MarcError &) {
		return true;
	}
	return false;
}

static void TestMarcJson() {
	Record r = MultiScriptRecord();
	std::string j = WriteMarcJson(r);
	CHECK_EQ(j.compare(0, 11, "{\"leader\":\""), 0);

	auto back = ParseMarcJson(j);
	CHECK_EQ(back.size(), size_t(1));
	CHECK(RecordsEqual(back[0], r));

	// Array of records and NDJSON both yield the same two records.
	Record r2 = MultiScriptRecord();
	r2.fields[0].control_value = "fmt-0002";
	std::string j2 = WriteMarcJson(r2);
	auto arr = ParseMarcJson("[" + j + "," + j2 + "]");
	auto nd = ParseMarcJson(j + "\n" + j2 + "\n");
	CHECK_EQ(arr.size(), size_t(2));
	CHECK_EQ(nd.size(), size_t(2));
	CHECK(RecordsEqual(arr[1], r2));
	CHECK(RecordsEqual(nd[0], r));
	CHECK(RecordsEqual(nd[1], r2));

	// FOLIO SRS envelopes: extra keys ignored, content unwrapped.
	auto srs = ParseMarcJson("{\"id\":\"9a\",\"recordType\":\"MARC_BIB\",\"parsedRecord\":{\"id\":\"9a\",\"content\":" +
	                         j + "}}");
	CHECK_EQ(srs.size(), size_t(1));
	CHECK(RecordsEqual(srs[0], r));
	auto content_only = ParseMarcJson("{\"content\":" + j + "}");
	CHECK(RecordsEqual(content_only[0], r));
	// NDJSON of envelopes (SRS exports are NDJSON in the wild).
	auto srs_nd = ParseMarcJson("{\"content\":" + j + "}\n{\"content\":" + j2 + "}");
	CHECK_EQ(srs_nd.size(), size_t(2));
	CHECK(RecordsEqual(srs_nd[1], r2));

	// Leader padded/truncated to 24; missing leader = 24 blanks.
	auto padded = ParseMarcJson("{\"leader\":\"short\",\"fields\":[]}");
	CHECK_EQ(padded[0].leader, std::string("short") + std::string(19, ' '));
	auto truncated = ParseMarcJson("{\"leader\":\"" + std::string(30, 'x') + "\",\"fields\":[]}");
	CHECK_EQ(truncated[0].leader, std::string(24, 'x'));
	auto no_leader = ParseMarcJson("{\"fields\":[]}");
	CHECK_EQ(no_leader[0].leader, std::string(24, ' '));

	// Missing indicators/subfields default to blank/empty; values NFC.
	auto sparse = ParseMarcJson("{\"fields\":[{\"245\":{\"subfields\":[{\"a\":\"e\\u0301tude\"}]}}]}");
	CHECK_EQ(sparse[0].fields[0].ind1, std::string(" "));
	CHECK_EQ(sparse[0].fields[0].ind2, std::string(" "));
	CHECK_EQ(sparse[0].fields[0].subfields[0].value, std::string("étude"));
	auto ctrl_nfc = ParseMarcJson("{\"fields\":[{\"001\":\"e\\u0301\"}]}");
	CHECK_EQ(ctrl_nfc[0].fields[0].control_value, std::string("é"));

	// Empty array is zero records; an empty object is not a record.
	CHECK(ParseMarcJson("[]").empty());
	CHECK(MarcJsonThrows(""));
	CHECK(MarcJsonThrows("   \n"));
	CHECK(MarcJsonThrows("42"));
	CHECK(MarcJsonThrows("[1]"));
	CHECK(MarcJsonThrows("{}"));
	CHECK(MarcJsonThrows("{\"leader\":\"x\"}"));
	CHECK(MarcJsonThrows("{\"fields\":{}}"));
	CHECK(MarcJsonThrows("{\"fields\":[\"x\"]}"));
	CHECK(MarcJsonThrows("{\"fields\":[{\"245\":{},\"246\":{}}]}"));
	CHECK(MarcJsonThrows("{\"fields\":[{\"245\":\"not a control tag\"}]}"));
	CHECK(MarcJsonThrows("{\"fields\":[{\"001\":{}}]}"));
	CHECK(MarcJsonThrows("{\"fields\":[{\"245\":{\"ind1\":1}}]}"));
	CHECK(MarcJsonThrows("{\"fields\":[{\"245\":{\"subfields\":[{\"a\":1}]}}]}"));
	CHECK(MarcJsonThrows("{\"fields\":[{\"245\":{\"subfields\":{}}}]}"));
	CHECK(MarcJsonThrows("{\"fields\":[{\"245\":null}]}"));
	CHECK(MarcJsonThrows(j + "\nnot json"));
}

static void TestMarcJsonFixture() {
	std::string text = ReadFile("test/data/sample.json");
	CHECK(!text.empty());
	auto recs = ParseMarcJson(text);
	CHECK_EQ(recs.size(), size_t(3));
	CHECK_EQ(*recs[0].ControlNumber(), std::string("ocm00000001"));
	CHECK_EQ(recs[0].fields[5].subfields[0].value, std::string("Łódź and the river :"));
	CHECK_EQ(recs[1].fields[1].subfields[0].value, std::string("日本の歴史 /"));
	// Each record re-serialised must reproduce a full line of the
	// independently generated fixture, byte for byte.
	for (auto &rec : recs) {
		std::string line = WriteMarcJson(rec);
		CHECK(text.find("\n" + line + ",\n") != std::string::npos ||
		      text.find("\n" + line + "\n]") != std::string::npos);
	}
}

// ---- MARCXML writer --------------------------------------------------------

static void TestXmlWriter() {
	Record r = MultiScriptRecord();
	std::string xml = WriteMarcXml(r);
	CHECK_EQ(xml.compare(0, 8, "<record>"), 0);
	CHECK(xml.find("&amp; the &quot;river&quot;") == std::string::npos); // text nodes use &amp;/&lt;/&gt; only
	CHECK(xml.find("&amp; the \"river\" &lt;study&gt;") != std::string::npos);
	auto back = ParseMarcXml(xml);
	CHECK_EQ(back.size(), size_t(1));
	CHECK(RecordsEqual(back[0], r));

	Record r2;
	r2.leader = LDR;
	r2.fields.push_back(Control("001", "")); // empty control value
	r2.fields.push_back(Data("999", "<", "\"", {{"&", "a<b>&\"c'd"}, {"a", "line\nbreak"}}));
	auto back2 = ParseMarcXml(WriteMarcXml(r2));
	CHECK(RecordsEqual(back2[0], r2));

	auto coll = WriteMarcXmlCollection({r, r2});
	CHECK(coll.find("<collection xmlns=\"http://www.loc.gov/MARC21/slim\">") != std::string::npos);
	auto both = ParseMarcXml(coll);
	CHECK_EQ(both.size(), size_t(2));
	CHECK(RecordsEqual(both[0], r));
	CHECK(RecordsEqual(both[1], r2));
}

// ---- breaker writer --------------------------------------------------------

static void TestBreakerWriter() {
	Record r = MultiScriptRecord();
	std::string mrk = WriteBreaker(r);
	CHECK_EQ(mrk.compare(0, 6, "=LDR  "), 0);
	CHECK(mrk.find("price {dollar}9.99") != std::string::npos);
	CHECK(mrk.find("=100  1\\$a") != std::string::npos); // blank indicator as backslash
	auto back = ParseBreaker(mrk);
	CHECK_EQ(back.size(), size_t(1));
	CHECK(RecordsEqual(back[0], r));

	Record r2;
	r2.leader = LDR;
	r2.fields.push_back(Control("003", "$$"));
	r2.fields.push_back(Data("245", "0", "0", {{"a", "Money $ money"}}));
	CHECK(WriteBreaker(r2).find("=003  {dollar}{dollar}") != std::string::npos);
	auto back2 = ParseBreaker(WriteBreaker(r2));
	CHECK(RecordsEqual(back2[0], r2));

	auto both = ParseBreaker(WriteBreaker(r) + "\n" + WriteBreaker(r2));
	CHECK_EQ(both.size(), size_t(2));
	CHECK(RecordsEqual(both[0], r));
	CHECK(RecordsEqual(both[1], r2));
}

// ---- Aleph sequential ------------------------------------------------------

static bool AlephThrows(const std::string &text) {
	try {
		ParseAlephSeq(text);
	} catch (const MarcError &) {
		return true;
	}
	return false;
}

static void TestAlephSeq() {
	std::string text = "000000001 LDR   L ^^^^^nam^a22^^^^^^a^4500\n"
	                   "000000001 FMT   L BK\n"
	                   "000000001 001   L 000000001\n"
	                   "000000001 008   L 200101s2020^^^^xx^eng^d\n"
	                   "000000001 24510 L $$a\xC5\x81\xC3\xB3" "d\xC5\xBA :$$ba study /\n"
	                   "000000001 650 0 L $$aRivers$$zPoland\n"
	                   "\n"
	                   "000000002 LDR   L 00000nam^a2200000^a^4500\r\n"
	                   "000000002 001   L 000000002\n"
	                   "000000002 24500 L $$a\xE6\x97\xA5\xE6\x9C\xAC$$c\xE5\xB1\xB1\xE7\x94\xB0\n"
	                   "000000003 100   L $$aNo leader here.\n";
	auto recs = ParseAlephSeq(text);
	CHECK_EQ(recs.size(), size_t(3));

	const Record &a = recs[0];
	CHECK_EQ(a.leader, std::string("     nam a22      a 4500"));
	CHECK_EQ(a.fields.size(), size_t(5));
	CHECK_EQ(a.fields[0].tag, std::string("FMT")); // fixed field kept, content dropped
	CHECK(!a.fields[0].is_control);
	CHECK(a.fields[0].subfields.empty());
	CHECK(a.fields[1].is_control);
	CHECK_EQ(a.fields[1].control_value, std::string("000000001"));
	CHECK_EQ(a.fields[2].control_value, std::string("200101s2020    xx eng d")); // ^ = blank in 00X
	CHECK_EQ(a.fields[3].ind1, std::string("1"));
	CHECK_EQ(a.fields[3].ind2, std::string("0"));
	CHECK_EQ(a.fields[3].subfields[0].value, std::string("Łódź :"));
	CHECK_EQ(a.fields[3].subfields[1].code, std::string("b"));
	CHECK_EQ(a.fields[4].ind1, std::string(" "));
	CHECK_EQ(a.fields[4].ind2, std::string("0"));

	const Record &b = recs[1];
	CHECK_EQ(b.leader, std::string("00000nam a2200000 a 4500"));
	CHECK_EQ(b.fields[1].subfields[0].value, std::string("日本"));
	CHECK_EQ(b.fields[1].subfields[1].value, std::string("山田"));

	CHECK_EQ(recs[2].leader, std::string("00000nam a2200000 a 4500")); // default leader
	CHECK_EQ(recs[2].fields[0].subfields[0].value, std::string("No leader here."));

	// A repeated LDR within one record replaces the earlier leader.
	auto reled = ParseAlephSeq("000000009 LDR   L first\n000000009 LDR   L 00000nam^a2200000^a^4500\n");
	CHECK_EQ(reled[0].leader, std::string("00000nam a2200000 a 4500"));

	// NFC normalisation of values (combining acute after 'e').
	auto nfc = ParseAlephSeq("000000004 24500 L $$ae\xCC\x81tude\n");
	CHECK_EQ(nfc[0].fields[0].subfields[0].value, std::string("étude"));

	// Empty content lines: bare 17-column header is a blank control field.
	auto empty = ParseAlephSeq("000000005 001   L\n000000005 002   L \n");
	CHECK_EQ(empty[0].fields.size(), size_t(2));
	CHECK_EQ(empty[0].fields[0].control_value, std::string(""));

	CHECK(AlephThrows("000000001 001 L x\n"));                        // header too short
	CHECK(AlephThrows("00000000A 001   L x\n"));                      // non-digit id
	CHECK(AlephThrows("000000001 001   X x\n"));                      // missing 'L'
	CHECK(AlephThrows("000000001 001   Lx\n"));                       // missing space after L
	CHECK(AlephThrows("000000001 0!1   L x\n"));                      // bad tag
	CHECK(AlephThrows("000000001-001   L x\n"));                      // bad separator
}

int main() {
	TestJsonDom();
	TestMarcJson();
	TestMarcJsonFixture();
	TestXmlWriter();
	TestBreakerWriter();
	TestAlephSeq();
	return CHECKS_MAIN_RESULT();
}
