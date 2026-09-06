//! Targeted $0/$1 write-back (see authlink.hpp for the API contracts).
//! Value semantics throughout: every operation copies the record and edits
//! the copy.  The heading-join and NACO-match semantics deliberately mirror
//! the marc_heading_join SQL macro and NacoNormalize (idnorm.cpp) so a
//! heading taken from marc_reconcile_headings / marc_headings output matches
//! the same field occurrences it was extracted from.  Written from the
//! published MARC 21 definitions of $0/$1; no external MARC tooling code
//! consulted.
#include "marc/authlink.hpp"

#include "marc/idnorm.hpp"

namespace marc {

namespace {

// Same validation and matching as the editing operations (file-local in
// edit.cpp, so repeated here rather than widening that file's interface).
void ValidateTagPattern(const std::string &pattern, const char *what) {
	if (pattern.size() != 3) {
		throw MarcError(std::string(what) + " \"" + pattern + "\" must be exactly 3 characters");
	}
	for (char c : pattern) {
		bool alnum = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
		if (!alnum && c != '.') {
			throw MarcError(std::string(what) + " \"" + pattern + "\" has a character outside [0-9a-zA-Z.]");
		}
	}
}

bool TagMatches(const std::string &pattern, const std::string &tag) {
	if (tag.size() != 3) {
		return false;
	}
	for (size_t i = 0; i < 3; i++) {
		if (pattern[i] != '.' && pattern[i] != tag[i]) {
			return false;
		}
	}
	return true;
}

void ValidateLinkCode(char code, const char *what) {
	if (code != '0' && code != '1') {
		throw MarcError(std::string(what) + ": link subfield code must be '0' or '1', got '" +
		                std::string(1, code) + "'");
	}
}

// marc_heading_join semantics: single-letter a-z codes except 'w', values
// joined with single spaces in field order ($0-$9 and $w never contribute).
std::string JoinHeading(const Field &f) {
	std::string out;
	bool first = true;
	for (auto &sf : f.subfields) {
		if (sf.code.size() != 1 || sf.code[0] < 'a' || sf.code[0] > 'z' || sf.code[0] == 'w') {
			continue;
		}
		if (!first) {
			out.push_back(' ');
		}
		out.append(sf.value);
		first = false;
	}
	return out;
}

} // namespace

Record SetLinkedUri(const Record &rec, const std::string &tagpat, const std::string &heading,
                    const std::string &uri, char code) {
	ValidateTagPattern(tagpat, "set-linked-uri tag pattern");
	ValidateLinkCode(code, "set-linked-uri");
	const std::string code_str(1, code);
	const std::string want = NacoNormalize(heading);

	Record out = rec;
	if (want.empty()) {
		return out; // an empty comparison form must not link everything
	}
	for (auto &f : out.fields) {
		if (f.is_control || !TagMatches(tagpat, f.tag)) {
			continue;
		}
		if (NacoNormalize(JoinHeading(f)) != want) {
			continue;
		}
		// Replace the first existing link subfield in place, drop the rest;
		// append at the end (the canonical $0/$1 spot) when there is none.
		bool replaced = false;
		std::vector<Subfield> kept;
		kept.reserve(f.subfields.size() + 1);
		for (auto &sf : f.subfields) {
			if (sf.code == code_str) {
				if (!replaced) {
					kept.push_back({code_str, uri});
					replaced = true;
				}
				continue;
			}
			kept.push_back(sf);
		}
		if (!replaced) {
			kept.push_back({code_str, uri});
		}
		f.subfields = std::move(kept);
	}
	return out;
}

Record ClearLinkedUris(const Record &rec, const std::string &tagpat, char code) {
	ValidateTagPattern(tagpat, "clear-linked-uris tag pattern");
	ValidateLinkCode(code, "clear-linked-uris");
	const std::string code_str(1, code);

	Record out = rec;
	for (auto &f : out.fields) {
		if (f.is_control || !TagMatches(tagpat, f.tag)) {
			continue;
		}
		std::vector<Subfield> kept;
		kept.reserve(f.subfields.size());
		for (auto &sf : f.subfields) {
			if (sf.code != code_str) {
				kept.push_back(sf);
			}
		}
		f.subfields = std::move(kept);
	}
	return out;
}

} // namespace marc
