// Standalone tests for the Z39.50 client core (no network, no DuckDB):
//   g++ -std=c++17 -Wall -O2 -Isrc/include src/core/*.cpp test/cpp/z3950_test.cpp -o z3950_test
// All server responses are hand-built with the ber primitives (self-
// consistency) and served through a scripted MockTransport — no live-server
// test is possible in this environment.
#include "checks.hpp"
#include "marc/z3950.hpp"

#include <cstdint>
#include <string>
#include <vector>

using namespace marc;
using ber::Class;
using ber::Tag;
using ber::Tlv;

// ---- helpers ----------------------------------------------------------------

static std::string C(uint32_t n, std::string_view content) {
	return Tlv(Class::CONTEXT, false, n, content);
}
static std::string CS(uint32_t n, std::string_view content) {
	return Tlv(Class::CONTEXT, true, n, content);
}
static std::string US(std::string_view content) {
	return Tlv(Class::UNIVERSAL, true, ber::TAG_SEQUENCE, content);
}
static std::string I(int64_t v) {
	return ber::IntegerContent(v);
}
static std::string UOid(const std::vector<uint32_t> &arcs) {
	return Tlv(Class::UNIVERSAL, false, ber::TAG_OID, ber::OidContent(arcs));
}

static const std::vector<uint32_t> USMARC_OID = {1, 2, 840, 10003, 5, 10};
static const std::vector<uint32_t> DIAG_BIB1_OID = {1, 2, 840, 10003, 4, 1};

struct MockTransport : Z3950Transport {
	std::vector<std::string> script; // each entry returned by one Recv()
	std::vector<std::string> sent;
	size_t next = 0;

	void Send(const std::string &bytes) override {
		sent.push_back(bytes);
	}
	std::string Recv() override {
		return next < script.size() ? script[next++] : std::string();
	}
};

static std::string InitResponseApdu(bool accept) {
	std::string body;
	body += C(3, ber::BitStringContent({0, 1}));
	body += C(4, ber::BitStringContent({0, 1}));
	body += C(5, I(1 << 20));
	body += C(6, I(4 << 20));
	body += C(12, accept ? "\xFF" : std::string_view("\x00", 1)); // result [12] BOOLEAN
	return CS(21, body);
}

static std::string SearchResponseApdu(int64_t count, bool ok, std::string_view records = {}) {
	std::string body;
	body += C(23, I(count));   // resultCount
	body += C(24, I(0));       // numberOfRecordsReturned
	body += C(25, I(1));       // nextResultSetPosition
	body += C(22, ok ? "\xFF" : std::string_view("\x00", 1)); // searchStatus
	body.append(records);
	return CS(23, body);
}

// NamePlusRecord carrying a USMARC retrieval record:
//   SEQUENCE { record [1] EXPLICIT { [1] IMPLICIT EXTERNAL { OID, [1] octets } } }
static std::string NamePlusRecord(std::string_view iso2709) {
	std::string external = UOid(USMARC_OID) + C(1, iso2709); // octet-aligned encoding
	return US(CS(1, CS(1, external)));
}

static std::string PresentResponseApdu(const std::vector<std::string> &recs, int64_t next_pos,
                                       std::string_view records_override = {}) {
	std::string body;
	body += C(24, I(static_cast<int64_t>(recs.size()))); // numberOfRecordsReturned
	body += C(25, I(next_pos));                          // nextResultSetPosition
	body += C(27, I(0));                                 // presentStatus success
	if (!records_override.empty()) {
		body.append(records_override);
	} else {
		std::string list;
		for (const auto &r : recs) {
			list += NamePlusRecord(r);
		}
		body += CS(28, list); // responseRecords
	}
	return CS(25, body);
}

static std::string DefaultDiagContent(int64_t condition, std::string_view addinfo) {
	return UOid(DIAG_BIB1_OID) + Tlv(Class::UNIVERSAL, false, ber::TAG_INTEGER, I(condition)) +
	       Tlv(Class::UNIVERSAL, false, ber::TAG_VISIBLE_STRING, addinfo);
}

