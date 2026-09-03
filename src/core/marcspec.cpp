//! MARCspec evaluator (marcspec.github.io), written from the published spec.
//! The subset implemented:
//!
//!   * fieldspec: a 3-character tag of [0-9a-zA-Z] with '.' as a per-position
//!     wildcard ("245", "6..", "..."), or "LDR" for the leader;
//!   * an optional index after the fieldspec — [n], [n-m], [#], [n-#] — that
//!     selects among the matched fields, '#' meaning the last one; [#-n]
//!     follows the spec's "last n+1" rule ([#-1] = the last two);
//!   * for LDR and control fields, an optional character position or range
//!     /n, /n-m, /#, /n-#, /#-n counted in bytes (fixed fields are ASCII);
//!   * for data fields, subfield codes $a$b... — any single character except
//!     the structural ones ($ [ ] { } / ^) — each with its own optional index
//!     over that code's occurrences within one field;
//!   * indicators via a "^1"/"^2" suffix on the fieldspec.
//!
//! Abbreviated data: a data-field spec with no subfield codes yields, per
//! matched field, the subfield values joined with a single space; control
//! fields matched by the same (wildcarded) spec yield their value.  Out-of-
//! range indices and positions select nothing rather than failing.
//!
//! Deliberate exclusions, all rejected with MarcError: subspecs ({...}) are
//! not supported; nor are subfield ranges ($a-c), character positions on
//! subfields ($a/0-3), or an index on LDR.  Character positions on a data
//! field, indicators of a control field, and subfield codes on a control
//! field are well-formed but select nothing.
#include "marc/query.hpp"

namespace marc {

namespace {

struct Pos {
	bool last = false; // '#'
	size_t num = 0;
};

struct Range {
	bool present = false;
	bool is_range = false;
	Pos a, b;
};

struct SubfieldSpec {
	std::string code;
	Range index;
};

struct Spec {
	bool is_leader = false;
	std::string tag; // 3 chars, '.' wildcards
	Range field_index;
	Range char_range;
	std::vector<SubfieldSpec> subfields;
	int indicator = 0; // 0 = none
};

// Resolve a parsed range against `len` items; false = selects nothing.
bool Resolve(const Range &r, size_t len, size_t &start, size_t &end) {
	if (len == 0) {
		return false;
	}
	size_t last = len - 1;
	if (r.is_range && r.a.last && !r.b.last) {
		// "#-n" is the last n+1 positions per the spec ([#-1] = last two).
		start = r.b.num >= last ? 0 : last - r.b.num;
		end = last;
	} else {
		start = r.a.last ? last : r.a.num;
		end = !r.is_range ? start : (r.b.last ? last : r.b.num);
	}
	if (start > last || start > end) {
		return false;
	}
	if (end > last) {
		end = last;
	}
	return true;
}

class SpecParser {
public:
	explicit SpecParser(std::string_view text) : text_(text) {
	}

	Spec Parse() {
		Spec spec;
		if (text_.size() < 3) {
			Fail("expected a 3-character field tag or LDR");
		}
		std::string tag(text_.substr(0, 3));
		pos_ = 3;
		if (tag == "LDR") {
			spec.is_leader = true;
		} else {
			for (char c : tag) {
				bool alnum = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
				if (!alnum && c != '.') {
					Fail("bad character in field tag");
				}
			}
			spec.tag = std::move(tag);
		}

		if (pos_ < text_.size() && text_[pos_] == '[') {
			if (spec.is_leader) {
				Fail("index not allowed on LDR");
			}
			spec.field_index = ParseBracketRange();
		}
		if (pos_ >= text_.size()) {
			return spec;
		}
		switch (text_[pos_]) {
		case '/':
			pos_++;
			spec.char_range = ParseRange();
			break;
		case '$':
			if (spec.is_leader) {
				Fail("subfields not allowed on LDR");
			}
			while (pos_ < text_.size() && text_[pos_] == '$') {
				pos_++;
				spec.subfields.push_back(ParseSubfield());
			}
			break;
		case '^':
			if (spec.is_leader) {
				Fail("indicators not allowed on LDR");
			}
			pos_++;
			if (pos_ >= text_.size() || (text_[pos_] != '1' && text_[pos_] != '2')) {
				Fail("indicator must be ^1 or ^2");
			}
			spec.indicator = text_[pos_++] - '0';
			break;
		default:
			break; // fall through to the trailing-character check
		}
		if (pos_ < text_.size()) {
			if (text_[pos_] == '{') {
				Fail("subspecs not supported");
			}
			Fail("unexpected trailing characters");
		}
		return spec;
	}

private:
	[[noreturn]] void Fail(const std::string &why) {
		throw MarcError("invalid MARCspec \"" + std::string(text_) + "\": " + why);
	}

