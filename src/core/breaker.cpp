//! MARC breaker (.mrk) text reader.  `\` in indicator positions means blank;
//! `{dollar}` is a literal `$`; values are NFC-normalised.
#include "marc/core.hpp"

namespace marc {

static std::string Unescape(std::string_view s) {
	std::string t;
	t.reserve(s.size());
	size_t i = 0;
	while (i < s.size()) {
		if (s.compare(i, 8, "{dollar}") == 0) {
			t.push_back('$');
			i += 8;
		} else {
			t.push_back(s[i++]);
		}
	}
	return NfcNormalizeUtf8(t);
}

// Take one UTF-8 scalar from the front of `s`; empty input yields a space.
static std::string TakeScalar(std::string_view &s) {
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

// Indicator position: '\' means blank.
static std::string TakeIndicator(std::string_view &s) {
	std::string ind = TakeScalar(s);
	return ind == "\\" ? " " : ind;
}

std::vector<Record> ParseBreaker(std::string_view text) {
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
	while (pos <= text.size()) {
		size_t eol = text.find('\n', pos);
		std::string_view line = text.substr(pos, eol == std::string_view::npos ? std::string_view::npos : eol - pos);
		pos = eol == std::string_view::npos ? text.size() + 1 : eol + 1;
		lineno++;

		if (!line.empty() && line.back() == '\r') {
			line.remove_suffix(1);
		}
		if (line.empty() || line[0] != '=') {
			continue;
		}
		if (line.size() < 6) {
			throw MarcError("line " + std::to_string(lineno) + ": field line too short");
		}
		std::string tag(line.substr(1, 3));
		std::string_view rest = line.substr(6); // skip "=TAG  " (two spaces)

		if (tag == "LDR") {
			flush();
			std::u32string ldr = Utf8DecodeLossy(rest);
			ldr.resize(24, U' ');
			current.leader = Utf8Encode(ldr);
			have_current = true;
			continue;
		}
		for (char c : tag) {
			if (!std::isalnum(static_cast<unsigned char>(c))) {
				throw MarcError("line " + std::to_string(lineno) + ": bad tag \"" + tag + "\"");
			}
		}
		if (!have_current) {
			current.leader = "00000nam a2200000 a 4500";
			have_current = true;
		}

		Field field;
		field.tag = std::move(tag);
		if (field.tag < "010") {
			field.is_control = true;
			field.control_value = Unescape(rest);
		} else {
			field.ind1 = TakeIndicator(rest);
			field.ind2 = TakeIndicator(rest);
			size_t p = rest.find('$');
			while (p != std::string_view::npos) {
				size_t next = rest.find('$', p + 1);
				std::string_view part =
				    rest.substr(p + 1, next == std::string_view::npos ? std::string_view::npos : next - p - 1);
				if (!part.empty()) {
					std::string_view code_src = part;
					Subfield sf;
					sf.code = TakeScalar(code_src);
					sf.value = Unescape(code_src);
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