static std::string FakeIso2709(const std::string &control_number, const std::string &title) {
	Record rec;
	rec.leader = "00000nam a2200000 a 4500";
	Field f001;
	f001.tag = "001";
	f001.is_control = true;
	f001.control_value = control_number;
	rec.fields.push_back(f001);
	Field f245;
	f245.tag = "245";
	f245.ind1 = "1";
	f245.ind2 = "0";
	f245.subfields.push_back({"a", title});
	rec.fields.push_back(f245);
	return WriteRecord(rec);
}

static bool Contains(const std::string &haystack, const std::string &needle) {
	return haystack.find(needle) != std::string::npos;
}

template <typename Fn>
static std::string CaughtMessage(Fn fn) {
	try {
		fn();
	} catch (const MarcError &e) {
		return e.what();
	}
	return std::string();
}

// ---- BER primitives ---------------------------------------------------------

static void TestBerIntegers() {
	// Minimal-length two's complement forms, checked byte-exact.
	CHECK_EQ(I(0), std::string("\x00", 1));
	CHECK_EQ(I(127), std::string("\x7F"));
	CHECK_EQ(I(128), std::string("\x00\x80", 2));
	CHECK_EQ(I(-1), std::string("\xFF"));
	CHECK_EQ(I(-128), std::string("\x80"));
	CHECK_EQ(I(-129), std::string("\xFF\x7F"));
	CHECK_EQ(I(300), std::string("\x01\x2C"));
	// Round trips including multi-byte and 64-bit extremes.
	const int64_t cases[] = {0,     1,       -1,       127,        128,        255,       256,
	                         -128,  -129,    32767,    -32768,     1 << 20,    4 << 20,   INT32_MAX,
	                         INT32_MIN, INT64_MAX, INT64_MIN, 1234567890123LL, -987654321LL};
	for (int64_t v : cases) {
		CHECK_EQ(ber::ParseIntegerContent(I(v)), v);
	}
	CHECK(!CaughtMessage([] { ber::ParseIntegerContent(""); }).empty());
	CHECK(!CaughtMessage([] { ber::ParseIntegerContent(std::string(9, '\x01')); }).empty());
}

static void TestBerLengths() {
	// Short form.
	CHECK_EQ(Tlv(Class::UNIVERSAL, false, 4, ""), std::string("\x04\x00", 2));
	CHECK_EQ(Tlv(Class::UNIVERSAL, false, 4, "a"), std::string("\x04\x01" "a"));
	std::string s127(127, 'x');
	std::string t127 = Tlv(Class::UNIVERSAL, false, 4, s127);
	CHECK_EQ(t127.size(), 129u);
	CHECK_EQ(static_cast<uint8_t>(t127[1]), 0x7Fu);
	// Long form: 128 -> 81 80, 300 -> 82 01 2C.
	std::string t128 = Tlv(Class::UNIVERSAL, false, 4, std::string(128, 'x'));
	CHECK_EQ(static_cast<uint8_t>(t128[1]), 0x81u);
	CHECK_EQ(static_cast<uint8_t>(t128[2]), 0x80u);
	std::string t300 = Tlv(Class::UNIVERSAL, false, 4, std::string(300, 'x'));
	CHECK_EQ(static_cast<uint8_t>(t300[1]), 0x82u);
	CHECK_EQ(static_cast<uint8_t>(t300[2]), 0x01u);
	CHECK_EQ(static_cast<uint8_t>(t300[3]), 0x2Cu);
	// Round trip through the reader.
	ber::Reader r(t300);
	Tag tag;
	CHECK_EQ(r.Next(tag).size(), 300u);
	CHECK(tag.Is(Class::UNIVERSAL, 4));
	CHECK(r.AtEnd());
}

