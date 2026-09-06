//! MicroLIF reader.  The line-oriented "Library Interchange Format" used by
//! book vendors (Follett, Brodart, ...) for microcomputer circulation
//! systems: one field per line, `_x` subfield markers, backtick record
//! terminator.  Both the classic layouts are accepted:
//!   * "header" variant — each record opens with an `LDR` leader line (and a
//!     vendor `HDR`/`HEADR` banner line may open the file);
//!   * "no-header" variant — records are bare field lines separated by the
//!     backtick terminator; a default leader is synthesised.
//! Parsing is deliberately tolerant (vendor output varies): CRLF or LF, blank
//! lines ignored, `\` accepted for a blank indicator, text before the first
//! subfield marker treated as an implied $a, `_` not followed by an
//! alphanumeric kept literal.  Values are NFC-normalised.  Throws MarcError
//! with a line number on lines that cannot be a field.
#include "marc/core.hpp"
#include "marc/formats.hpp"

#include <cctype>

namespace marc {

namespace {

bool IsSubfieldCode(char c) {
	return std::islower(static_cast<unsigned char>(c)) || std::isdigit(static_cast<unsigned char>(c));
}

// One UTF-8 scalar off the front (lossy); empty input yields a space.
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

std::string TakeIndicator(std::string_view &s) {
	std::string ind = TakeScalar(s);
	return (ind == "\\" || ind == "_") ? " " : ind;
}

// Split `data` on `_x` markers into field.subfields.  Text before the first
// marker becomes an implied $a; `_` not followed by a lowercase letter or
// digit stays literal inside the current value.
void ParseSubfields(std::string_view data, Field &field) {
	size_t i = 0, n = data.size();
	std::string code, value;
	bool have_subfield = false, implied = false;
	auto flush = [&]() {
		// An implied $a that stayed empty (e.g. indicators only) is noise.
		if (have_subfield && !(implied && value.empty())) {
			field.subfields.push_back(Subfield {code, NfcNormalizeUtf8(value)});
		}
		value.clear();
	};
	while (i < n) {
		if (data[i] == '_' && i + 1 < n && IsSubfieldCode(data[i + 1])) {
			flush();
			code = std::string(1, data[i + 1]);
			have_subfield = true;
			implied = false;
			i += 2;
			continue;
		}
		if (!have_subfield) {
			// Implied $a for marker-less leading text.
			code = "a";
			have_subfield = true;
			implied = true;
		}
		value.push_back(data[i++]);
	}
	flush();
}

} // namespace

std::vector<Record> ParseMicroLif(std::string_view text) {
	std::vector<Record> records;
	Record current;
	bool have_current = false;
	auto flush = [&]() {
		if (have_current) {
			records.push_back(std::move(current));
			current = Record();
			have_current = false;
		}
	};

	size_t lineno = 0;
	size_t pos = 0;
	bool first_content_line = true;
	while (pos <= text.size()) {
		size_t eol = text.find('\n', pos);
		std::string_view line = text.substr(pos, eol == std::string_view::npos ? std::string_view::npos : eol - pos);
		pos = eol == std::string_view::npos ? text.size() + 1 : eol + 1;
		lineno++;

		if (!line.empty() && line.back() == '\r') {
			line.remove_suffix(1);
		}
		// A trailing backtick run terminates the record after this line; a
		// bare (or leading) backtick line is a terminator on its own.
		bool terminate = false;
		while (!line.empty() && line.back() == '`') {
			line.remove_suffix(1);
			terminate = true;
		}
		if (!line.empty() && line[0] == '`') {
			flush();
			continue;
		}
		if (line.empty()) {
			if (terminate) {
				flush();
			}
			continue;
		}

		std::string_view tag_src = line.substr(0, std::min<size_t>(3, line.size()));
		bool tag_alnum = tag_src.size() == 3;
		for (char c : tag_src) {
			if (!std::isalnum(static_cast<unsigned char>(c))) {
				tag_alnum = false;
			}
		}

		if (tag_src.size() >= 3 && (line.compare(0, 3, "LDR") == 0 || line.compare(0, 3, "ldr") == 0)) {
			// Leader line: always opens a new record ("header" variant).
			flush();
			std::u32string ldr = Utf8DecodeLossy(line.substr(3));
			ldr.resize(24, U' ');
			current.leader = Utf8Encode(ldr);
			have_current = true;
			first_content_line = false;
			if (terminate) {
				flush();
			}
			continue;
		}
		// Vendor banner lines (`HDR...`, `HEADR...`) and any other non-field
		// first line are skipped; garbage later in the file is an error.
		if (line.compare(0, 5, "HEADR") == 0 || line.compare(0, 3, "HDR") == 0 || (!tag_alnum && first_content_line)) {
			first_content_line = false;
			if (terminate) {
				flush();
			}
			continue;
		}
		if (!tag_alnum) {
			throw MarcError("line " + std::to_string(lineno) + ": not a MicroLIF field line");
		}
		first_content_line = false;

		if (!have_current) {
			current.leader = "00000nam a2200000 a 4500";
			have_current = true;
		}

		Field field;
		field.tag = std::string(tag_src);
		std::string_view rest = line.substr(3);
		if (field.tag < "010") {
			field.is_control = true;
			field.control_value = NfcNormalizeUtf8(rest);
		} else {
			field.ind1 = TakeIndicator(rest);
			field.ind2 = TakeIndicator(rest);
			ParseSubfields(rest, field);
		}
		current.fields.push_back(std::move(field));
		if (terminate) {
			flush();
		}
	}
	flush();
	return records;
}

} // namespace marc
