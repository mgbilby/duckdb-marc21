//! Record-editing, merge/diff and identifier-normalization scalars.
//!
//! Editing functions take and return the nested `fields` value, so batch
//! edits compose in plain UPDATE/SELECT pipelines:
//!   marc_add_field(fields, f), marc_remove_fields(fields, tagpat),
//!   marc_remove_subfield(fields, tagpat, code),
//!   marc_set_subfield(fields, tagpat, code, value),
//!   marc_replace_values(fields, tagpat, code_or_null, regex, replacement),
//!   marc_set_indicators(fields, tagpat, ind1_or_null, ind2_or_null),
//!   marc_merge(base, incoming, protected_csv, replace_csv, add_csv, action)
//! Analysis:
//!   marc_diff(leader_a, fields_a, leader_b, fields_b) -> LIST(STRUCT)
//!   marc_isbn13/marc_issn/marc_lccn/marc_oclc/marc_naco(s) -> VARCHAR
//!   marc_matchkey(fields) -> VARCHAR
//! Invalid identifiers yield NULL; invalid tag patterns/regexes are errors.

#include "marc21_extension.hpp"

#include "duckdb.hpp"
#include "duckdb/main/extension/extension_loader.hpp"

#include "marc/core.hpp"
#include "marc/callnum.hpp"
#include "marc/catalog.hpp"
#include "marc/edit.hpp"
#include "marc/formats.hpp"
#include "marc/idnorm.hpp"