static void TestBerHighTags() {
	// Low form boundary: context constructed [30] -> BE.
	CHECK_EQ(Tlv(Class::CONTEXT, true, 30, ""), std::string("\xBE\x00", 2));
	// [31] needs the high form: 9F 1F for primitive.
	CHECK_EQ(Tlv(Class::CONTEXT, false, 31, ""), std::string("\x9F\x1F\x00", 3));
	// [102] AttributesPlusTerm: BF 66 (constructed).
	CHECK_EQ(Tlv(Class::CONTEXT, true, 102, ""), std::string("\xBF\x66\x00", 3));
	// [105] DatabaseName: 9F 69.
	CHECK_EQ(Tlv(Class::CONTEXT, false, 105, ""), std::string("\x9F\x69\x00", 3));
	// [211] closeReason: 211 = 1*128 + 83 -> 9F 81 53.
	CHECK_EQ(Tlv(Class::CONTEXT, false, 211, ""), std::string("\x9F\x81\x53\x00", 4));
	// 1016 = 7*128 + 120 -> 9F 87 78.
	CHECK_EQ(Tlv(Class::CONTEXT, false, 1016, ""), std::string("\x9F\x87\x78\x00", 4));
	// Round trips through the reader.
	for (uint32_t n : {30u, 31u, 105u, 120u, 130u, 205u, 211u, 1016u, 100000u}) {
		std::string tlv = Tlv(Class::CONTEXT, false, n, "payload");
		ber::Reader r(tlv);
		Tag tag;
		CHECK_EQ(std::string(r.Next(tag)), std::string("payload"));
		CHECK_EQ(tag.number, n);
		CHECK_EQ(static_cast<int>(tag.cls), static_cast<int>(Class::CONTEXT));
		CHECK(!tag.constructed);
	}
}

// Independent BER OID computation (X.690 8.19) — deliberately NOT via ber::.
static std::string RefOidContent(const std::vector<uint32_t> &arcs) {
	std::vector<uint32_t> subs;
	subs.push_back(arcs[0] * 40 + arcs[1]);
	for (size_t i = 2; i < arcs.size(); i++) {
		subs.push_back(arcs[i]);
	}
	std::string out;
	for (uint32_t v : subs) {
		std::string enc(1, static_cast<char>(v & 0x7F));
		v >>= 7;
		while (v) {
			enc.insert(enc.begin(), static_cast<char>(0x80 | (v & 0x7F)));
			v >>= 7;
		}
		out += enc;
	}
	return out;
}

static void TestBerOid() {
	// USMARC 1.2.840.10003.5.10 must be byte-exact: 2A 86 48 CE 13 05 0A.
	const std::string expect("\x2A\x86\x48\xCE\x13\x05\x0A", 7);
	CHECK_EQ(ber::OidContent(USMARC_OID), expect);
	CHECK_EQ(RefOidContent(USMARC_OID), expect);
	// Bib-1 attribute set and diagnostic set agree with the reference encoder.
	CHECK_EQ(ber::OidContent({1, 2, 840, 10003, 3, 1}), RefOidContent({1, 2, 840, 10003, 3, 1}));
	CHECK_EQ(ber::OidContent(DIAG_BIB1_OID), RefOidContent(DIAG_BIB1_OID));
	// Round trip.
	CHECK(ber::ParseOidContent(ber::OidContent(USMARC_OID)) == USMARC_OID);
	CHECK(ber::ParseOidContent(expect) == USMARC_OID);
	CHECK(!CaughtMessage([] { ber::OidContent({1}); }).empty());
	CHECK(!CaughtMessage([] { ber::ParseOidContent(std::string("\x2A\x86", 2)); }).empty()); // dangling continuation
}

static void TestBerBitString() {
	// search (bit 0) + present (bit 1): one octet C0 with 6 unused bits.
	CHECK_EQ(ber::BitStringContent({0, 1}), std::string("\x06\xC0"));
	// bit 14 (namedResultSets) alone: two octets, 1 unused bit.
	CHECK_EQ(ber::BitStringContent({14}), std::string("\x01\x00\x02", 3));
	CHECK_EQ(ber::BitStringContent({}), std::string("\x00", 1));
}

