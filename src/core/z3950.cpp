//! Z39.50-1995 client core: BER subset + the five APDUs needed for
//! Init/Search/Present.  Written from the standard's ASN.1; every tag and
//! OID assignment used is listed below with a confidence note.  See
//! marc/z3950.hpp for the v1 limitations.
//!
//! ASN.1 shapes relied on (Z39.50-1995 APDU definitions; all component tags
//! are context-specific IMPLICIT unless noted, and a tag placed on a CHOICE
//! type is necessarily EXPLICIT — a constructed wrapper around the chosen
//! alternative's own TLV):
//!
//!   PDU ::= CHOICE { initRequest [20], initResponse [21], searchRequest [22],
//!     searchResponse [23], presentRequest [24], presentResponse [25], ...,
//!     close [48] }                                        -- high confidence
//!   InitializeRequest ::= SEQUENCE { referenceId [2] OPTIONAL,
//!     protocolVersion [3] BIT STRING, options [4] BIT STRING,
//!     preferredMessageSize [5] INTEGER, exceptionalRecordSize [6] INTEGER,
//!     idAuthentication [7] OPTIONAL, implementationId [110],
//!     implementationName [111], implementationVersion [112], ... }
//!                                                         -- high confidence
//!   InitializeResponse ::= like the request plus result [12] BOOLEAN
//!                                                         -- high confidence
//!   SearchRequest ::= SEQUENCE { referenceId OPTIONAL,
//!     smallSetUpperBound [13] INTEGER, largeSetLowerBound [14] INTEGER,
//!     mediumSetPresentNumber [15] INTEGER, replaceIndicator [16] BOOLEAN,
//!     resultSetName [17] InternationalString,
//!     databaseNames [18] SEQUENCE OF DatabaseName,
//!     -- DatabaseName ::= [105] IMPLICIT InternationalString
//!     smallSetElementSetNames [100] OPTIONAL, mediumSet... [101] OPTIONAL,
//!     preferredRecordSyntax [104] OBJECT IDENTIFIER OPTIONAL,
//!     query [21] Query, ... }        -- high confidence except [100]/[101],
//!                                       which we never emit (medium)
//!   Query ::= CHOICE { ..., type-1 [1] IMPLICIT RPNQuery, ... }
//!   RPNQuery ::= SEQUENCE { attributeSet OBJECT IDENTIFIER, rpn RPNStructure }
//!   RPNStructure ::= CHOICE { op [0] Operand (EXPLICIT: tags a CHOICE),
//!     rpnRpnOp [1] SEQUENCE {...} (unused here) }
//!   Operand ::= CHOICE { attrTerm AttributesPlusTerm, resultSet ResultSetId,
//!     resultAttr [214] ... }
//!   AttributesPlusTerm ::= [102] IMPLICIT SEQUENCE {
//!     attributes AttributeList, term Term }
//!   AttributeList ::= [44] IMPLICIT SEQUENCE OF SEQUENCE {
//!     attributeSet [1] OPTIONAL, attributeType [120] INTEGER,
//!     attributeValue CHOICE { numeric [121] INTEGER, complex [224] ... } }
//!   Term ::= CHOICE { general [45] IMPLICIT OCTET STRING, ... }
//!                              -- [1]/[0]/[102]/[44]/[120]/[121]/[45]: high
//!                                 confidence; [214]/[224]: medium, unused
//!   SearchResponse ::= SEQUENCE { referenceId OPTIONAL,
//!     resultCount [23] INTEGER, numberOfRecordsReturned [24] INTEGER,
//!     nextResultSetPosition [25] INTEGER, searchStatus [22] BOOLEAN,
//!     resultSetStatus [26] OPTIONAL, presentStatus [27] OPTIONAL,
//!     records Records OPTIONAL, ... }                     -- high confidence
//!   PresentRequest ::= SEQUENCE { referenceId OPTIONAL,
//!     resultSetId ResultSetId,  -- ResultSetId ::= [31] InternationalString
//!     resultSetStartPoint [30] INTEGER,
//!     numberOfRecordsRequested [29] INTEGER, ...,
//!     preferredRecordSyntax [104] OPTIONAL, ... }         -- high confidence
//!   PresentResponse ::= SEQUENCE { referenceId OPTIONAL,
//!     numberOfRecordsReturned [24] INTEGER,
//!     nextResultSetPosition [25] INTEGER,
//!     presentStatus [27] INTEGER (0 = success),
//!     records Records OPTIONAL, ... }                     -- high confidence
//!   Records ::= CHOICE { responseRecords [28] SEQUENCE OF NamePlusRecord,
//!     nonSurrogateDiagnostic [130] DefaultDiagFormat,
//!     multipleNonSurDiagnostics [205] SEQUENCE OF DiagRec }
//!                      -- [28] high confidence; [130]/[205] medium-high
//!   NamePlusRecord ::= SEQUENCE { name [0] DatabaseName OPTIONAL,
//!     record [1] CHOICE (EXPLICIT) { retrievalRecord [1] EXTERNAL,
//!       surrogateDiagnostic [2] DiagRec (EXPLICIT: tags a CHOICE) } }
//!                                                         -- high confidence
//!   DiagRec ::= CHOICE { defaultFormat DefaultDiagFormat (a plain SEQUENCE),
//!     externallyDefined EXTERNAL }
//!   DefaultDiagFormat ::= SEQUENCE { diagnosticSetId OBJECT IDENTIFIER,
//!     condition INTEGER, addinfo (VisibleString or InternationalString) }
//!                                                         -- high confidence
//!   EXTERNAL (X.690/X.208 universal 8) ::= SEQUENCE {
//!     direct-reference OBJECT IDENTIFIER OPTIONAL,
//!     indirect-reference INTEGER OPTIONAL,
//!     data-value-descriptor ObjectDescriptor OPTIONAL,
//!     encoding CHOICE { single-ASN1-type [0], octet-aligned [1] OCTET
//!       STRING, arbitrary [2] BIT STRING } }              -- high confidence
//!   Close ::= SEQUENCE { referenceId OPTIONAL, closeReason [211] INTEGER,
//!     diagnosticInformation [3] InternationalString OPTIONAL, ... }
//!                                                         -- [211] medium
//!
//! OIDs (high confidence; USMARC verified byte-exact in the tests):
//!   Bib-1 attribute set   1.2.840.10003.3.1
//!   Bib-1 diagnostic set  1.2.840.10003.4.1
//!   USMARC record syntax  1.2.840.10003.5.10
#include "marc/z3950.hpp"

