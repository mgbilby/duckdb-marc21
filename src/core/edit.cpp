//! Record editing, merge and diff (see edit.hpp for the API contracts).
//! Value semantics throughout: every operation copies the record and edits
//! the copy.  Merge semantics follow the vendor-overlay concept from
//! published FOLIO/OCLC profile documentation, written from first
//! principles; no external MARC tooling code was consulted.
#include "marc/edit.hpp"

#include <algorithm>
#include <cstddef>
#include <map>
#include <regex>

namespace marc {

namespace {

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

std::regex CompileRegex(const std::string &pattern, bool icase, const char *what) {
	auto flags = std::regex::ECMAScript;
	if (icase) {
		flags |= std::regex::icase;
	}
	try {
		return std::regex(pattern, flags);
	} catch (const std::regex_error &e) {
		throw MarcError(std::string(what) + " \"" + pattern + "\" is not a valid ECMAScript regex: " + e.what());
	}
}

// Selector with its pieces validated and the regex compiled once.
struct CompiledSelector {
	const FieldSelector &sel;
	std::optional<std::regex> re;

	explicit CompiledSelector(const FieldSelector &s) : sel(s) {
		ValidateTagPattern(s.tag, "selector tag pattern");
		if (s.value_regex) {
			if (!s.subfield_code) {
				throw MarcError("selector value_regex requires subfield_code");
			}
			re = CompileRegex(*s.value_regex, s.value_regex_icase, "selector value_regex");
		}
	}

	bool SubfieldMatches(const Subfield &sf) const {
		return sf.code == *sel.subfield_code && (!re || std::regex_search(sf.value, *re));
	}

