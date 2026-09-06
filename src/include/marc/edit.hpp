//! Record editing, merge and diff over the core record model.  Deliberately
//! DuckDB-free like core.hpp/query.hpp; the orchestrator binds these to SQL
//! scalars later.  Every operation takes the input Record by const reference
//! and returns a NEW Record — inputs are never mutated.
#pragma once

#include "marc/core.hpp"

namespace marc {

// ---- edit.cpp --------------------------------------------------------------

// Predicate for selecting fields of a record.  A plain struct the caller
// fills; string parsing of any selector syntax lives in SQL later.  A field
// matches when ALL present criteria hold:
//   * `tag` — exactly 3 characters of [0-9a-zA-Z.], '.' a per-position
//     wildcard (same convention as MARCspec);
//   * `ind1`/`ind2` — exact match on the indicator (data fields only; a set
//     indicator never matches a control field);
//   * `subfield_code` — the field has at least one subfield with this code
//     (control fields never match);
//   * `value_regex` — ECMAScript std::regex, matched with search semantics
//     (anchor with ^...$ for a full match) against the values of
//     `subfield_code` subfields; requires `subfield_code`;
//   * `occurrence` — 0-based index into the fields matching everything
//     above; out of range selects nothing (not an error).
// Invalid tag patterns, invalid regexes, and value_regex without
// subfield_code throw MarcError.
struct FieldSelector {
	std::string tag = "...";
	std::optional<std::string> ind1, ind2;
	std::optional<std::string> subfield_code;
	std::optional<std::string> value_regex;
	bool value_regex_icase = false;
	std::optional<size_t> occurrence;
};

enum class InsertPosition {
	END,             // append after the last field
	BEFORE_TAG_ORDER // insert after the last field with tag <= the new tag,
	                 // keeping the ascending tag grouping catalogers expect
};

Record AddField(const Record &rec, Field field, InsertPosition position = InsertPosition::BEFORE_TAG_ORDER);

// Remove matching fields.  With `remove_subfield_only` (requires
// selector.subfield_code) only the matching subfields are removed — those
// with that code whose value also matches value_regex when one is set — and
// a data field left with no subfields is dropped entirely.
Record RemoveFields(const Record &rec, const FieldSelector &selector, bool remove_subfield_only = false);

// Replace the value of every `code` subfield in each matching field; when a
// matching field has none and `add_if_missing`, append one.  Control fields
// the selector matches are left untouched.
Record SetSubfield(const Record &rec, const FieldSelector &selector, const std::string &code,
                   const std::string &value, bool add_if_missing = true);

enum class ValueDomain { CONTROL, DATA, BOTH };

// std::regex_replace (ECMAScript, $1... backreferences, all occurrences)
// over the values of matching fields: control values when `which` admits
// CONTROL, subfield values when it admits DATA.  When the selector names a
// subfield_code only that code's values are rewritten.  Invalid patterns
// throw MarcError.
Record ReplaceInValues(const Record &rec, const FieldSelector &selector, const std::string &pattern,
                       const std::string &replacement, ValueDomain which = ValueDomain::BOTH, bool icase = false);

// Set ind1/ind2 (each std::nullopt = leave unchanged) on matching data
// fields; control fields the selector matches are left untouched.  Each
// indicator must be one Unicode scalar (throws MarcError otherwise).
Record SetIndicators(const Record &rec, const FieldSelector &selector, const std::optional<std::string> &ind1,
                     const std::optional<std::string> &ind2);

// Overlay merge in the spirit of vendor-record / FOLIO profile practice,
// implemented from first principles.  Each entry of the three tag lists is a
// tag pattern ('.' wildcards, validated like FieldSelector::tag); a tag of
// `incoming` is classified by the FIRST category that matches it, in the
// precedence order protected > replace > add > default_action:
//   * protected — base is authoritative: the incoming occurrences are
//     ignored and base's fields stay untouched;
//   * REPLACE — every base occurrence of that exact tag is removed and the
//     incoming occurrences are inserted where the base group was (or in tag
//     order when base had none);
//   * ADD — incoming occurrences are appended after the last base occurrence
//     of that exact tag (or inserted in tag order when base had none);
//   * KEEP — incoming occurrences are used only when base has NO occurrence
//     of that exact tag, in which case they are inserted in tag order.
// Incoming tags are processed in order of first appearance; within a tag the
// incoming field order is preserved.  Base fields whose tags never appear in
// `incoming` are always kept.  The result takes base's leader (incoming's
// when base's is empty).
enum class MergeAction { KEEP, REPLACE, ADD };

struct MergeProfile {
	std::vector<std::string> protected_tags;
	std::vector<std::string> replace_tags;
	std::vector<std::string> add_tags;
	MergeAction default_action = MergeAction::KEEP;
};

Record MergeRecords(const Record &base, const Record &incoming, const MergeProfile &profile);

// ---- extended editing (edit.cpp) -------------------------------------------

// Renumber every field whose tag matches `from_tagpat` ('.' wildcards,
// validated like FieldSelector::tag) to the literal `to_tag`, keeping each
// field's position, indicators and subfields exactly as they were.  A move
// across the control/data boundary (tag < "010" is control) would have to
// invent structure the field does not have, so it throws MarcError instead;
// `to_tag` may not contain wildcards.  No match is not an error.
Record MoveField(const Record &rec, const std::string &from_tagpat, const std::string &to_tag);

// Copy every field matching `tagpat` as a new `new_tag` field, the originals
// untouched; copies are inserted in tag order (AddField's default placement)
// preserving their source order.  Same wildcard and control/data-boundary
// rules as MoveField.
Record CopyField(const Record &rec, const std::string &tagpat, const std::string &new_tag);

// Exchange the tag numbers of two field sets in place: every field tagged
// `tag_a` becomes `tag_b` and vice versa, each field keeping its position,
// indicators and subfields exactly as they were.  Both tags are literal (no
// wildcards) and must sit on the same side of the control/data boundary
// (tag < "010" is control) — the MoveField rule, checked up front on the tag
// pair and again per field for records whose is_control disagrees with the
// tag.  An absent tag on either side (or tag_a == tag_b) is a no-op, not an
// error.
Record SwapFields(const Record &rec, const std::string &tag_a, const std::string &tag_b);

// Stable sort of the whole field list by tag ascending (the MARCSort
// operation): fields sharing a tag keep their relative occurrence order, and
// nothing inside a field changes.  Always succeeds.
Record SortFields(const Record &rec);

// Rename every `from_code` subfield to `to_code` on data fields matching
// `tagpat` ('.' wildcards), values and subfield order untouched — the
// subfield half of MarcEdit's Swap Field Data ($x → $z and friends).
// Control fields are never touched.  Each code must be exactly one Unicode
// scalar (MarcError otherwise); no match is a no-op.
Record RenameSubfield(const Record &rec, const std::string &tagpat, const std::string &from_code,
                      const std::string &to_code);

// One find-and-replace rule for ApplyReplaceRules: `tag` is a tag pattern
// ('.' wildcards), `code` scopes to one subfield code (std::nullopt = every
// code), `pattern`/`replacement` are the ReplaceInValues regex pair.
struct ReplaceRule {
	std::string tag = "...";
	std::optional<std::string> code;
	std::string pattern;
	std::string replacement;
};

// Apply a whole rules table in order — MarcEdit's "Replace All ... from an
// external list" as one call.  Each rule is one ReplaceInValues pass
// (ValueDomain::BOTH), so later rules see earlier rules' output.  An empty
// list returns the record unchanged; invalid tags or regexes throw MarcError
// naming the offending rule.
Record ApplyReplaceRules(const Record &rec, const std::vector<ReplaceRule> &rules);

// Letter-case rewriting of subfield values on matching data fields (control
// fields hold coded values and are never touched).  `code_or_all` names one
// subfield code, or "*" (or "") for every subfield.  TITLE upper-cases the
// first caseable letter after each separator and lower-cases the rest of the
// word.  The case map covers ASCII plus the Latin-1 Supplement letters (with
// ß→SS and ÿ↔Ÿ) ONLY — see edit.cpp for the honest boundary.
enum class CaseMode { UPPER, LOWER, TITLE };

Record ChangeCase(const Record &rec, const std::string &tagpat, const std::string &code_or_all, CaseMode mode);

// Build ONE new field from a breaker-style template line and insert it in
// tag order.  The template is a "=TAG  ii$a..." line (blank indicators as
// '\', literal '$' as {dollar}) in which every {tag$code} placeholder — tag
// may use '.' wildcards — is replaced by the record's first matching
// subfield value ("" when absent), e.g.
//   "=953  \\$a{245$a} / {100$a}".
// The substituted line must parse as exactly one field (MarcError
// otherwise); substituted values have '$' re-escaped so they stay literal.
Record BuildField(const Record &rec, const std::string &tmpl);

// Remove every field matching `tagpat` that has a `code` subfield whose
// value matches `regex` (ECMAScript std::regex, search semantics — anchor
// with ^...$ for a full match).  Convenience over RemoveFields with a
// subfield_code + value_regex selector; same validation and errors.
Record RemoveFieldsWhere(const Record &rec, const std::string &tagpat, const std::string &code,
                         const std::string &regex, bool icase = false);

// One field in MARC breaker line form ("=245  10$aTitle", "=001  cn123",
// blank indicators as '\', literal '$' as {dollar}) — round-trips through
// ParseBreaker.  Display helper for DiffRecords and friends.
std::string RenderFieldBreaker(const Field &f);

// Structural diff.  Fields pair by (tag, occurrence): the k-th occurrence of
// a tag in `a` pairs with the k-th in `b`, compared by rendered form.  A
// leader difference is reported as a CHANGED entry with tag "LDR" and no
// field numbers.  Entries are ordered by tag ascending (LDR first), then
// occurrence; field_no_* are 0-based indexes into the source records'
// `fields`, absent on the missing side.
enum class DiffKind { ADDED, REMOVED, CHANGED };

struct DiffEntry {
	DiffKind kind;
	std::string tag;
	std::optional<size_t> field_no_a, field_no_b;
	std::string rendered_a, rendered_b; // breaker form; empty when absent
};

std::vector<DiffEntry> DiffRecords(const Record &a, const Record &b);

} // namespace marc
