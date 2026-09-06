//! Clustering-key and extended-editing scalars.
//!
//! Clustering (OpenRefine-style key collision; group in SQL, see
//! src/macros/editing.sql):
//!   marc_fingerprint(v) -> VARCHAR
//!   marc_ngram_fingerprint(v, n) -> VARCHAR
//! Editing (fields in, fields out — compose in UPDATE/SELECT like the
//! marc_edit_scalars.cpp family):
//!   marc_move_field(fields, from_tagpat, to_tag)
//!   marc_copy_field(fields, tagpat, new_tag)
//!   marc_change_case(fields, tagpat, code_or_all, 'upper'|'lower'|'title')
//!   marc_build_field(fields, template)   -- "=953  \\$a{245$a} / {100$a}"
//!   marc_remove_fields_where(fields, tagpat, code, regex)
//! Tag patterns use '.' wildcards; invalid patterns/regexes/modes are errors.

#include "marc21_extension.hpp"

#include "duckdb.hpp"
#include "duckdb/main/extension/extension_loader.hpp"

#include "marc/cluster.hpp"
#include "marc/core.hpp"
#include "marc/edit.hpp"

namespace duckdb {
namespace {

// Same shared helpers as marc_edit_scalars.cpp (file-local there, so
// repeated here rather than widening that file's interface).

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

// ---------------------------------------------------------------------------
// Clustering keys
// ---------------------------------------------------------------------------

static void FingerprintExec(DataChunk &args, ExpressionState &, Vector &result) {
	UnaryExecutor::Execute<string_t, string_t>(args.data[0], result, args.size(), [&](string_t input) {
		return StringVector::AddString(result,
		                               marc::Fingerprint(std::string_view(input.GetData(), input.GetSize())));
	});
}

static void NgramFingerprintExec(DataChunk &args, ExpressionState &, Vector &result) {
	BinaryExecutor::Execute<string_t, int32_t, string_t>(
	    args.data[0], args.data[1], result, args.size(), [&](string_t input, int32_t n) {
		    if (n < 1) {
			    throw InvalidInputException("marc_ngram_fingerprint: n must be at least 1");
		    }
		    return StringVector::AddString(
		        result, marc::NgramFingerprint(std::string_view(input.GetData(), input.GetSize()),
		                                       static_cast<size_t>(n)));
	    });
}

// ---------------------------------------------------------------------------
// Extended editing
// ---------------------------------------------------------------------------

static void MoveFieldExec(DataChunk &args, ExpressionState &, Vector &result) {
	FieldsOp(args, result, [](marc::Record &rec, DataChunk &a, idx_t i) {
		return marc::MoveField(rec, StrArg(a, 1, i), StrArg(a, 2, i));
	});
}

static void CopyFieldExec(DataChunk &args, ExpressionState &, Vector &result) {
	FieldsOp(args, result, [](marc::Record &rec, DataChunk &a, idx_t i) {
		return marc::CopyField(rec, StrArg(a, 1, i), StrArg(a, 2, i));
	});
}

static void ChangeCaseExec(DataChunk &args, ExpressionState &, Vector &result) {
	FieldsOp(args, result, [](marc::Record &rec, DataChunk &a, idx_t i) {
		auto mode = StringUtil::Lower(StrArg(a, 3, i));
		marc::CaseMode cm;
		if (mode == "upper") {
			cm = marc::CaseMode::UPPER;
		} else if (mode == "lower") {
			cm = marc::CaseMode::LOWER;
		} else if (mode == "title") {
			cm = marc::CaseMode::TITLE;
		} else {
			throw InvalidInputException("marc_change_case: mode must be upper, lower or title");
		}
		return marc::ChangeCase(rec, StrArg(a, 1, i), StrArg(a, 2, i), cm);
	});
}

static void BuildFieldExec(DataChunk &args, ExpressionState &, Vector &result) {
	FieldsOp(args, result, [](marc::Record &rec, DataChunk &a, idx_t i) {
		return marc::BuildField(rec, StrArg(a, 1, i));
	});
}

static void RemoveFieldsWhereExec(DataChunk &args, ExpressionState &, Vector &result) {
	FieldsOp(args, result, [](marc::Record &rec, DataChunk &a, idx_t i) {
		return marc::RemoveFieldsWhere(rec, StrArg(a, 1, i), StrArg(a, 2, i), StrArg(a, 3, i));
	});
}

} // namespace

void RegisterMarcClusterScalars(ExtensionLoader &loader) {
	auto fields_type = LogicalType::LIST(MarcFieldStructType());
	auto V = LogicalType::VARCHAR;

	loader.RegisterFunction(ScalarFunction("marc_fingerprint", {V}, V, FingerprintExec));
	loader.RegisterFunction(
	    ScalarFunction("marc_ngram_fingerprint", {V, LogicalType::INTEGER}, V, NgramFingerprintExec));

	loader.RegisterFunction(ScalarFunction("marc_move_field", {fields_type, V, V}, fields_type, MoveFieldExec));
	loader.RegisterFunction(ScalarFunction("marc_copy_field", {fields_type, V, V}, fields_type, CopyFieldExec));
	loader.RegisterFunction(
	    ScalarFunction("marc_change_case", {fields_type, V, V, V}, fields_type, ChangeCaseExec));
	loader.RegisterFunction(ScalarFunction("marc_build_field", {fields_type, V}, fields_type, BuildFieldExec));
	loader.RegisterFunction(
	    ScalarFunction("marc_remove_fields_where", {fields_type, V, V, V}, fields_type, RemoveFieldsWhereExec));
}

} // namespace duckdb