static void TestFraming() {
	std::string apdu = CS(21, C(12, "\xFF"));
	size_t total = 0;
	// Every strict prefix needs more bytes; the whole thing frames exactly.
	for (size_t cut = 0; cut < apdu.size(); cut++) {
		CHECK(!ber::FrameTlv(apdu.substr(0, cut), total));
	}
	CHECK(ber::FrameTlv(apdu, total));
	CHECK_EQ(total, apdu.size());
	// Concatenated APDUs: framing returns just the first.
	CHECK(ber::FrameTlv(apdu + apdu, total));
	CHECK_EQ(total, apdu.size());
}

static void TestMalformedBer() {
	// Truncated content in the reader.
	{
		ber::Reader r(std::string("\x30\x05\x00", 3)); // claims 5 content bytes, has 1
		Tag tag;
		CHECK(!CaughtMessage([&] { r.Next(tag); }).empty());
	}
	// Indefinite length is rejected with a clear message (documented v1 limit).
	{
		size_t total = 0;
		std::string msg = CaughtMessage([&] { ber::FrameTlv(std::string("\x30\x80\x00\x00", 4), total); });
		CHECK(Contains(msg, "indefinite"));
	}
	// Reader::Expect flags the wrong tag.
	{
		ber::Reader r(C(5, "x"));
		CHECK(!CaughtMessage([&] { r.Expect(Class::CONTEXT, 12); }).empty());
	}
}

// ---- protocol flow ----------------------------------------------------------

static void TestFullSearchFlow() {
	std::string rec1 = FakeIso2709("z001", "Dinosaur bones");
	std::string rec2 = FakeIso2709("z002", "More dinosaur bones");
	MockTransport t;
	// Init + Search responses arrive concatenated in ONE Recv (buffering test).
	t.script.push_back(InitResponseApdu(true) + SearchResponseApdu(2, true));
	t.script.push_back(PresentResponseApdu({rec1, rec2}, 3));

	Z3950Result res = Z3950Search(t, "Voyager", "@attr 1=4 \"dinosaur bones\"", 10);
	CHECK_EQ(res.hit_count, 2);
	CHECK_EQ(res.raw_records.size(), 2u);
	// The transported bytes parse back as MARC and kept their content.
	Record parsed1 = ParseRecord(res.raw_records[0], Encoding::AUTO);
	Record parsed2 = ParseRecord(res.raw_records[1], Encoding::AUTO);
	CHECK_EQ(*parsed1.ControlNumber(), std::string("z001"));
	CHECK_EQ(*parsed2.ControlNumber(), std::string("z002"));
	CHECK_EQ(parsed2.fields[1].subfields[0].value, std::string("More dinosaur bones"));

	// What the client sent: Init [20], Search [22], Present [24].
	CHECK_EQ(t.sent.size(), 3u);
	CHECK_EQ(static_cast<uint8_t>(t.sent[0][0]), 0xB4u); // context constructed 20
	CHECK_EQ(static_cast<uint8_t>(t.sent[1][0]), 0xB6u); // context constructed 22
	CHECK_EQ(static_cast<uint8_t>(t.sent[2][0]), 0xB8u); // context constructed 24
	// SearchRequest carries the title use attribute, the term, the database
	// name and the USMARC preferred syntax — checked as embedded TLV bytes.
	const std::string &sr = t.sent[1];
	CHECK(Contains(sr, C(120, I(1))));               // attributeType 1 (use)
	CHECK(Contains(sr, C(121, I(4))));               // attributeValue 4 (title)
	CHECK(Contains(sr, C(45, "dinosaur bones")));    // Term general
	CHECK(Contains(sr, C(105, "Voyager")));          // DatabaseName
	CHECK(Contains(sr, C(104, ber::OidContent(USMARC_OID))));
	CHECK(Contains(sr, C(17, "default")));           // resultSetName
	// PresentRequest asks for records 1..2 in USMARC.
	const std::string &pr = t.sent[2];
	CHECK(Contains(pr, C(30, I(1))));
	CHECK(Contains(pr, C(29, I(2))));
	CHECK(Contains(pr, C(31, "default")));
	CHECK(Contains(pr, C(104, ber::OidContent(USMARC_OID))));
}