namespace duckdb {
namespace {

static Value FieldsArg(const Vector &v, idx_t i) {
	return const_cast<Vector &>(v).GetValue(i);
}

//! Wrap a fields-in/fields-out operation with shared NULL/error handling.
template <class OP>
static void FieldsOp(DataChunk &args, Vector &result, OP op) {
	for (idx_t i = 0; i < args.size(); i++) {
		auto fields = FieldsArg(args.data[0], i);
		if (fields.IsNull()) {
			result.SetValue(i, Value(result.GetType()));
			continue;
		}
		try {
			auto rec = MarcValuesToRecord(Value(LogicalType::VARCHAR), fields);
			result.SetValue(i, MarcFieldsToValue(op(rec, args, i)));
		} catch (marc::MarcError &e) {
			throw InvalidInputException("marc edit: %s", e.what());
		}
	}
	if (args.AllConstant()) {
		result.SetVectorType(VectorType::CONSTANT_VECTOR);
	}
}

static string StrArg(DataChunk &args, idx_t col, idx_t row) {
	auto v = args.data[col].GetValue(row);
	return v.IsNull() ? "" : v.ToString();
}

static std::optional<std::string> OptArg(DataChunk &args, idx_t col, idx_t row) {
	auto v = args.data[col].GetValue(row);
	if (v.IsNull()) {
		return std::nullopt;
	}
	return v.ToString();
}

// ---------------------------------------------------------------------------
// Editing
// ---------------------------------------------------------------------------

static void AddFieldExec(DataChunk &args, ExpressionState &, Vector &result) {
	FieldsOp(args, result, [](marc::Record &rec, DataChunk &a, idx_t i) {
		auto fv = a.data[1].GetValue(i);
		if (fv.IsNull()) {
			return rec;
		}
		// Reuse the list converter on a single-element list.
		auto one = Value::LIST(a.data[1].GetType(), {fv});
		auto tmp = MarcValuesToRecord(Value(LogicalType::VARCHAR), one);
		if (tmp.fields.empty()) {
			return rec;
		}
		return marc::AddField(rec, tmp.fields[0]);
	});
}

static void RemoveFieldsExec(DataChunk &args, ExpressionState &, Vector &result) {
	FieldsOp(args, result, [](marc::Record &rec, DataChunk &a, idx_t i) {
		marc::FieldSelector sel;
		sel.tag = StrArg(a, 1, i);
		return marc::RemoveFields(rec, sel);
	});
}

static void RemoveSubfieldExec(DataChunk &args, ExpressionState &, Vector &result) {
	FieldsOp(args, result, [](marc::Record &rec, DataChunk &a, idx_t i) {
		marc::FieldSelector sel;
		sel.tag = StrArg(a, 1, i);
		sel.subfield_code = StrArg(a, 2, i);
		return marc::RemoveFields(rec, sel, true);
	});
}

static void SetSubfieldExec(DataChunk &args, ExpressionState &, Vector &result) {
	FieldsOp(args, result, [](marc::Record &rec, DataChunk &a, idx_t i) {
		marc::FieldSelector sel;
		sel.tag = StrArg(a, 1, i);
		return marc::SetSubfield(rec, sel, StrArg(a, 2, i), StrArg(a, 3, i));
	});
}

static void ReplaceValuesExec(DataChunk &args, ExpressionState &, Vector &result) {
	FieldsOp(args, result, [](marc::Record &rec, DataChunk &a, idx_t i) {
		marc::FieldSelector sel;
		sel.tag = StrArg(a, 1, i);
		auto code = OptArg(a, 2, i);
		if (code) {
			sel.subfield_code = code;
		}
		return marc::ReplaceInValues(rec, sel, StrArg(a, 3, i), StrArg(a, 4, i));
	});
}

static void SetIndicatorsExec(DataChunk &args, ExpressionState &, Vector &result) {
	FieldsOp(args, result, [](marc::Record &rec, DataChunk &a, idx_t i) {
		marc::FieldSelector sel;
		sel.tag = StrArg(a, 1, i);
		return marc::SetIndicators(rec, sel, OptArg(a, 2, i), OptArg(a, 3, i));
	});
}

// ---------------------------------------------------------------------------
// Merge / diff
// ---------------------------------------------------------------------------

static std::vector<std::string> SplitTags(const string &csv) {
	std::vector<std::string> out;
	for (auto &t : StringUtil::Split(csv, ',')) {
		auto trimmed = t;
		StringUtil::Trim(trimmed);
		if (!trimmed.empty()) {
			out.push_back(trimmed);
		}
	}
	return out;
}

static void MergeExec(DataChunk &args, ExpressionState &, Vector &result) {
	for (idx_t i = 0; i < args.size(); i++) {
		auto base = args.data[0].GetValue(i);
		auto incoming = args.data[1].GetValue(i);
		if (base.IsNull() || incoming.IsNull()) {
			result.SetValue(i, base.IsNull() ? incoming : base);
			continue;
		}
		marc::MergeProfile profile;
		profile.protected_tags = SplitTags(StrArg(args, 2, i));
		profile.replace_tags = SplitTags(StrArg(args, 3, i));
		profile.add_tags = SplitTags(StrArg(args, 4, i));
		auto action = StringUtil::Lower(StrArg(args, 5, i));
		if (action == "replace") {
			profile.default_action = marc::MergeAction::REPLACE;
		} else if (action == "add") {
			profile.default_action = marc::MergeAction::ADD;
		} else if (action == "keep" || action.empty()) {
			profile.default_action = marc::MergeAction::KEEP;
		} else {
			throw InvalidInputException("marc_merge: default action must be keep, replace or add");
		}
		try {
			auto rec = marc::MergeRecords(MarcValuesToRecord(Value(LogicalType::VARCHAR), base),
			                              MarcValuesToRecord(Value(LogicalType::VARCHAR), incoming), profile);
			result.SetValue(i, MarcFieldsToValue(rec));
		} catch (marc::MarcError &e) {
			throw InvalidInputException("marc_merge: %s", e.what());
		}
	}
	if (args.AllConstant()) {
		result.SetVectorType(VectorType::CONSTANT_VECTOR);
	}
}

static const LogicalType &DiffEntryType() {
	static const LogicalType type = LogicalType::STRUCT({{"kind", LogicalType::VARCHAR},
	                                                     {"tag", LogicalType::VARCHAR},
	                                                     {"field_no_a", LogicalType::INTEGER},
	                                                     {"field_no_b", LogicalType::INTEGER},
	                                                     {"a", LogicalType::VARCHAR},
	                                                     {"b", LogicalType::VARCHAR}});
	return type;
}

static void DiffExec(DataChunk &args, ExpressionState &, Vector &result) {
	for (idx_t i = 0; i < args.size(); i++) {
		try {
			auto a = MarcValuesToRecord(args.data[0].GetValue(i), args.data[1].GetValue(i));
			auto b = MarcValuesToRecord(args.data[2].GetValue(i), args.data[3].GetValue(i));
			vector<Value> entries;
			for (auto &d : marc::DiffRecords(a, b)) {
				const char *kind = d.kind == marc::DiffKind::ADDED     ? "added"
				                   : d.kind == marc::DiffKind::REMOVED ? "removed"
				                                                       : "changed";
				entries.push_back(Value::STRUCT(
				    DiffEntryType(),
				    {Value(kind), Value(d.tag),
				     d.field_no_a ? Value::INTEGER(static_cast<int32_t>(*d.field_no_a)) : Value(LogicalType::INTEGER),
				     d.field_no_b ? Value::INTEGER(static_cast<int32_t>(*d.field_no_b)) : Value(LogicalType::INTEGER),
				     Value(d.rendered_a), Value(d.rendered_b)}));
			}
			result.SetValue(i, Value::LIST(DiffEntryType(), std::move(entries)));
		} catch (marc::MarcError &e) {
			throw InvalidInputException("marc_diff: %s", e.what());
		}
	}
	if (args.AllConstant()) {
		result.SetVectorType(VectorType::CONSTANT_VECTOR);
	}
}

// ---------------------------------------------------------------------------
// Identifier normalization
// ---------------------------------------------------------------------------

template <std::string (*FN)(std::string_view)>
static void NormalizeExec(DataChunk &args, ExpressionState &, Vector &result) {
	UnaryExecutor::ExecuteWithNulls<string_t, string_t>(
	    args.data[0], result, args.size(), [&](string_t input, ValidityMask &mask, idx_t idx) {
		    auto out = FN(std::string_view(input.GetData(), input.GetSize()));
		    if (out.empty()) {
			    mask.SetInvalid(idx);
			    return string_t();
		    }
		    return StringVector::AddString(result, out);
	    });
}

static void MatchKeyExec(DataChunk &args, ExpressionState &, Vector &result) {
	for (idx_t i = 0; i < args.size(); i++) {
		auto fields = args.data[0].GetValue(i);
		if (fields.IsNull()) {
			result.SetValue(i, Value(LogicalType::VARCHAR));
			continue;
		}
		auto key = marc::MatchKey(MarcValuesToRecord(Value(LogicalType::VARCHAR), fields));
		result.SetValue(i, key.empty() ? Value(LogicalType::VARCHAR) : Value(key));
	}
	if (args.AllConstant()) {
		result.SetVectorType(VectorType::CONSTANT_VECTOR);
	}
}

// ---------------------------------------------------------------------------
// Cataloging: ranking, templates, RDA helpers, call numbers
// ---------------------------------------------------------------------------

static const LogicalType &RankType() {
	static const LogicalType type = LogicalType::STRUCT({{"encoding_level_rank", LogicalType::INTEGER},
	                                                     {"completeness", LogicalType::INTEGER},
	                                                     {"total", LogicalType::INTEGER}});
	return type;
}

static void RankExec(DataChunk &args, ExpressionState &, Vector &result) {
	for (idx_t i = 0; i < args.size(); i++) {
		auto rec = MarcValuesToRecord(args.data[0].GetValue(i), args.data[1].GetValue(i));
		auto rank = marc::RankRecord(rec);
		result.SetValue(i, Value::STRUCT(RankType(), {Value::INTEGER(rank.encoding_level_rank),
		                                              Value::INTEGER(rank.completeness), Value::INTEGER(rank.total)}));
	}
	if (args.AllConstant()) {
		result.SetVectorType(VectorType::CONSTANT_VECTOR);
	}
}

static void Gen33xExec(DataChunk &args, ExpressionState &, Vector &result) {
	for (idx_t i = 0; i < args.size(); i++) {
		auto fields = args.data[1].GetValue(i);
		if (fields.IsNull()) {
			result.SetValue(i, fields);
			continue;
		}
		auto rec = MarcValuesToRecord(args.data[0].GetValue(i), fields);
		result.SetValue(i, MarcFieldsToValue(marc::Generate33X(rec)));
	}
	if (args.AllConstant()) {
		result.SetVectorType(VectorType::CONSTANT_VECTOR);
	}
}

static void RdaExpandExec(DataChunk &args, ExpressionState &, Vector &result) {
	FieldsOp(args, result, [](marc::Record &rec, DataChunk &, idx_t) { return marc::RdaExpandAbbreviations(rec); });
}

static const LogicalType &LccPartsType() {
	static const LogicalType type = LogicalType::STRUCT(
	    {{"class", LogicalType::VARCHAR},
	     {"number", LogicalType::VARCHAR},
	     {"decimal", LogicalType::VARCHAR},
	     {"cutters", LogicalType::LIST(LogicalType::VARCHAR)},
	     {"year", LogicalType::VARCHAR},
	     {"rest", LogicalType::VARCHAR},
	     {"valid", LogicalType::BOOLEAN}});
	return type;
}

static void LccParseExec(DataChunk &args, ExpressionState &, Vector &result) {
	for (idx_t i = 0; i < args.size(); i++) {
		auto v = args.data[0].GetValue(i);
		if (v.IsNull()) {
			result.SetValue(i, Value(LccPartsType()));
			continue;
		}
		auto parts = marc::ParseLcc(v.ToString());
		result.SetValue(i, Value::STRUCT(LccPartsType(),
		                                 {Value(parts.klass), Value(parts.number), Value(parts.decimal),
		                                  MarcStringsToList(parts.cutters), Value(parts.year), Value(parts.rest),
		                                  Value::BOOLEAN(parts.valid)}));
	}
	if (args.AllConstant()) {
		result.SetVectorType(VectorType::CONSTANT_VECTOR);
	}
}

template <std::string (*FN)(std::string_view)>
static void SortKeyExec(DataChunk &args, ExpressionState &, Vector &result) {
	UnaryExecutor::ExecuteWithNulls<string_t, string_t>(
	    args.data[0], result, args.size(), [&](string_t input, ValidityMask &mask, idx_t idx) {
		    auto out = FN(std::string_view(input.GetData(), input.GetSize()));
		    if (out.empty()) {
			    mask.SetInvalid(idx);
			    return string_t();
		    }
		    return StringVector::AddString(result, out);
	    });
}

static void CutterValidExec(DataChunk &args, ExpressionState &, Vector &result) {
	UnaryExecutor::Execute<string_t, bool>(args.data[0], result, args.size(), [](string_t input) {
		return marc::CutterValid(std::string_view(input.GetData(), input.GetSize()));
	});
}

static void NewRecordExec(DataChunk &args, ExpressionState &, Vector &result);

// marc_parse_json: one JSON record (community MARC-in-JSON or a FOLIO SRS
// parsedRecord envelope) as STRUCT(leader, fields) — the bridge that lets an
// ATTACHed FOLIO database's Source Record Storage rows join the marc_*
// surface directly.
static const LogicalType &ParsedRecordType() {
	static const LogicalType type = LogicalType::STRUCT(
	    {{"leader", LogicalType::VARCHAR}, {"fields", LogicalType::LIST(MarcFieldStructType())}});
	return type;
}

static void ParseJsonExec(DataChunk &args, ExpressionState &, Vector &result) {
	for (idx_t i = 0; i < args.size(); i++) {
		auto json = args.data[0].GetValue(i);
		if (json.IsNull()) {
			result.SetValue(i, Value(ParsedRecordType()));
			continue;
		}
		try {
			auto records = marc::ParseMarcJson(json.ToString());
			if (records.empty()) {
				result.SetValue(i, Value(ParsedRecordType()));
				continue;
			}
			result.SetValue(i, Value::STRUCT(ParsedRecordType(),
			                                 {Value(records[0].leader), MarcFieldsToValue(records[0])}));
		} catch (marc::MarcError &e) {
			throw InvalidInputException("marc_parse_json: %s", e.what());
		}
	}
	if (args.AllConstant()) {
		result.SetVectorType(VectorType::CONSTANT_VECTOR);
	}
}

static void NewRecordExec(DataChunk &args, ExpressionState &, Vector &result) {
	for (idx_t i = 0; i < args.size(); i++) {
		auto v = args.data[0].GetValue(i);
		if (v.IsNull()) {
			result.SetValue(i, Value(ParsedRecordType()));
			continue;
		}
		try {
			auto rec = marc::NewRecord(v.ToString());
			result.SetValue(i, Value::STRUCT(ParsedRecordType(), {Value(rec.leader), MarcFieldsToValue(rec)}));
		} catch (marc::MarcError &e) {
			throw InvalidInputException("marc_new_record: %s", e.what());
		}
	}
	if (args.AllConstant()) {
		result.SetVectorType(VectorType::CONSTANT_VECTOR);
	}
}

} // namespace

void RegisterMarcEditScalars(ExtensionLoader &loader) {
	auto fields_type = LogicalType::LIST(MarcFieldStructType());
	auto V = LogicalType::VARCHAR;

	loader.RegisterFunction(
	    ScalarFunction("marc_add_field", {fields_type, MarcFieldStructType()}, fields_type, AddFieldExec));
	loader.RegisterFunction(ScalarFunction("marc_remove_fields", {fields_type, V}, fields_type, RemoveFieldsExec));
	loader.RegisterFunction(
	    ScalarFunction("marc_remove_subfield", {fields_type, V, V}, fields_type, RemoveSubfieldExec));
	loader.RegisterFunction(
	    ScalarFunction("marc_set_subfield", {fields_type, V, V, V}, fields_type, SetSubfieldExec));
	loader.RegisterFunction(
	    ScalarFunction("marc_replace_values", {fields_type, V, V, V, V}, fields_type, ReplaceValuesExec));
	loader.RegisterFunction(
	    ScalarFunction("marc_set_indicators", {fields_type, V, V, V}, fields_type, SetIndicatorsExec));
	loader.RegisterFunction(
	    ScalarFunction("marc_merge", {fields_type, fields_type, V, V, V, V}, fields_type, MergeExec));
	loader.RegisterFunction(ScalarFunction("marc_diff", {V, fields_type, V, fields_type},
	                                       LogicalType::LIST(DiffEntryType()), DiffExec));

	loader.RegisterFunction(ScalarFunction("marc_isbn13", {V}, V, NormalizeExec<marc::NormalizeIsbn>));
	loader.RegisterFunction(ScalarFunction("marc_issn", {V}, V, NormalizeExec<marc::NormalizeIssn>));
	loader.RegisterFunction(ScalarFunction("marc_lccn", {V}, V, NormalizeExec<marc::NormalizeLccn>));
	loader.RegisterFunction(ScalarFunction("marc_oclc", {V}, V, NormalizeExec<marc::NormalizeOclc>));
	loader.RegisterFunction(ScalarFunction("marc_naco", {V}, V, NormalizeExec<marc::NacoNormalize>));
	loader.RegisterFunction(ScalarFunction("marc_matchkey", {fields_type}, V, MatchKeyExec));
	loader.RegisterFunction(ScalarFunction("marc_parse_json", {V}, ParsedRecordType(), ParseJsonExec));

	loader.RegisterFunction(ScalarFunction("marc_rank", {V, fields_type}, RankType(), RankExec));
	loader.RegisterFunction(ScalarFunction("marc_new_record", {V}, ParsedRecordType(), NewRecordExec));
	loader.RegisterFunction(ScalarFunction("marc_rda_expand", {fields_type}, fields_type, RdaExpandExec));
	loader.RegisterFunction(ScalarFunction("marc_generate_33x", {V, fields_type}, fields_type, Gen33xExec));
	loader.RegisterFunction(ScalarFunction("marc_lcc_parse", {V}, LccPartsType(), LccParseExec));
	loader.RegisterFunction(ScalarFunction("marc_lcc_sortkey", {V}, V, SortKeyExec<marc::LccSortKey>));
	loader.RegisterFunction(ScalarFunction("marc_ddc_sortkey", {V}, V, SortKeyExec<marc::DdcSortKey>));
	loader.RegisterFunction(ScalarFunction("marc_cutter_valid", {V}, LogicalType::BOOLEAN, CutterValidExec));
}

} // namespace duckdb
