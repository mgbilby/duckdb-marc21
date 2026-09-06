//! Text/JSON format cores beyond core.hpp's readers: MARC-in-JSON both ways,
//! the MARCXML and breaker writers, and the Aleph sequential reader.  All
//! DuckDB-free; the orchestrator binds them to table functions and COPY
//! formats.  Semantics must agree with tools/marcref.py.
#pragma once

#include "marc/core.hpp"

namespace marc {

// ---- marcjson.cpp ----------------------------------------------------------
// MARC-in-JSON reader.  Accepts, auto-detected:
//   * one community-shape record object
//       {"leader": "...", "fields": [{"001": "v"},
//        {"245": {"ind1": "1", "ind2": "0", "subfields": [{"a": "T"}]}}]}
//   * a JSON array of such objects
//   * newline-delimited objects (NDJSON; any inter-value whitespace works)
//   * each object may be a FOLIO SRS envelope: {"parsedRecord": {"content":
//     {...}}} or {"content": {...}} is unwrapped to the community shape.
// Leaders are padded/truncated to 24 code points; values NFC-normalised.
// Throws MarcError on malformed JSON or on records without a "fields" array.
std::vector<Record> ParseMarcJson(std::string_view text);

// One record as a compact community-shape object: {"leader":...,"fields":[..]}
// with fields and subfields in record order.  Byte-identical to
// marcref.record_to_marcjson.
std::string WriteMarcJson(const Record &rec);

// ---- textwriters.cpp -------------------------------------------------------
// One namespace-free <record> element (slim schema layout); exact inverse of
// ParseMarcXml, so ParseMarcXml(WriteMarcXml(rec)) round-trips NFC input.
std::string WriteMarcXml(const Record &rec);

// XML declaration + <collection xmlns="http://www.loc.gov/MARC21/slim">
// wrapping WriteMarcXml of every record.
std::string WriteMarcXmlCollection(const std::vector<Record> &records);

// MARC breaker (.mrk) text for one record, trailing newline included; exact
// inverse of ParseBreaker (`\` for blank indicators, `$` as {dollar}).
std::string WriteBreaker(const Record &rec);

// ---- microlif.cpp ----------------------------------------------------------
// MicroLIF (vendor "Library Interchange Format") reader.  One field per line:
//   <3-char tag><ind1><ind2>_a...subfields marked with underscore+code
// Control fields (tag < "010") carry no indicators; a backtick terminates a
// record (trailing on the last field line or on a line of its own); an `LDR`
// line opens a record with an explicit leader ("header" variant) while bare
// field runs synthesise a default leader ("no-header" variant); a vendor
// banner first line (`HDR`/`HEADR`) is skipped.  Tolerant of CRLF, `\` blank
// indicators, marker-less leading text (implied $a) and literal `_` not
// followed by [a-z0-9].  Values NFC-normalised.  Throws MarcError with a line
// number on non-field lines.
std::vector<Record> ParseMicroLif(std::string_view text);

// ---- aleph.cpp -------------------------------------------------------------
// Ex Libris Aleph sequential reader.  One field per line:
//   <9-digit id> <tag+inds, 5 chars> L <content>
// with LDR for the leader and $$x subfield markers; see aleph.cpp for the
// exact conventions honoured.  Throws MarcError with a line number.
std::vector<Record> ParseAlephSeq(std::string_view text);

} // namespace marc
