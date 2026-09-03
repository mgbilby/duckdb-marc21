//! Ex Libris Aleph sequential reader, written from the format's published
//! description: one field per line,
//!
//!   columns 0-8   nine-digit record/system number
//!   column  9     space
//!   columns 10-14 three-character tag then two indicator characters
//!                 ("LDR" for the leader; control and fixed fields carry two
//!                 blanks in the indicator positions)
//!   column  15    space
//!   column  16    literal 'L' (the "library"/language-of-cataloging column)
//!   column  17    space (absent only when the field content is empty)
//!   column  18+   field content, subfields introduced by "$$x"
//!
//! Consecutive lines with the same nine-digit number form one record; the
//! number changes at a record boundary and is used for grouping only (it is
//! not copied into a field).
//!
//! Ambiguities in the wild, resolved as follows (mirrored by
//! marcref.parse_alephseq):
//!   * '^' is Aleph's blank in fixed-length data: translated to a space in
//!     the LDR line and in every control-field (tag < "010") value, kept
//!     verbatim inside $$-subfielded content.
//!   * Control-ness is tag-derived (< "010") like every other reader here.
//!     A data-tag line whose content has no "$$" (Aleph's FMT and similar
//!     fixed fields) keeps its tag and indicator columns but its content is
//!     dropped — the same treatment ParseBreaker gives unsubfielded content
//!     after a data field's indicators.
//!   * A record with no LDR line gets the breaker reader's default leader; a
//!     repeated LDR line replaces the earlier leader.
//!   * Content before the first "$$" on a data line (empty in well-formed
//!     input) is ignored, matching the breaker reader's leniency.
//! Blank lines are skipped; anything else malformed throws MarcError with a
//! line number.  Values are NFC-normalised.
#include "marc/formats.hpp"

#include <cctype>

namespace marc {

namespace {

std::string CaretToSpace(std::string_view s) {
	std::string out(s);
	for (char &c : out) {
		if (c == '^') {
			c = ' ';
		}
	}
	return out;
}

// One UTF-8 scalar from the front of `s` (a space if empty), repaired.
std::string TakeScalar(std::string_view &s) {
	if (s.empty()) {
		return " ";
	}
	size_t len = 1;
	uint8_t c = s[0];
	if (c >= 0xF0) {
		len = 4;
	} else if (c >= 0xE0) {
		len = 3;
	} else if (c >= 0xC0) {
		len = 2;
	}
	len = std::min(len, s.size());
	std::string scalar = Utf8Encode(Utf8DecodeLossy(s.substr(0, len)));
	s.remove_prefix(len);
	return scalar;
}

} // namespace

std::vector<Record> ParseAlephSeq(std::string_view text) {
	std::vector<Record> records;
	Record current;
	std::string current_id;
	bool have_current = false, have_leader = false;
	auto flush = [&]() {
		if (have_current) {
			if (!have_leader) {
				current.leader = "00000nam a2200000 a 4500";
			}
			records.push_back(std::move(current));
			current = Record();
			have_current = false;
			have_leader = false;
		}
	};

	size_t lineno = 0;
	size_t pos = 0;
	while (pos <= text.size()) {
		size_t eol = text.find('\n', pos);
		std::string_view line = text.substr(pos, eol == std::string_view::npos ? std::string_view::npos : eol - pos);
		pos = eol == std::string_view::npos ? text.size() + 1 : eol + 1;
		lineno++;

		if (!line.empty() && line.back() == '\r') {
			line.remove_suffix(1);
		}
		bool blank = true;
		for (char c : line) {
			if (c != ' ' && c != '\t') {
				blank = false;
				break;
			}
		}
		if (blank) {
			continue;
		}
		auto fail = [&](const std::string &why) -> MarcError {
			return MarcError("aleph: line " + std::to_string(lineno) + ": " + why);
		};
		if (line.size() < 17) {
			throw fail("line shorter than the 17-column field header");
		}
		for (size_t i = 0; i < 9; i++) {
			if (line[i] < '0' || line[i] > '9') {
				throw fail("record number is not nine digits");
			}
		}
		if (line[9] != ' ' || line[15] != ' ' || line[16] != 'L') {
			throw fail("malformed field header (expected \"<id> <tag+inds> L \")");
		}
		if (line.size() > 17 && line[17] != ' ') {
			throw fail("missing space after 'L'");
		}
		std::string id(line.substr(0, 9));
		std::string tag(line.substr(10, 3));
		std::string_view inds = line.substr(13, 2);
		std::string_view content = line.size() > 18 ? line.substr(18) : std::string_view();

		if (!have_current || id != current_id) {
			flush();
			current_id = id;
			have_current = true;
		}

		if (tag == "LDR") {
			std::u32string ldr = Utf8DecodeLossy(CaretToSpace(content));
			ldr.resize(24, U' ');
			current.leader = Utf8Encode(ldr);
			have_leader = true;
			continue;
		}
		for (char c : tag) {
			if (!std::isalnum(static_cast<unsigned char>(c))) {
				throw fail("bad tag \"" + tag + "\"");
			}
		}

		Field field;
		field.tag = std::move(tag);
		if (field.tag < "010") {
			field.is_control = true;
			field.control_value = NfcNormalizeUtf8(CaretToSpace(content));
		} else {
			std::string_view ind_src = inds;
			field.ind1 = TakeScalar(ind_src);
			field.ind2 = TakeScalar(ind_src);
			size_t p = content.find("$$");
			while (p != std::string_view::npos) {
				size_t next = content.find("$$", p + 2);
				std::string_view part =
				    content.substr(p + 2, next == std::string_view::npos ? std::string_view::npos : next - p - 2);
				if (!part.empty()) {
					Subfield sf;
					sf.code = TakeScalar(part);
					sf.value = NfcNormalizeUtf8(part);
					field.subfields.push_back(std::move(sf));
				}
				p = next;
			}
		}
		current.fields.push_back(std::move(field));
	}
	flush();
	return records;
}

} // namespace marc