	Pos ParsePos() {
		if (pos_ < text_.size() && text_[pos_] == '#') {
			pos_++;
			return Pos {true, 0};
		}
		size_t n = 0, digits = 0;
		while (pos_ < text_.size() && text_[pos_] >= '0' && text_[pos_] <= '9') {
			n = n * 10 + static_cast<size_t>(text_[pos_] - '0');
			pos_++;
			digits++;
		}
		if (digits == 0 || digits > 9) {
			Fail("expected a position (digits or #)");
		}
		return Pos {false, n};
	}

	Range ParseRange() {
		Range r;
		r.present = true;
		r.a = ParsePos();
		if (pos_ < text_.size() && text_[pos_] == '-') {
			pos_++;
			r.is_range = true;
			r.b = ParsePos();
		}
		return r;
	}

	Range ParseBracketRange() {
		pos_++; // '['
		Range r = ParseRange();
		if (pos_ >= text_.size() || text_[pos_] != ']') {
			Fail("unterminated index");
		}
		pos_++;
		return r;
	}

	SubfieldSpec ParseSubfield() {
		if (pos_ >= text_.size()) {
			Fail("expected a subfield code after $");
		}
		char c = text_[pos_];
		if (c == '$' || c == '[' || c == ']' || c == '{' || c == '}' || c == '/' || c == '^') {
			Fail("expected a subfield code after $");
		}
		pos_++;
		SubfieldSpec sub;
		sub.code = std::string(1, c);
		if (pos_ < text_.size() && text_[pos_] == '-') {
			Fail("subfield ranges not supported");
		}
		if (pos_ < text_.size() && text_[pos_] == '[') {
			sub.index = ParseBracketRange();
		}
		if (pos_ < text_.size() && text_[pos_] == '/') {
			Fail("character positions on subfields not supported");
		}
		return sub;
	}

	std::string_view text_;
	size_t pos_ = 0;
};

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

std::string Slice(const std::string &s, const Range &r) {
	size_t start, end;
	if (!r.present) {
		return s;
	}
	if (!Resolve(r, s.size(), start, end)) {
		return std::string();
	}
	return s.substr(start, end - start + 1);
}

std::string JoinSubfields(const Field &f) {
	std::string out;
	for (size_t i = 0; i < f.subfields.size(); i++) {
		if (i > 0) {
			out += " ";
		}
		out += f.subfields[i].value;
	}
	return out;
}

} // namespace

std::vector<std::string> MarcSpecEvaluate(const Record &rec, std::string_view spec_text) {
	Spec spec = SpecParser(spec_text).Parse();
	std::vector<std::string> out;

	if (spec.is_leader) {
		std::string v = Slice(rec.leader, spec.char_range);
		if (!spec.char_range.present || !v.empty()) {
			out.push_back(std::move(v));
		}
		return out;
	}

	std::vector<const Field *> matched;
	for (auto &f : rec.fields) {
		if (TagMatches(spec.tag, f.tag)) {
			matched.push_back(&f);
		}
	}
	size_t start = 0, end = matched.empty() ? 0 : matched.size() - 1;
	if (spec.field_index.present && !Resolve(spec.field_index, matched.size(), start, end)) {
		return out;
	}
	if (matched.empty()) {
		return out;
	}

	for (size_t i = start; i <= end; i++) {
		const Field &f = *matched[i];
		if (spec.indicator != 0) {
			if (!f.is_control) {
				out.push_back(spec.indicator == 1 ? f.ind1 : f.ind2);
			}
		} else if (spec.char_range.present) {
			if (f.is_control) {
				std::string v = Slice(f.control_value, spec.char_range);
				if (!v.empty()) {
					out.push_back(std::move(v));
				}
			}
		} else if (!spec.subfields.empty()) {
			if (f.is_control) {
				continue;
			}
			for (auto &sub : spec.subfields) {
				std::vector<const std::string *> values;
				for (auto &sf : f.subfields) {
					if (sf.code == sub.code) {
						values.push_back(&sf.value);
					}
				}
				size_t s = 0, e = values.empty() ? 0 : values.size() - 1;
				if (sub.index.present && !Resolve(sub.index, values.size(), s, e)) {
					continue;
				}
				for (size_t k = s; k < values.size() && k <= e; k++) {
					out.push_back(*values[k]);
				}
			}
		} else {
			out.push_back(f.is_control ? f.control_value : JoinSubfields(f));
		}
	}
	return out;
}

} // namespace marc
