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