	bool Matches(const Field &f) const {
		if (!TagMatches(sel.tag, f.tag)) {
			return false;
		}
		if (sel.ind1 || sel.ind2) {
			if (f.is_control) {
				return false;
			}
			if ((sel.ind1 && f.ind1 != *sel.ind1) || (sel.ind2 && f.ind2 != *sel.ind2)) {
				return false;
			}
		}
		if (sel.subfield_code) {
			if (f.is_control) {
				return false;
			}
			for (auto &sf : f.subfields) {
				if (SubfieldMatches(sf)) {
					return true;
				}
			}
			return false;
		}
		return true;
	}
};

// Indexes into rec.fields of the fields the selector picks, occurrence
// filter applied (out of range selects nothing).
std::vector<size_t> SelectFields(const Record &rec, const CompiledSelector &cs) {
	std::vector<size_t> matched;
	for (size_t i = 0; i < rec.fields.size(); i++) {
		if (cs.Matches(rec.fields[i])) {
			matched.push_back(i);
		}
	}
	if (cs.sel.occurrence) {
		if (*cs.sel.occurrence >= matched.size()) {
			return {};
		}
		return {matched[*cs.sel.occurrence]};
	}
	return matched;
}

// Insertion point keeping ascending tag grouping: after the last field with
// tag <= the new tag (so a repeated tag's new occurrence lands last in its
// group), before the first strictly greater one.
size_t TagOrderPosition(const std::vector<Field> &fields, const std::string &tag) {
	size_t pos = 0;
	for (size_t i = 0; i < fields.size(); i++) {
		if (fields[i].tag <= tag) {
			pos = i + 1;
		}
	}
	return pos;
}

void ValidateIndicator(const std::string &ind, const char *what) {
	if (Utf8DecodeLossy(ind).size() != 1) {
		throw MarcError(std::string(what) + " \"" + ind + "\" must be exactly one Unicode scalar");
	}
}

std::string EscapeBreaker(const std::string &value) {
	std::string out;
	out.reserve(value.size());
	for (char c : value) {
		if (c == '$') {
			out += "{dollar}";
		} else {
			out.push_back(c);
		}
	}
	return out;
}

} // namespace

Record AddField(const Record &rec, Field field, InsertPosition position) {
	ValidateTagPattern(field.tag, "field tag");
	if (field.tag.find('.') != std::string::npos) {
		throw MarcError("field tag \"" + field.tag + "\" may not contain wildcards");
	}
	Record out = rec;
	size_t pos = position == InsertPosition::END ? out.fields.size() : TagOrderPosition(out.fields, field.tag);
	out.fields.insert(out.fields.begin() + static_cast<std::ptrdiff_t>(pos), std::move(field));
	return out;
}

Record RemoveFields(const Record &rec, const FieldSelector &selector, bool remove_subfield_only) {
	CompiledSelector cs(selector);
	if (remove_subfield_only && !selector.subfield_code) {
		throw MarcError("remove_subfield_only requires selector.subfield_code");
	}
	std::vector<size_t> picked = SelectFields(rec, cs);
	Record out;
	out.leader = rec.leader;
	size_t next = 0;
	for (size_t i = 0; i < rec.fields.size(); i++) {
		bool hit = next < picked.size() && picked[next] == i;
		if (hit) {
			next++;
		}
		if (!hit) {
			out.fields.push_back(rec.fields[i]);
			continue;
		}
		if (remove_subfield_only) {
			Field f = rec.fields[i];
			std::vector<Subfield> kept;
			for (auto &sf : f.subfields) {
				if (!cs.SubfieldMatches(sf)) {
					kept.push_back(sf);
				}
			}
			if (!kept.empty()) {
				f.subfields = std::move(kept);
				out.fields.push_back(std::move(f));
			}
		}
	}
	return out;
}

Record SetSubfield(const Record &rec, const FieldSelector &selector, const std::string &code,
                   const std::string &value, bool add_if_missing) {
	CompiledSelector cs(selector);
	if (Utf8DecodeLossy(code).size() != 1) {
		throw MarcError("subfield code \"" + code + "\" must be exactly one Unicode scalar");
	}
	Record out = rec;
	for (size_t i : SelectFields(rec, cs)) {
		Field &f = out.fields[i];
		if (f.is_control) {
			continue;
		}
		bool found = false;
		for (auto &sf : f.subfields) {
			if (sf.code == code) {
				sf.value = value;
				found = true;
			}
		}
		if (!found && add_if_missing) {
			f.subfields.push_back(Subfield {code, value});
		}
	}
	return out;
}

Record ReplaceInValues(const Record &rec, const FieldSelector &selector, const std::string &pattern,
                       const std::string &replacement, ValueDomain which, bool icase) {
	CompiledSelector cs(selector);
	std::regex re = CompileRegex(pattern, icase, "replacement pattern");
	Record out = rec;
	for (size_t i : SelectFields(rec, cs)) {
		Field &f = out.fields[i];
		if (f.is_control) {
			if (which != ValueDomain::DATA) {
				f.control_value = std::regex_replace(f.control_value, re, replacement);
			}
			continue;
		}
		if (which == ValueDomain::CONTROL) {
			continue;
		}
		for (auto &sf : f.subfields) {
			if (!selector.subfield_code || sf.code == *selector.subfield_code) {
				sf.value = std::regex_replace(sf.value, re, replacement);
			}
		}
	}
	return out;
}

Record SetIndicators(const Record &rec, const FieldSelector &selector, const std::optional<std::string> &ind1,
                     const std::optional<std::string> &ind2) {
	CompiledSelector cs(selector);
	if (ind1) {
		ValidateIndicator(*ind1, "ind1");
	}
	if (ind2) {
		ValidateIndicator(*ind2, "ind2");
	}
	Record out = rec;
	for (size_t i : SelectFields(rec, cs)) {
		Field &f = out.fields[i];
		if (f.is_control) {
			continue;
		}
		if (ind1) {
			f.ind1 = *ind1;
		}
		if (ind2) {
			f.ind2 = *ind2;
		}
	}
	return out;
}

Record MergeRecords(const Record &base, const Record &incoming, const MergeProfile &profile) {
	for (auto *list : {&profile.protected_tags, &profile.replace_tags, &profile.add_tags}) {
		for (auto &pattern : *list) {
			ValidateTagPattern(pattern, "merge profile tag pattern");
		}
	}
	auto in_list = [](const std::vector<std::string> &patterns, const std::string &tag) {
		for (auto &p : patterns) {
			if (TagMatches(p, tag)) {
				return true;
			}
		}
		return false;
	};

	Record out;
	out.leader = base.leader.empty() ? incoming.leader : base.leader;
	out.fields = base.fields;

	// Group incoming fields by tag, keeping first-appearance order.
	std::vector<std::pair<std::string, std::vector<const Field *>>> groups;
	for (auto &f : incoming.fields) {
		if (!groups.empty() && groups.back().first == f.tag) {
			groups.back().second.push_back(&f);
			continue;
		}
		bool found = false;
		for (auto &g : groups) {
			if (g.first == f.tag) {
				g.second.push_back(&f);
				found = true;
				break;
			}
		}
		if (!found) {
			groups.push_back({f.tag, {&f}});
		}
	}

	for (auto &[tag, group] : groups) {
		if (in_list(profile.protected_tags, tag)) {
			continue;
		}
		MergeAction action = in_list(profile.replace_tags, tag)  ? MergeAction::REPLACE
		                     : in_list(profile.add_tags, tag)    ? MergeAction::ADD
		                                                         : profile.default_action;
		size_t pos;
		if (action == MergeAction::REPLACE) {
			pos = out.fields.size();
			size_t w = 0;
			for (size_t r = 0; r < out.fields.size(); r++) {
				if (out.fields[r].tag == tag) {
					pos = std::min(pos, w);
					continue;
				}
				if (w != r) {
					out.fields[w] = std::move(out.fields[r]);
				}
				w++;
			}
			out.fields.resize(w);
			pos = std::min(pos, w);
			if (pos == out.fields.size()) {
				pos = TagOrderPosition(out.fields, tag);
			}
		} else {
			bool base_has = false;
			size_t last = 0;
			for (size_t r = 0; r < out.fields.size(); r++) {
				if (out.fields[r].tag == tag) {
					base_has = true;
					last = r;
				}
			}
			if (action == MergeAction::KEEP && base_has) {
				continue;
			}
			pos = (action == MergeAction::ADD && base_has) ? last + 1 : TagOrderPosition(out.fields, tag);
		}
		for (const Field *f : group) {
			out.fields.insert(out.fields.begin() + static_cast<std::ptrdiff_t>(pos++), *f);
		}
	}
	return out;
}

std::string RenderFieldBreaker(const Field &f) {
	std::string out = "=" + f.tag + "  ";
	if (f.is_control) {
		out += EscapeBreaker(f.control_value);
		return out;
	}
	out += f.ind1 == " " ? "\\" : f.ind1;
	out += f.ind2 == " " ? "\\" : f.ind2;
	for (auto &sf : f.subfields) {
		out += "$";
		out += sf.code;
		out += EscapeBreaker(sf.value);
	}
	return out;
}

std::vector<DiffEntry> DiffRecords(const Record &a, const Record &b) {
	std::vector<DiffEntry> out;
	if (a.leader != b.leader) {
		out.push_back({DiffKind::CHANGED, "LDR", std::nullopt, std::nullopt, "=LDR  " + a.leader, "=LDR  " + b.leader});
	}
	std::map<std::string, std::pair<std::vector<size_t>, std::vector<size_t>>> by_tag;
	for (size_t i = 0; i < a.fields.size(); i++) {
		by_tag[a.fields[i].tag].first.push_back(i);
	}
	for (size_t i = 0; i < b.fields.size(); i++) {
		by_tag[b.fields[i].tag].second.push_back(i);
	}
	for (auto &[tag, occ] : by_tag) {
		auto &[in_a, in_b] = occ;
		size_t n = std::max(in_a.size(), in_b.size());
		for (size_t k = 0; k < n; k++) {
			DiffEntry e;
			e.tag = tag;
			if (k < in_a.size()) {
				e.field_no_a = in_a[k];
				e.rendered_a = RenderFieldBreaker(a.fields[in_a[k]]);
			}
			if (k < in_b.size()) {
				e.field_no_b = in_b[k];
				e.rendered_b = RenderFieldBreaker(b.fields[in_b[k]]);
			}
			if (e.field_no_a && e.field_no_b) {
				if (e.rendered_a == e.rendered_b) {
					continue;
				}
				e.kind = DiffKind::CHANGED;
			} else {
				e.kind = e.field_no_a ? DiffKind::REMOVED : DiffKind::ADDED;
			}
			out.push_back(std::move(e));
		}
	}
	return out;
}

} // namespace marc