static void TestBareTermUsesAny() {
	MockTransport t;
	t.script.push_back(InitResponseApdu(true));
	t.script.push_back(SearchResponseApdu(0, true));
	Z3950Result res = Z3950Search(t, "Voyager", "  dinosaurs  ", 5);
	CHECK_EQ(res.hit_count, 0);
	CHECK_EQ(res.raw_records.size(), 0u);
	CHECK_EQ(t.sent.size(), 2u); // zero hits: no Present issued
	CHECK(Contains(t.sent[1], C(121, I(1016)))); // Bib-1 use "any"
	CHECK(Contains(t.sent[1], C(45, "dinosaurs")));
}

static void TestIsbnAttrAndHitCountOnly() {
	MockTransport t;
	t.script.push_back(InitResponseApdu(true));
	t.script.push_back(SearchResponseApdu(17, true));
	// max_records = 0: hit count only, no Present.
	Z3950Result res = Z3950Search(t, "db", "@attr 1=7 0316769487", 0);
	CHECK_EQ(res.hit_count, 17);
	CHECK_EQ(res.raw_records.size(), 0u);
	CHECK_EQ(t.sent.size(), 2u);
	CHECK(Contains(t.sent[1], C(121, I(7))));
	CHECK(Contains(t.sent[1], C(45, "0316769487")));
}

static void TestPresentChunking() {
	// 25 hits, 12 wanted -> Present of 10 from position 1, then 2 from 11.
	std::vector<std::string> first, second;
	for (int i = 0; i < 10; i++) {
		first.push_back(FakeIso2709("c" + std::to_string(i), "T"));
	}
	second.push_back(FakeIso2709("c10", "T"));
	second.push_back(FakeIso2709("c11", "T"));
	MockTransport t;
	t.script.push_back(InitResponseApdu(true));
	t.script.push_back(SearchResponseApdu(25, true));
	t.script.push_back(PresentResponseApdu(first, 11));
	t.script.push_back(PresentResponseApdu(second, 13));
	Z3950Result res = Z3950Search(t, "db", "term", 12);
	CHECK_EQ(res.hit_count, 25);
	CHECK_EQ(res.raw_records.size(), 12u);
	CHECK_EQ(t.sent.size(), 4u);
	CHECK(Contains(t.sent[2], C(30, I(1))));
	CHECK(Contains(t.sent[2], C(29, I(10))));
	CHECK(Contains(t.sent[3], C(30, I(11))));
	CHECK(Contains(t.sent[3], C(29, I(2))));
	CHECK_EQ(*ParseRecord(res.raw_records[11], Encoding::AUTO).ControlNumber(), std::string("c11"));
}

static void TestInitRejected() {
	MockTransport t;
	t.script.push_back(InitResponseApdu(false));
	std::string msg = CaughtMessage([&] { Z3950Search(t, "db", "term", 5); });
	CHECK(Contains(msg, "rejected"));
}

static void TestWrongApduTag() {
	MockTransport t;
	// Server answers Init with a SearchResponse-tagged PDU.
	t.script.push_back(SearchResponseApdu(1, true));
	std::string msg = CaughtMessage([&] { Z3950Search(t, "db", "term", 5); });
	CHECK(Contains(msg, "expected InitResponse"));
	CHECK(Contains(msg, "[23]"));
}

static void TestTruncatedApdu() {
	MockTransport t;
	std::string apdu = InitResponseApdu(true);
	t.script.push_back(apdu.substr(0, apdu.size() - 3)); // then Recv() returns "" = closed
	std::string msg = CaughtMessage([&] { Z3950Search(t, "db", "term", 5); });
	CHECK(Contains(msg, "closed before a complete APDU"));
}

static void TestIndefiniteLengthApdu() {
	MockTransport t;
	t.script.push_back(std::string("\xB5\x80\x00\x00", 4)); // [21] with indefinite length
	std::string msg = CaughtMessage([&] { Z3950Search(t, "db", "term", 5); });
	CHECK(Contains(msg, "indefinite"));
}

