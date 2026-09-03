//! Minimal Z39.50-1995 (ISO 23950) client core: Init, Search (Type-1 RPN
//! with Bib-1 use attributes) and Present of USMARC records over an abstract
//! byte transport.  The BER subset and APDU shapes below are written from
//! the published standard's ASN.1 definitions (as recalled and documented
//! inline in z3950.cpp) — no existing Z39.50 implementation's source was
//! consulted.  DuckDB-free, unit-testable standalone.
//!
//! Honest limitations (v1):
//!  * No live-server test is possible in this build environment; the protocol
//!    flow is exercised only against a scripted mock transport
//!    (test/cpp/z3950_test.cpp).  Behaviour against real servers such as
//!    z3950.loc.gov:7090/Voyager is untested.
//!  * Query language: a single term with optional numeric Bib-1 attributes —
//!    no boolean operators, proximity, truncation or multi-term queries.
//!  * No authentication: idAuthentication is never sent.
//!  * USMARC (OID 1.2.840.10003.5.10) is the only record syntax requested,
//!    and the only one accepted back.
//!  * BER subset: definite lengths only; indefinite-length encodings are
//!    rejected with MarcError.
//!
//! Query language (tiny prefix subset, inspired by the common @attr syntax):
//!   query := attr* term
//!   attr  := "@attr" SP type "=" value        (unsigned decimal integers)
//!   term  := '"' any-chars-except-quote '"'   (no escape sequences)
//!          | remaining-text (trimmed; may contain spaces)
//! A bare term (no @attr) searches with Bib-1 use=any: '@attr 1=1016'.
//! Useful Bib-1 use (type 1) values: 1 personal name, 4 title, 7 ISBN,
//! 12 local number, 1016 any.  Examples:
//!   dinosaurs                  -> use 1016, term "dinosaurs"
//!   @attr 1=4 "dinosaur bones" -> use 4 (title), term "dinosaur bones"
//!   @attr 1=7 0316769487       -> use 7 (ISBN), term "0316769487"
#pragma once

#include "marc/core.hpp"

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace marc {
namespace ber {

//! BER identifier-octet class (X.690 8.1.2: bits 8-7 of the leading octet).
enum class Class : uint8_t { UNIVERSAL = 0, APPLICATION = 1, CONTEXT = 2, PRIVATE = 3 };

//! Universal tag numbers this subset uses.
constexpr uint32_t TAG_BOOLEAN = 1;
constexpr uint32_t TAG_INTEGER = 2;
constexpr uint32_t TAG_BIT_STRING = 3;
constexpr uint32_t TAG_OCTET_STRING = 4;
constexpr uint32_t TAG_OID = 6;
constexpr uint32_t TAG_OBJECT_DESCRIPTOR = 7;
constexpr uint32_t TAG_EXTERNAL = 8;
constexpr uint32_t TAG_SEQUENCE = 16;
constexpr uint32_t TAG_VISIBLE_STRING = 26;
constexpr uint32_t TAG_GENERAL_STRING = 27; // InternationalString ::= GeneralString

//! A decoded identifier octet (plus any high-tag-number continuation octets).
struct Tag {
	Class cls = Class::UNIVERSAL;
	bool constructed = false;
	uint32_t number = 0;

	bool Is(Class c, uint32_t n) const {
		return cls == c && number == n;
	}
};

// ---- encoding --------------------------------------------------------------
//! Identifier octets; numbers >= 31 use the high-tag-number form (X.690
//! 8.1.2.4: leading octet with tag bits 11111, then base-128 big-endian with
//! bit 8 as continuation).  Z39.50 needs this constantly ([44], [102], ...).
void AppendTag(std::string &out, Class cls, bool constructed, uint32_t number);
//! Definite length octets: short form < 128, else long form (X.690 8.1.3).
void AppendLength(std::string &out, size_t length);
//! One whole TLV: tag + definite length + content octets.
std::string Tlv(Class cls, bool constructed, uint32_t number, std::string_view content);
//! INTEGER content octets: minimal-length big-endian two's complement.
std::string IntegerContent(int64_t value);
//! OBJECT IDENTIFIER content octets (X.690 8.19): first subidentifier is
//! 40*arc0 + arc1, every subidentifier base-128 big-endian, bit 8 continues.
std::string OidContent(const std::vector<uint32_t> &arcs);
//! BIT STRING content: leading unused-bit count octet, then the bits with
//! bit 0 as the MSB of the first octet (the numbering Z39.50 options use).
std::string BitStringContent(const std::vector<uint32_t> &set_bits);

// ---- decoding --------------------------------------------------------------
//! Both throw MarcError on empty/oversized content.
int64_t ParseIntegerContent(std::string_view content);
std::vector<uint32_t> ParseOidContent(std::string_view content);

//! Framing: true when `buffer` begins with one complete definite-length TLV
//! (total size, header included, in `total_length`); false when more bytes
//! are needed.  Throws MarcError on indefinite length (unsupported in v1).
bool FrameTlv(std::string_view buffer, size_t &total_length);

//! Sequential TLV reader over a byte range (typically the content octets of a
//! constructed value).  All reads throw MarcError on truncated or
//! indefinite-length input.
class Reader {
public:
	explicit Reader(std::string_view data) : data_(data) {
	}
	bool AtEnd() const {
		return pos_ >= data_.size();
	}
	//! Tag of the next TLV without consuming it.
	Tag Peek() const;
	//! Consume the next TLV; returns its content octets (view into `data`).
	std::string_view Next(Tag &tag);
	//! Next() that throws unless the tag matches.
	std::string_view Expect(Class cls, uint32_t number);
	//! Consume the next TLV only when its tag matches; false otherwise.
	bool NextIf(Class cls, uint32_t number, std::string_view &content);

private:
	std::string_view data_;
	size_t pos_ = 0;
};

} // namespace ber

// ---- z3950.cpp -------------------------------------------------------------

//! Byte transport supplied by the caller (sockets live outside this module).
//! Recv() must return at least one whole BER APDU's worth of bytes per call
//! (returning more is fine — Z3950Search buffers and re-frames); an empty
//! return means the peer closed the connection.
struct Z3950Transport {
	virtual ~Z3950Transport() = default;
	virtual void Send(const std::string &bytes) = 0;
	virtual std::string Recv() = 0;
};

struct Z3950Result {
	int64_t hit_count = 0;
	//! ISO 2709 transmission-format bytes, one string per record, ready for
	//! marc::ParseRecord.
	std::vector<std::string> raw_records;
};

//! Drive Init -> Search -> Present against `t`: initialise (search+present
//! options), search `database` with the Type-1 RPN query built from `query`
//! (see the query-language note at the top of this header), then Present
//! USMARC records in chunks of at most 10 until max_records or hit_count is
//! reached.  max_records <= 0 fetches no records (hit count only).  Throws
//! MarcError carrying the server's diagnostic text on any failure.
Z3950Result Z3950Search(Z3950Transport &t, const std::string &database, const std::string &query, int max_records);

} // namespace marc
