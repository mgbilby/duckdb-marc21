//! Core record model shared by every reader and the writer.
//!
//! Deliberately DuckDB-free so the parsers compile and unit-test standalone
//! (see test/cpp/core_test.cpp).  Semantics must agree with tools/marcref.py.
#pragma once

#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace marc {

constexpr uint8_t FT = 0x1E; // field terminator
constexpr uint8_t SF = 0x1F; // subfield delimiter
constexpr uint8_t RT = 0x1D; // record terminator

struct MarcError : std::runtime_error {
	using std::runtime_error::runtime_error;
};

enum class Encoding { AUTO, UTF8, MARC8 };

Encoding ParseEncoding(const std::string &s);

// `code`, `ind1`, `ind2` hold one Unicode scalar as UTF-8 (a single byte for
// all binary MARC, but the XML and breaker readers admit anything).
struct Subfield {
	std::string code;
	std::string value;
};

struct Field {
	std::string tag;
	bool is_control = false;
	std::string control_value;           // control fields (tag < "010")
	std::string ind1 = " ", ind2 = " ";  // data fields
	std::vector<Subfield> subfields;
};

struct Record {
	std::string leader; // 24 chars
	std::vector<Field> fields;

	const std::string *ControlNumber() const {
		for (auto &f : fields) {
			if (f.tag == "001" && f.is_control) {
				return &f.control_value;
			}
		}
		return nullptr;
	}
};

// ---- unicode_nfc.cpp -------------------------------------------------------
// UTF-8 decode with U+FFFD for invalid sequences (Rust from_utf8_lossy rules).
std::u32string Utf8DecodeLossy(std::string_view bytes);
std::string Utf8Encode(const std::u32string &cps);
// Canonical ordering + primary composition over the generated UCD tables;
// equivalent to unicodedata.normalize("NFC", s) for the sequences we produce.
std::u32string NfcNormalize(std::u32string s);
inline std::string NfcNormalizeUtf8(std::string_view s) {
	return Utf8Encode(NfcNormalize(Utf8DecodeLossy(s)));
}
// Each byte to the code point of the same value (leaders, tags and codes are
// raw bytes from untrusted input; VARCHARs must be valid UTF-8).
std::string Latin1ToUtf8(std::string_view bytes);

// ---- marc8.cpp -------------------------------------------------------------
// MARC-8 (Basic Latin + ANSEL) to NFC-normalised UTF-8.  Never fails;
// unmappable bytes and unsupported escape-designated sets become U+FFFD.
std::string Marc8Decode(std::string_view bytes);

// ---- iso2709.cpp -----------------------------------------------------------
// How much character decoding a parse should do.  Structure (tags, indicators,
// codes, field boundaries) is always parsed; CONTROL_ONLY and NONE leave the
// affected `value` strings empty.  Used for projection pushdown — the visible
// semantics of decoded columns never change.
enum class DecodeMode { ALL, CONTROL_ONLY, NONE };

// Parse one raw record (leader through RT inclusive).  Throws MarcError.
Record ParseRecord(std::string_view raw, Encoding encoding, DecodeMode mode = DecodeMode::ALL);

// Split a buffer into raw records on RT; stray CR/LF/space between records is
// skipped and a trailing RT-less fragment is yielded so its error is visible.
class RecordSplitter {
public:
	explicit RecordSplitter(std::string_view data) : data_(data) {
	}
	// Returns false at end of input.
	bool Next(std::string_view &out);

private:
	std::string_view data_;
	size_t pos_ = 0;
};

// ---- writer.cpp ------------------------------------------------------------
// Serialise to ISO 2709 bytes: UTF-8 output, leader/00-04, 09 and 12-16
// recomputed (same positions as marcref.encode_record).  Throws MarcError on
// unrepresentable records (field > 9999 bytes, record > 99999).
std::string WriteRecord(const Record &rec);

// UTF-8 → MARC-8 using Basic Latin + ANSEL (G1) only, no escape-designated
// sets.  NFD first, combining marks emitted BEFORE their base; the spanning
// U+0361/U+0360 split into their ANSEL halves (EB/EC, FA/FB) around the two
// letters they join.  Anything unrepresentable becomes an LC-guidelines NCR
// "&#xHHHH;" (uppercase hex, no padding) — Marc8Decode passes those through
// literally; consumers un-NCR downstream.
std::string EncodeMarc8(std::string_view utf8);

// WriteRecord with field/subfield text through EncodeMarc8; leader/09 blank.
std::string WriteRecordMarc8(const Record &rec);

// ---- breaker.cpp -----------------------------------------------------------
// MARC breaker (.mrk) text: `\` indicators are blank, `{dollar}` a literal $.
std::vector<Record> ParseBreaker(std::string_view text);

// ---- marcxml.cpp -----------------------------------------------------------
// MARCXML slim schema, namespace-prefix tolerant, entity/NCR decoding.
std::vector<Record> ParseMarcXml(std::string_view text);

} // namespace marc