static void TestSearchDiagnostic() {
	MockTransport t;
	t.script.push_back(InitResponseApdu(true));
	// searchStatus false + nonSurrogateDiagnostic [130] (implicit DefaultDiagFormat).
	std::string body;
	body += C(23, I(0));
	body += C(24, I(0));
	body += C(25, I(1));
	body += C(22, std::string_view("\x00", 1));
	body += CS(130, DefaultDiagContent(114, "Unsupported Use attribute"));
	t.script.push_back(CS(23, body));
	std::string msg = CaughtMessage([&] { Z3950Search(t, "db", "term", 5); });
	CHECK(Contains(msg, "114"));
	CHECK(Contains(msg, "Unsupported Use attribute"));
}

static void TestSurrogateDiagnostic() {
	MockTransport t;
	t.script.push_back(InitResponseApdu(true));
	t.script.push_back(SearchResponseApdu(1, true));
	// NamePlusRecord { record [1] { surrogateDiagnostic [2] { SEQUENCE DefaultDiagFormat } } }
	std::string nprec = US(CS(1, CS(2, US(DefaultDiagContent(238, "Record not available in USMARC")))));
	t.script.push_back(PresentResponseApdu({std::string("x")}, 2, CS(28, nprec)));
	std::string msg = CaughtMessage([&] { Z3950Search(t, "db", "term", 5); });
	CHECK(Contains(msg, "surrogate"));
	CHECK(Contains(msg, "238"));
	CHECK(Contains(msg, "Record not available in USMARC"));
}

static void TestCloseApdu() {
	MockTransport t;
	t.script.push_back(InitResponseApdu(true));
	// Close [48] with closeReason [211] = 6 (protocol error).
	t.script.push_back(CS(48, C(211, I(6))));
	std::string msg = CaughtMessage([&] { Z3950Search(t, "db", "term", 5); });
	CHECK(Contains(msg, "closed the association"));
	CHECK(Contains(msg, "protocol error"));
}

static void TestWrongRecordSyntax() {
	MockTransport t;
	t.script.push_back(InitResponseApdu(true));
	t.script.push_back(SearchResponseApdu(1, true));
	// EXTERNAL whose direct-reference is SUTRS (1.2.840.10003.5.101), not USMARC.
	std::string external = UOid({1, 2, 840, 10003, 5, 101}) + C(1, "not marc");
	std::string nprec = US(CS(1, CS(1, external)));
	t.script.push_back(PresentResponseApdu({std::string("x")}, 2, CS(28, nprec)));
	std::string msg = CaughtMessage([&] { Z3950Search(t, "db", "term", 5); });
	CHECK(Contains(msg, "not USMARC"));
	CHECK(Contains(msg, "1.2.840.10003.5.101"));
}

static void TestQueryLanguageErrors() {
	MockTransport t; // never reached: parsing fails before any Send
	CHECK(!CaughtMessage([&] { Z3950Search(t, "db", "", 5); }).empty());
	CHECK(!CaughtMessage([&] { Z3950Search(t, "db", "@attr 1=4", 5); }).empty());          // no term
	CHECK(!CaughtMessage([&] { Z3950Search(t, "db", "@attr nope term", 5); }).empty());    // bad attr
	CHECK(!CaughtMessage([&] { Z3950Search(t, "db", "@attr 1=4 \"open", 5); }).empty());   // unterminated
	CHECK(Contains(CaughtMessage([&] { Z3950Search(t, "db", "@attr 1=4 \"a\" junk", 5); }), "after quoted term"));
	CHECK_EQ(t.sent.size(), 0u);
}

int main() {
	TestBerIntegers();
	TestBerLengths();
	TestBerHighTags();
	TestBerOid();
	TestBerBitString();
	TestFraming();
	TestMalformedBer();
	TestFullSearchFlow();
	TestBareTermUsesAny();
	TestIsbnAttrAndHitCountOnly();
	TestPresentChunking();
	TestInitRejected();
	TestWrongApduTag();
	TestTruncatedApdu();
	TestIndefiniteLengthApdu();
	TestSearchDiagnostic();
	TestSurrogateDiagnostic();
	TestCloseApdu();
	TestWrongRecordSyntax();
	TestQueryLanguageErrors();
	return CHECKS_MAIN_RESULT();
}
