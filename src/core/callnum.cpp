//! Call-number parsing and collation keys (see callnum.hpp for the API).
//! Written from the published structure of LC Classification and Dewey call
//! numbers; no external MARC tooling code consulted.
//!
//! ParseLcc grammar, in order:
//!   * 1-3 ASCII class letters, uppercased; a 4th letter is malformed;
//!   * optional spaces, then a 1-4 digit class number (LCC schedules stop
//!     at 9999; longer runs are rejected so zero-padding stays total);
//!   * '.' immediately followed by a digit starts the class decimal;
//!   * repeatedly, skipping spaces and dots: a letter followed by a digit
//!     is a cutter (letter uppercased + its digit run); exactly four
//!     digits are the year, taking one trailing work letter (lowercased)
//!     when it ends the string or precedes a space;
//!   * the first token fitting neither shape — or anything after the year
//!     — becomes `rest`, trimmed but otherwise verbatim.
//!
//! LccSortKey layout, designed so bytewise order equals shelf order:
//!   KKK NNNN . DDD (' ' CUTTER)* (' ' YEAR) (' ' REST)
//!   * class letters space-padded to 3 — space < 'A', so "P" < "PA" < "PZ";
//!   * integer part zero-padded to 4 — "PZ7" < "PZ76", "QA76" < "QA279";
//!   * the '.' is always present and decimal digits follow positionally —
//!     "QA76.73" < "QA76.9" because '7' < '9' position by position, and a
//!     bare number sorts before any decimal because ' ' < any digit;
//!   * cutter digits are decimal digits, so positional comparison gives
//!     .C4 < .C45 < .C5; a date directly after the class number files
//!     before any cutter because '0'-'9' < 'A';
//!   * "1990" < "1990b" by prefix order — work letters file after plain.
//!
//! DdcSortKey: leading letters (with following '.'/spaces) are stripped as
//! an audience/collection prefix ("j398.2" and "398.2" key identically);
//! integer part 1-3 digits zero-padded to 3, decimals positional, trailing
//! cutter/item text uppercased with runs of whitespace collapsed to one
//! space (' ' < '.' keeps "813 F553" before "813.54").
#include "marc/callnum.hpp"

namespace marc {

namespace {

bool IsDigit(char c) {
	return c >= '0' && c <= '9';
}

bool IsAlpha(char c) {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

char Upper(char c) {
	return (c >= 'a' && c <= 'z') ? static_cast<char>(c - 'a' + 'A') : c;
}

char Lower(char c) {
	return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;
}

std::string_view Trim(std::string_view s) {
	while (!s.empty() && (s.front() == ' ' || s.front() == '\t')) {
		s.remove_prefix(1);
	}
	while (!s.empty() && (s.back() == ' ' || s.back() == '\t')) {
		s.remove_suffix(1);
	}
	return s;
}

} // namespace

LccParts ParseLcc(std::string_view s) {
	LccParts p;
	p.valid = false;
	s = Trim(s);
	size_t i = 0, n = s.size();

	while (i < n && i < 3 && IsAlpha(s[i])) {
		p.klass += Upper(s[i]);
		i++;
	}
	if (p.klass.empty() || (i < n && IsAlpha(s[i]))) {
		return LccParts {"", "", "", {}, "", "", false};
	}
	while (i < n && s[i] == ' ') {
		i++;
	}
	while (i < n && IsDigit(s[i])) {
		p.number += s[i++];
	}
	if (p.number.empty() || p.number.size() > 4) {
		return LccParts {"", "", "", {}, "", "", false};
	}
	if (i + 1 < n && s[i] == '.' && IsDigit(s[i + 1])) {
		i++;
		while (i < n && IsDigit(s[i])) {
			p.decimal += s[i++];
		}
	}
	p.valid = true;

	while (i < n) {
		while (i < n && (s[i] == ' ' || s[i] == '.')) {
			i++;
		}
		if (i == n) {
			break;
		}
		if (p.year.empty() && IsAlpha(s[i]) && i + 1 < n && IsDigit(s[i + 1])) {
			std::string cutter(1, Upper(s[i]));
			i++;
			while (i < n && IsDigit(s[i])) {
				cutter += s[i++];
			}
			p.cutters.push_back(std::move(cutter));
			continue;
		}
		if (p.year.empty() && IsDigit(s[i])) {
			size_t start = i;
			std::string digits;
			while (i < n && IsDigit(s[i])) {
				digits += s[i++];
			}
			if (digits.size() == 4) {
				if (i < n && IsAlpha(s[i]) && (i + 1 == n || s[i + 1] == ' ')) {
					digits += Lower(s[i++]);
				}
				p.year = std::move(digits);
				continue;
			}
			i = start; // not a year: hand the token to `rest`
		}
		p.rest = std::string(Trim(s.substr(i)));
		break;
	}
	return p;
}

std::string LccSortKey(std::string_view s) {
	LccParts p = ParseLcc(s);
	if (!p.valid) {
		return "";
	}
	std::string key = p.klass;
	key.append(3 - p.klass.size(), ' ');
	key.append(4 - p.number.size(), '0');
	key += p.number;
	key += '.';
	key += p.decimal;
	for (auto &cutter : p.cutters) {
		key += ' ';
		key += cutter;
	}
	if (!p.year.empty()) {
		key += ' ';
		key += p.year;
	}
	if (!p.rest.empty()) {
		key += ' ';
		key += p.rest;
	}
	return key;
}

std::string DdcSortKey(std::string_view s) {
	s = Trim(s);
	size_t i = 0, n = s.size();
	while (i < n && IsAlpha(s[i])) {
		i++;
	}
	if (i > 0) {
		while (i < n && (s[i] == ' ' || s[i] == '.')) {
			i++;
		}
	}
	std::string ipart;
	while (i < n && IsDigit(s[i])) {
		ipart += s[i++];
	}
	if (ipart.empty() || ipart.size() > 3) {
		return "";
	}
	std::string key(3 - ipart.size(), '0');
	key += ipart;
	if (i + 1 < n && s[i] == '.' && IsDigit(s[i + 1])) {
		key += '.';
		i++;
		while (i < n && IsDigit(s[i])) {
			key += s[i++];
		}
	}
	std::string_view rest = Trim(s.substr(i));
	if (!rest.empty()) {
		key += ' ';
		bool pending_space = false;
		for (char c : rest) {
			if (c == ' ' || c == '\t') {
				pending_space = true;
				continue;
			}
			if (pending_space) {
				key += ' ';
				pending_space = false;
			}
			key += Upper(c);
		}
	}
	return key;
}

bool CutterValid(std::string_view s) {
	size_t i = 0, n = s.size();
	if (i < n && s[i] == '.') {
		i++;
	}
	size_t letters = 0;
	while (i < n && IsAlpha(s[i])) {
		letters++;
		i++;
	}
	if (letters < 1 || letters > 2) {
		return false;
	}
	size_t digits = 0;
	while (i < n && IsDigit(s[i])) {
		digits++;
		i++;
	}
	return digits >= 1 && i == n;
}

} // namespace marc