#include <algorithm>

namespace marc {
namespace ber {

// ---- encoding --------------------------------------------------------------

void AppendTag(std::string &out, Class cls, bool constructed, uint32_t number) {
	uint8_t head = static_cast<uint8_t>((static_cast<uint8_t>(cls) << 6) | (constructed ? 0x20 : 0x00));
	if (number < 31) {
		out.push_back(static_cast<char>(head | number));
		return;
	}
	out.push_back(static_cast<char>(head | 0x1F));
	uint8_t sub[5];
	int n = 0;
	uint32_t v = number;
	do {
		sub[n++] = static_cast<uint8_t>(v & 0x7F);
		v >>= 7;
	} while (v);
	for (int i = n - 1; i >= 0; i--) {
		out.push_back(static_cast<char>(sub[i] | (i ? 0x80 : 0x00)));
	}
}

void AppendLength(std::string &out, size_t length) {
	if (length < 128) {
		out.push_back(static_cast<char>(length));
		return;
	}
	uint8_t bytes[sizeof(size_t)];
	int n = 0;
	size_t v = length;
	while (v) {
		bytes[n++] = static_cast<uint8_t>(v & 0xFF);
		v >>= 8;
	}
	out.push_back(static_cast<char>(0x80 | n));
	for (int i = n - 1; i >= 0; i--) {
		out.push_back(static_cast<char>(bytes[i]));
	}
}

std::string Tlv(Class cls, bool constructed, uint32_t number, std::string_view content) {
	std::string out;
	out.reserve(content.size() + 6);
	AppendTag(out, cls, constructed, number);
	AppendLength(out, content.size());
	out.append(content);
	return out;
}

std::string IntegerContent(int64_t value) {
	uint64_t u = static_cast<uint64_t>(value);
	int n = 8;
	// Strip redundant leading octets (all-zero before a clear bit 8, all-one
	// before a set bit 8) down to the minimal two's-complement form.
	while (n > 1) {
		uint8_t top = static_cast<uint8_t>(u >> ((n - 1) * 8));
		uint8_t next_msb = static_cast<uint8_t>((u >> ((n - 2) * 8 + 7)) & 1);
		if ((top == 0x00 && next_msb == 0) || (top == 0xFF && next_msb == 1)) {
			n--;
		} else {
			break;
		}
	}
	std::string out;
	for (int i = n - 1; i >= 0; i--) {
		out.push_back(static_cast<char>(u >> (i * 8)));
	}
	return out;
}

std::string OidContent(const std::vector<uint32_t> &arcs) {
	if (arcs.size() < 2 || arcs[0] > 2 || (arcs[0] < 2 && arcs[1] > 39)) {
		throw MarcError("BER OID: need at least two arcs with valid root values");
	}
	std::string out;
	auto put_base128 = [&out](uint32_t v) {
		uint8_t sub[5];
		int n = 0;
		do {
			sub[n++] = static_cast<uint8_t>(v & 0x7F);
			v >>= 7;
		} while (v);
		for (int i = n - 1; i >= 0; i--) {
			out.push_back(static_cast<char>(sub[i] | (i ? 0x80 : 0x00)));
		}
	};
	put_base128(arcs[0] * 40 + arcs[1]);
	for (size_t i = 2; i < arcs.size(); i++) {
		put_base128(arcs[i]);
	}
	return out;
}

std::string BitStringContent(const std::vector<uint32_t> &set_bits) {
	uint32_t max_bit = 0;
	for (uint32_t b : set_bits) {
		max_bit = std::max(max_bit, b);
	}
	std::string out;
	if (set_bits.empty()) {
		out.push_back('\0'); // zero-length bit string: just the unused count
		return out;
	}
	std::string bits(max_bit / 8 + 1, '\0');
	for (uint32_t b : set_bits) {
		bits[b / 8] = static_cast<char>(bits[b / 8] | (0x80 >> (b % 8)));
	}
	out.push_back(static_cast<char>(7 - max_bit % 8));
	out += bits;
	return out;
}

// ---- decoding --------------------------------------------------------------

int64_t ParseIntegerContent(std::string_view content) {
	if (content.empty() || content.size() > 8) {
		throw MarcError("BER INTEGER content is empty or wider than 64 bits");
	}
	uint64_t u = (static_cast<uint8_t>(content[0]) & 0x80) ? ~0ULL : 0;
	for (char c : content) {
		u = (u << 8) | static_cast<uint8_t>(c);
	}
	return static_cast<int64_t>(u);
}

std::vector<uint32_t> ParseOidContent(std::string_view content) {
	if (content.empty()) {
		throw MarcError("BER OID content is empty");
	}
	std::vector<uint32_t> arcs;
	size_t i = 0;
	bool first = true;
	while (i < content.size()) {
		uint32_t v = 0;
		int count = 0;
		while (true) {
			if (i >= content.size()) {
				throw MarcError("BER OID subidentifier is truncated");
			}
			uint8_t o = static_cast<uint8_t>(content[i++]);
			if (++count > 5 || (v >> 25)) {
				throw MarcError("BER OID subidentifier exceeds 32 bits");
			}
			v = (v << 7) | (o & 0x7F);
			if (!(o & 0x80)) {
				break;
			}
		}
		if (first) {
			first = false;
			arcs.push_back(v < 80 ? v / 40 : 2);
			arcs.push_back(v < 80 ? v % 40 : v - 80);
		} else {
			arcs.push_back(v);
		}
	}
	return arcs;
}

//! Parse identifier + length octets at the start of `data`.  Returns false
//! when more bytes are needed to complete the header; throws on indefinite
//! length and other malformed headers.
static bool TryHeader(std::string_view data, Tag &tag, size_t &content_off, size_t &content_len) {
	size_t pos = 0;
	if (data.empty()) {
		return false;
	}
	uint8_t b = static_cast<uint8_t>(data[pos++]);
	tag.cls = static_cast<Class>(b >> 6);
	tag.constructed = (b & 0x20) != 0;
	uint32_t num = b & 0x1F;
	if (num == 0x1F) { // high-tag-number form
		num = 0;
		while (true) {
			if (pos >= data.size()) {
				return false;
			}
			uint8_t o = static_cast<uint8_t>(data[pos++]);
			if (num >> 25) {
				throw MarcError("BER tag number exceeds 32 bits");
			}
			num = (num << 7) | (o & 0x7F);
			if (!(o & 0x80)) {
				break;
			}
		}
	}
	tag.number = num;
	if (pos >= data.size()) {
		return false;
	}
	uint8_t l = static_cast<uint8_t>(data[pos++]);
	if (l == 0x80) {
		throw MarcError("BER indefinite length is unsupported (v1 handles definite-length encodings only)");
	}
	if (l < 0x80) {
		content_len = l;
	} else {
		int n = l & 0x7F;
		if (n > 8) {
			throw MarcError("BER length exceeds 64 bits");
		}
		if (pos + static_cast<size_t>(n) > data.size()) {
			return false;
		}
		size_t v = 0;
		for (int i = 0; i < n; i++) {
			v = (v << 8) | static_cast<uint8_t>(data[pos++]);
		}
		content_len = v;
	}
	content_off = pos;
	return true;
}

bool FrameTlv(std::string_view buffer, size_t &total_length) {
	Tag tag;
	size_t off = 0, len = 0;
	if (!TryHeader(buffer, tag, off, len)) {
		return false;
	}
	if (len > buffer.size() - off) {
		return false;
	}
	total_length = off + len;
	return true;
}

Tag Reader::Peek() const {
	Tag tag;
	size_t off = 0, len = 0;
	if (!TryHeader(data_.substr(pos_), tag, off, len)) {
		throw MarcError("truncated BER element header");
	}
	return tag;
}

std::string_view Reader::Next(Tag &tag) {
	std::string_view rest = data_.substr(pos_);
	size_t off = 0, len = 0;
	if (!TryHeader(rest, tag, off, len) || len > rest.size() - off) {
		throw MarcError("truncated BER element");
	}
	pos_ += off + len;
	return rest.substr(off, len);
}

std::string_view Reader::Expect(Class cls, uint32_t number) {
	Tag tag;
	std::string_view content = Next(tag);
	if (!tag.Is(cls, number)) {
		throw MarcError("unexpected BER tag [" + std::to_string(tag.number) + "] (class " +
		                std::to_string(static_cast<int>(tag.cls)) + "), expected [" + std::to_string(number) + "]");
	}
	return content;
}

bool Reader::NextIf(Class cls, uint32_t number, std::string_view &content) {
	if (AtEnd() || !Peek().Is(cls, number)) {
		return false;
	}
	Tag tag;
	content = Next(tag);
	return true;
}

} // namespace ber

// ---- Z39.50 client ---------------------------------------------------------

using ber::Class;
using ber::Reader;
using ber::Tag;
using ber::Tlv;

namespace {

// PDU choice tags (see the file-top ASN.1 notes for confidence).
constexpr uint32_t APDU_INIT_REQUEST = 20;
constexpr uint32_t APDU_INIT_RESPONSE = 21;
constexpr uint32_t APDU_SEARCH_REQUEST = 22;
constexpr uint32_t APDU_SEARCH_RESPONSE = 23;
constexpr uint32_t APDU_PRESENT_REQUEST = 24;
constexpr uint32_t APDU_PRESENT_RESPONSE = 25;
constexpr uint32_t APDU_CLOSE = 48;

const std::vector<uint32_t> OID_BIB1_ATTRIBUTES = {1, 2, 840, 10003, 3, 1};
const std::vector<uint32_t> OID_USMARC_SYNTAX = {1, 2, 840, 10003, 5, 10};

//! Records are pulled in Present chunks of at most this many.
constexpr int64_t PRESENT_CHUNK = 10;

// Context-specific implicit-tag helpers.
std::string Ctx(uint32_t number, std::string_view content) {
	return Tlv(Class::CONTEXT, false, number, content);
}
std::string CtxSeq(uint32_t number, std::string_view content) {
	return Tlv(Class::CONTEXT, true, number, content);
}
std::string CtxInt(uint32_t number, int64_t value) {
	return Ctx(number, ber::IntegerContent(value));
}
std::string CtxBool(uint32_t number, bool value) {
	return Ctx(number, value ? std::string_view("\xFF", 1) : std::string_view("\x00", 1));
}
std::string UnivOid(const std::vector<uint32_t> &arcs) {
	return Tlv(Class::UNIVERSAL, false, ber::TAG_OID, ber::OidContent(arcs));
}
std::string UnivSeq(std::string_view content) {
	return Tlv(Class::UNIVERSAL, true, ber::TAG_SEQUENCE, content);
}

bool ParseBooleanContent(std::string_view content) {
	if (content.size() != 1) {
		throw MarcError("BER BOOLEAN content must be one octet");
	}
	return content[0] != 0;
}

std::string OidToText(const std::vector<uint32_t> &arcs) {
	std::string out;
	for (uint32_t a : arcs) {
		if (!out.empty()) {
			out += '.';
		}
		out += std::to_string(a);
	}
	return out;
}

// ---- query language ---------------------------------------------------------

struct RpnTerm {
	std::vector<std::pair<int64_t, int64_t>> attributes; // (type, value), numeric only
	std::string term;
};

void SkipSpaces(std::string_view &s) {
	while (!s.empty() && (s.front() == ' ' || s.front() == '\t')) {
		s.remove_prefix(1);
	}
}

bool ParseUnsigned(std::string_view &s, int64_t &out) {
	size_t n = 0;
	int64_t v = 0;
	while (n < s.size() && s[n] >= '0' && s[n] <= '9') {
		if (v > (INT64_MAX - 9) / 10) {
			return false;
		}
		v = v * 10 + (s[n] - '0');
		n++;
	}
	if (n == 0) {
		return false;
	}
	s.remove_prefix(n);
	out = v;
	return true;
}

//! See the query-language grammar in z3950.hpp.
RpnTerm ParseQueryString(const std::string &query) {
	RpnTerm out;
	std::string_view s = query;
	SkipSpaces(s);
	while (s.substr(0, 5) == "@attr" && (s.size() == 5 || s[5] == ' ' || s[5] == '\t')) {
		s.remove_prefix(5);
		SkipSpaces(s);
		int64_t type = 0, value = 0;
		if (!ParseUnsigned(s, type) || s.empty() || s.front() != '=') {
			throw MarcError("Z39.50 query: @attr expects 'type=value' with unsigned integers");
		}
		s.remove_prefix(1);
		if (!ParseUnsigned(s, value)) {
			throw MarcError("Z39.50 query: @attr expects 'type=value' with unsigned integers");
		}
		out.attributes.emplace_back(type, value);
		SkipSpaces(s);
	}
	if (!s.empty() && s.front() == '"') {
		size_t close = s.find('"', 1);
		if (close == std::string_view::npos) {
			throw MarcError("Z39.50 query: unterminated quoted term");
		}
		out.term = std::string(s.substr(1, close - 1));
		s.remove_prefix(close + 1);
		SkipSpaces(s);
		if (!s.empty()) {
			throw MarcError("Z39.50 query: unexpected text after quoted term");
		}
	} else {
		// Bare term: rest of the string, trailing whitespace trimmed.
		while (!s.empty() && (s.back() == ' ' || s.back() == '\t')) {
			s.remove_suffix(1);
		}
		out.term = std::string(s);
	}
	if (out.term.empty()) {
		throw MarcError("Z39.50 query: empty search term");
	}
	if (out.attributes.empty()) {
		out.attributes.emplace_back(1, 1016); // bare term: Bib-1 use "any"
	}
	return out;
}

// ---- APDU builders ----------------------------------------------------------

std::string BuildInitRequest() {
	std::string body;
	body += Ctx(3, ber::BitStringContent({0, 1}));  // protocolVersion: version-1 + version-2
	body += Ctx(4, ber::BitStringContent({0, 1}));  // options: search (bit 0) + present (bit 1)
	body += CtxInt(5, 1 << 20);                     // preferredMessageSize: 1 MiB
	body += CtxInt(6, 4 << 20);                     // exceptionalRecordSize: 4 MiB
	body += Ctx(110, "81");                         // implementationId (arbitrary local id)
	body += Ctx(111, "marc21 duckdb extension z3950 core"); // implementationName
	body += Ctx(112, "0.1");                        // implementationVersion
	return CtxSeq(APDU_INIT_REQUEST, body);
}

std::string BuildRpnQueryContent(const RpnTerm &q) {
	std::string attr_list;
	for (const auto &attr : q.attributes) {
		// AttributeElement ::= SEQUENCE { attributeType [120], numeric [121] }
		attr_list += UnivSeq(CtxInt(120, attr.first) + CtxInt(121, attr.second));
	}
	// AttributesPlusTerm [102] { AttributeList [44], Term general [45] }
	std::string apt = CtxSeq(102, CtxSeq(44, attr_list) + Ctx(45, q.term));
	// RPNQuery ::= SEQUENCE { attributeSet OID, rpn op [0] (EXPLICIT) }
	return UnivOid(OID_BIB1_ATTRIBUTES) + CtxSeq(0, apt);
}

std::string BuildSearchRequest(const std::string &database, const RpnTerm &q) {
	std::string body;
	body += CtxInt(13, 0);                          // smallSetUpperBound
	body += CtxInt(14, 1);                          // largeSetLowerBound
	body += CtxInt(15, 0);                          // mediumSetPresentNumber
	body += CtxBool(16, true);                      // replaceIndicator
	body += Ctx(17, "default");                     // resultSetName
	body += CtxSeq(18, Ctx(105, database));         // databaseNames: SEQUENCE OF [105]
	body += Ctx(104, ber::OidContent(OID_USMARC_SYNTAX)); // preferredRecordSyntax
	// query [21] EXPLICIT { type-1 [1] IMPLICIT RPNQuery }
	body += CtxSeq(21, CtxSeq(1, BuildRpnQueryContent(q)));
	return CtxSeq(APDU_SEARCH_REQUEST, body);
}

std::string BuildPresentRequest(int64_t start, int64_t count) {
	std::string body;
	body += Ctx(31, "default");                     // resultSetId
	body += CtxInt(30, start);                      // resultSetStartPoint (1-based)
	body += CtxInt(29, count);                      // numberOfRecordsRequested
	body += Ctx(104, ber::OidContent(OID_USMARC_SYNTAX)); // preferredRecordSyntax
	return CtxSeq(APDU_PRESENT_REQUEST, body);
}

// ---- APDU parsing -----------------------------------------------------------

//! DefaultDiagFormat content -> readable text.  `context` names the phase.
std::string FormatDefaultDiag(const char *context, std::string_view seq_content) {
	Reader r(seq_content);
	std::string msg = std::string("Z39.50 ") + context + " diagnostic";
	std::string_view part;
	if (r.NextIf(Class::UNIVERSAL, ber::TAG_OID, part)) {
		// diagnosticSetId noted only when it is not Bib-1.
		auto arcs = ber::ParseOidContent(part);
		if (arcs != std::vector<uint32_t> {1, 2, 840, 10003, 4, 1}) {
			msg += " (set " + OidToText(arcs) + ")";
		}
	}
	if (r.NextIf(Class::UNIVERSAL, ber::TAG_INTEGER, part)) {
		msg += " " + std::to_string(ber::ParseIntegerContent(part));
	}
	// addinfo: v2 VisibleString or v3 InternationalString (GeneralString);
	// accept any remaining primitive string-ish element.
	if (!r.AtEnd()) {
		Tag t;
		std::string_view add = r.Next(t);
		if (!t.constructed && !add.empty()) {
			msg += ": " + std::string(add);
		}
	}
	return msg;
}

//! One DiagRec CHOICE TLV (already read) -> text.
std::string FormatDiagRec(const char *context, const Tag &tag, std::string_view content) {
	if (tag.Is(Class::UNIVERSAL, ber::TAG_SEQUENCE)) {
		return FormatDefaultDiag(context, content);
	}
	return std::string("Z39.50 ") + context + " diagnostic in an externally-defined format (unsupported)";
}

//! A wrapper whose content is exactly one DiagRec (e.g. surrogateDiagnostic).
std::string FormatWrappedDiagRec(const char *context, std::string_view wrapped) {
	Reader r(wrapped);
	Tag tag;
	std::string_view content = r.Next(tag);
	return FormatDiagRec(context, tag, content);
}

//! EXTERNAL content octets -> the transported USMARC/ISO 2709 bytes.  Accepts
//! either the EXTERNAL's own content (implicit tagging, the expected form) or
//! a nested universal-8 TLV (a peer that tagged the CHOICE explicitly).
std::string ParseExternalRecord(std::string_view ext) {
	Reader r(ext);
	if (!r.AtEnd() && r.Peek().Is(Class::UNIVERSAL, ber::TAG_EXTERNAL)) {
		Tag t;
		return ParseExternalRecord(r.Next(t));
	}
	std::string_view part;
	if (r.NextIf(Class::UNIVERSAL, ber::TAG_OID, part)) { // direct-reference
		auto arcs = ber::ParseOidContent(part);
		if (arcs != OID_USMARC_SYNTAX) {
			throw MarcError("Z39.50: record syntax " + OidToText(arcs) + " is not USMARC (1.2.840.10003.5.10)");
		}
	}
	r.NextIf(Class::UNIVERSAL, ber::TAG_INTEGER, part);           // indirect-reference (ignored)
	r.NextIf(Class::UNIVERSAL, ber::TAG_OBJECT_DESCRIPTOR, part); // data-value-descriptor (ignored)
	if (r.AtEnd()) {
		throw MarcError("Z39.50: EXTERNAL record without an encoding");
	}
	Tag t;
	std::string_view enc = r.Next(t);
	if (t.cls == Class::CONTEXT && t.number == 1) { // octet-aligned OCTET STRING
		return std::string(enc);
	}
	if (t.cls == Class::CONTEXT && t.number == 0) { // single-ASN1-type: expect an OCTET STRING inside
		Reader inner(enc);
		Tag it;
		std::string_view ic = inner.Next(it);
		if (it.Is(Class::UNIVERSAL, ber::TAG_OCTET_STRING)) {
			return std::string(ic);
		}
		throw MarcError("Z39.50: single-ASN1-type EXTERNAL encoding is not an OCTET STRING");
	}
	if (t.cls == Class::CONTEXT && t.number == 2) { // arbitrary BIT STRING: usable when byte-aligned
		if (!enc.empty() && enc[0] == 0) {
			return std::string(enc.substr(1));
		}
		throw MarcError("Z39.50: arbitrary (bit-string) EXTERNAL encoding is not byte-aligned");
	}
	throw MarcError("Z39.50: unsupported EXTERNAL encoding choice [" + std::to_string(t.number) + "]");
}

//! NamePlusRecord SEQUENCE content: append the retrieval record's octets, or
//! throw the surrogate diagnostic.
void ParseNamePlusRecord(std::string_view seq_content, std::vector<std::string> &out) {
	Reader r(seq_content);
	std::string_view skip;
	r.NextIf(Class::CONTEXT, 0, skip);                          // name [0] OPTIONAL
	std::string_view rec = r.Expect(Class::CONTEXT, 1);         // record [1] (EXPLICIT CHOICE)
	Reader choice(rec);
	if (choice.AtEnd()) {
		throw MarcError("Z39.50: empty record choice in NamePlusRecord");
	}
	if (choice.Peek().cls == Class::UNIVERSAL) {
		// Lenient: a peer that collapsed the explicit wrapper (content is the
		// EXTERNAL itself, or its guts starting at the OID).
		out.push_back(ParseExternalRecord(rec));
		return;
	}
	Tag t;
	std::string_view inner = choice.Next(t);
	if (t.number == 1) { // retrievalRecord [1] EXTERNAL
		out.push_back(ParseExternalRecord(inner));
		return;
	}
	if (t.number == 2) { // surrogateDiagnostic [2] DiagRec
		throw MarcError(FormatWrappedDiagRec("surrogate", inner));
	}
	throw MarcError("Z39.50: unrecognised record choice tag [" + std::to_string(t.number) + "]");
}

//! Handle a Records CHOICE TLV from a Search/Present response: append records
//! for responseRecords, throw MarcError for the diagnostic alternatives.
void ParseRecordsChoice(const char *context, const Tag &tag, std::string_view content,
                        std::vector<std::string> &out) {
	if (tag.Is(Class::CONTEXT, 28)) { // responseRecords: SEQUENCE OF NamePlusRecord
		Reader r(content);
		while (!r.AtEnd()) {
			Tag t;
			std::string_view seq = r.Next(t);
			if (!t.Is(Class::UNIVERSAL, ber::TAG_SEQUENCE)) {
				throw MarcError("Z39.50: expected a NamePlusRecord SEQUENCE in responseRecords");
			}
			ParseNamePlusRecord(seq, out);
		}
		return;
	}
	if (tag.Is(Class::CONTEXT, 130)) { // nonSurrogateDiagnostic (implicit DefaultDiagFormat)
		throw MarcError(FormatDefaultDiag(context, content));
	}
	if (tag.Is(Class::CONTEXT, 205)) { // multipleNonSurDiagnostics: SEQUENCE OF DiagRec
		Reader r(content);
		std::string msg;
		while (!r.AtEnd()) {
			Tag t;
			std::string_view c = r.Next(t);
			if (!msg.empty()) {
				msg += "; ";
			}
			msg += FormatDiagRec(context, t, c);
		}
		throw MarcError(msg.empty() ? std::string("Z39.50 ") + context + " diagnostic (no detail)" : msg);
	}
	// Unknown alternative: ignore (forward compatibility).
}

void ParseInitResponse(std::string_view body) {
	Reader r(body);
	bool have_result = false, accepted = false;
	while (!r.AtEnd()) {
		Tag t;
		std::string_view c = r.Next(t);
		if (t.Is(Class::CONTEXT, 12)) { // result [12] BOOLEAN
			have_result = true;
			accepted = ParseBooleanContent(c);
		}
	}
	if (!have_result) {
		throw MarcError("Z39.50: InitResponse lacks the result flag");
	}
	if (!accepted) {
		throw MarcError("Z39.50: server rejected initialization");
	}
}

struct SearchOutcome {
	int64_t result_count = -1;
	int64_t next_position = 0;
	bool status = false;
	bool have_status = false;
	std::vector<std::string> piggyback;
};

SearchOutcome ParseSearchResponse(std::string_view body) {
	SearchOutcome out;
	Reader r(body);
	while (!r.AtEnd()) {
		Tag t;
		std::string_view c = r.Next(t);
		if (t.cls != Class::CONTEXT) {
			continue;
		}
		switch (t.number) {
		case 23: // resultCount
			out.result_count = ber::ParseIntegerContent(c);
			break;
		case 25: // nextResultSetPosition
			out.next_position = ber::ParseIntegerContent(c);
			break;
		case 22: // searchStatus
			out.status = ParseBooleanContent(c);
			out.have_status = true;
			break;
		default:
			ParseRecordsChoice("search", t, c, out.piggyback); // throws on diagnostics
			break;
		}
	}
	if (!out.have_status || out.result_count < 0) {
		throw MarcError("Z39.50: SearchResponse lacks searchStatus or resultCount");
	}
	if (!out.status) {
		throw MarcError("Z39.50: search failed (searchStatus false, no diagnostic supplied)");
	}
	return out;
}

struct PresentOutcome {
	int64_t returned = 0;
	int64_t next_position = 0;
	int64_t present_status = 0;
	std::vector<std::string> records;
};

PresentOutcome ParsePresentResponse(std::string_view body) {
	PresentOutcome out;
	Reader r(body);
	while (!r.AtEnd()) {
		Tag t;
		std::string_view c = r.Next(t);
		if (t.cls != Class::CONTEXT) {
			continue;
		}
		switch (t.number) {
		case 24: // numberOfRecordsReturned
			out.returned = ber::ParseIntegerContent(c);
			break;
		case 25: // nextResultSetPosition
			out.next_position = ber::ParseIntegerContent(c);
			break;
		case 27: // presentStatus (0 = success)
			out.present_status = ber::ParseIntegerContent(c);
			break;
		default:
			ParseRecordsChoice("present", t, c, out.records); // throws on diagnostics
			break;
		}
	}
	return out;
}

//! Close APDU body -> MarcError describing why the peer hung up.
[[noreturn]] void ThrowClose(std::string_view body) {
	static const char *REASONS[] = {"finished",       "shutdown",       "system problem",
	                                "cost limit",     "resources",      "security violation",
	                                "protocol error", "lack of activity", "peer abort",
	                                "unspecified"};
	std::string msg = "Z39.50: server closed the association";
	Reader r(body);
	while (!r.AtEnd()) {
		Tag t;
		std::string_view c = r.Next(t);
		if (t.Is(Class::CONTEXT, 211)) { // closeReason [211] INTEGER (assumed tag, medium confidence)
			int64_t reason = ber::ParseIntegerContent(c);
			msg += " (";
			if (reason >= 0 && reason <= 9) {
				msg += REASONS[reason];
			} else {
				msg += std::to_string(reason);
			}
			msg += ")";
		} else if (t.Is(Class::CONTEXT, 3) && !c.empty()) { // diagnosticInformation [3]
			msg += ": " + std::string(c);
		}
	}
	throw MarcError(msg);
}

//! Pull one complete APDU off the transport, buffering partial reads in `buf`.
std::string ReadApdu(Z3950Transport &t, std::string &buf) {
	size_t total = 0;
	while (!ber::FrameTlv(buf, total)) {
		std::string more = t.Recv();
		if (more.empty()) {
			throw MarcError("Z39.50: connection closed before a complete APDU arrived");
		}
		buf += more;
	}
	std::string apdu = buf.substr(0, total);
	buf.erase(0, total);
	return apdu;
}

//! Read an APDU and check the PDU tag; hands back the APDU bytes (owning) —
//! call ApduBody on them for the content view.  Close APDUs throw.
std::string ExpectApdu(Z3950Transport &t, std::string &buf, uint32_t want, const char *what) {
	std::string apdu = ReadApdu(t, buf);
	Reader r(apdu);
	Tag tag;
	std::string_view body = r.Next(tag);
	if (tag.cls != Class::CONTEXT) {
		throw MarcError("Z39.50: response is not a context-tagged PDU");
	}
	if (tag.number == APDU_CLOSE) {
		ThrowClose(body);
	}
	if (tag.number != want) {
		throw MarcError("Z39.50: expected " + std::string(what) + " [" + std::to_string(want) + "], got PDU tag [" +
		                std::to_string(tag.number) + "]");
	}
	return apdu;
}

std::string_view ApduBody(const std::string &apdu) {
	Reader r(apdu);
	Tag tag;
	return r.Next(tag);
}

} // namespace

Z3950Result Z3950Search(Z3950Transport &t, const std::string &database, const std::string &query, int max_records) {
	RpnTerm rpn = ParseQueryString(query); // throws before any I/O on bad syntax
	std::string buf;

	t.Send(BuildInitRequest());
	{
		std::string apdu = ExpectApdu(t, buf, APDU_INIT_RESPONSE, "InitResponse");
		ParseInitResponse(ApduBody(apdu));
	}

	t.Send(BuildSearchRequest(database, rpn));
	SearchOutcome search;
	{
		std::string apdu = ExpectApdu(t, buf, APDU_SEARCH_RESPONSE, "SearchResponse");
		search = ParseSearchResponse(ApduBody(apdu));
	}

	Z3950Result result;
	result.hit_count = search.result_count;
	result.raw_records = std::move(search.piggyback); // empty with our request parameters
	int64_t want = std::min<int64_t>(std::max(max_records, 0), search.result_count);
	if (static_cast<int64_t>(result.raw_records.size()) > want) {
		result.raw_records.resize(want);
	}
	int64_t next = search.next_position >= 1 ? search.next_position : 1;
	while (static_cast<int64_t>(result.raw_records.size()) < want) {
		int64_t chunk = std::min<int64_t>(want - static_cast<int64_t>(result.raw_records.size()), PRESENT_CHUNK);
		t.Send(BuildPresentRequest(next, chunk));
		std::string apdu = ExpectApdu(t, buf, APDU_PRESENT_RESPONSE, "PresentResponse");
		PresentOutcome present = ParsePresentResponse(ApduBody(apdu));
		if (present.records.empty()) {
			throw MarcError("Z39.50: present returned no records (presentStatus " +
			                std::to_string(present.present_status) + ")");
		}
		for (auto &rec : present.records) {
			if (static_cast<int64_t>(result.raw_records.size()) >= want) {
				break;
			}
			result.raw_records.push_back(std::move(rec));
		}
		int64_t advanced = present.next_position >= 1 ? present.next_position : next + present.returned;
		if (advanced <= next) {
			throw MarcError("Z39.50: present did not advance the result-set position");
		}
		next = advanced;
	}
	return result;
}

} // namespace marc
