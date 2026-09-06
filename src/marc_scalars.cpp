//! Scalar functions over the nested `fields` shape:
//!   marc_spec(leader, fields, spec)                    -> LIST(VARCHAR)
//!   marc_validate_avram(leader, fields, schema_json)   -> LIST(VARCHAR)
//! Both take the record as (leader, fields) so LDR specs and leader checks
//! work.  A constant spec/schema argument is parsed once at bind time.

#include "marc21_extension.hpp"
#include "marc/compat.hpp"

#include "duckdb.hpp"
#include "duckdb/main/extension/extension_loader.hpp"
#include "duckdb/planner/expression/bound_function_expression.hpp"

#include "marc/core.hpp"
#include "marc/query.hpp"

namespace duckdb {

namespace {
static idx_t StructChild(const LogicalType &type, const string &name) {
	auto &children = StructType::GetChildTypes(type);
	for (idx_t i = 0; i < children.size(); i++) {
		if (StringUtil::CIEquals(MarcName(children[i].first), name)) {
			return i;
		}
	}
	throw InvalidInputException("marc: fields value is missing STRUCT member \"%s\"", name);
}

static string ScalarOrSpace(const Value &v) {
	if (v.IsNull()) {
		return " ";
	}
	auto s = v.ToString();
	return s.empty() ? " " : s;
}

} // namespace

marc::Record MarcValuesToRecord(const Value &leader, const Value &fields) {
	marc::Record rec;
	if (!leader.IsNull()) {
		rec.leader = leader.ToString();
	}
	if (fields.IsNull()) {
		return rec;
	}
	auto &field_type = ListType::GetChildType(fields.type());
	idx_t f_tag = StructChild(field_type, "tag");
	idx_t f_ind1 = StructChild(field_type, "ind1");
	idx_t f_ind2 = StructChild(field_type, "ind2");
	idx_t f_value = StructChild(field_type, "value");
	idx_t f_subfields = StructChild(field_type, "subfields");
	for (auto &fv : ListValue::GetChildren(fields)) {
		if (fv.IsNull()) {
			continue;
		}
		auto &members = StructValue::GetChildren(fv);
		marc::Field field;
		field.tag = members[f_tag].IsNull() ? "" : members[f_tag].ToString();
		auto &control_value = members[f_value];
		auto &subfields = members[f_subfields];
		if (!control_value.IsNull() && subfields.IsNull()) {
			field.is_control = true;
			field.control_value = control_value.ToString();
		} else {
			field.ind1 = ScalarOrSpace(members[f_ind1]);
			field.ind2 = ScalarOrSpace(members[f_ind2]);
			if (!subfields.IsNull()) {
				auto &sf_type = ListType::GetChildType(subfields.type());
				idx_t sf_code = StructChild(sf_type, "code");
				idx_t sf_value = StructChild(sf_type, "value");
				for (auto &sv : ListValue::GetChildren(subfields)) {
					if (sv.IsNull()) {
						continue;
					}
					auto &sf = StructValue::GetChildren(sv);
					marc::Subfield out;
					out.code = ScalarOrSpace(sf[sf_code]);
					out.value = sf[sf_value].IsNull() ? "" : sf[sf_value].ToString();
					field.subfields.push_back(std::move(out));
				}
			}
		}
		rec.fields.push_back(std::move(field));
	}
	return rec;
}

Value MarcStringsToList(const std::vector<std::string> &strings) {
	vector<Value> values;
	values.reserve(strings.size());
	for (auto &s : strings) {
		values.emplace_back(s);
	}
	return Value::LIST(LogicalType::VARCHAR, std::move(values));
}

namespace {

// ---------------------------------------------------------------------------
// marc_spec
// ---------------------------------------------------------------------------

struct MarcSpecBindData : public FunctionData {
	// Set when the spec argument folds to a constant: validated once here.
	bool checked = false;

	unique_ptr<FunctionData> Copy() const override {
		auto copy = make_uniq<MarcSpecBindData>();
		copy->checked = checked;
		return std::move(copy);
	}
	bool Equals(const FunctionData &other) const override {
		return checked == other.Cast<MarcSpecBindData>().checked;
	}
};

static unique_ptr<FunctionData> MarcSpecBind(ClientContext &context, ScalarFunction &,
                                             vector<unique_ptr<Expression>> &arguments) {
	auto bind = make_uniq<MarcSpecBindData>();
	if (arguments[2]->IsFoldable()) {
		auto spec = ExpressionExecutor::EvaluateScalar(context, *arguments[2]);
		if (!spec.IsNull()) {
			try {
				marc::MarcSpecEvaluate(marc::Record {std::string(24, ' '), {}}, spec.ToString());
			} catch (marc::MarcError &e) {
				throw BinderException("marc_spec: %s", e.what());
			}
			bind->checked = true;
		}
	}
	return std::move(bind);
}

static void MarcSpecExec(DataChunk &args, ExpressionState &, Vector &result) {
	for (idx_t i = 0; i < args.size(); i++) {
		auto leader = args.data[0].GetValue(i);
		auto fields = args.data[1].GetValue(i);
		auto spec = args.data[2].GetValue(i);
		if (spec.IsNull()) {
			result.SetValue(i, Value(LogicalType::LIST(LogicalType::VARCHAR)));
			continue;
		}
		try {
			auto rec = MarcValuesToRecord(leader, fields);
			result.SetValue(i, MarcStringsToList(marc::MarcSpecEvaluate(rec, spec.ToString())));
		} catch (marc::MarcError &e) {
			throw InvalidInputException("marc_spec: %s", e.what());
		}
	}
	if (args.AllConstant()) {
		result.SetVectorType(VectorType::CONSTANT_VECTOR);
	}
}

// ---------------------------------------------------------------------------
// marc_validate_avram
// ---------------------------------------------------------------------------

struct AvramBindData : public FunctionData {
	// Parsed once at bind time when the schema argument is constant.
	shared_ptr<marc::AvramSchema> schema;

	unique_ptr<FunctionData> Copy() const override {
		auto copy = make_uniq<AvramBindData>();
		copy->schema = schema;
		return std::move(copy);
	}
	bool Equals(const FunctionData &other) const override {
		return schema == other.Cast<AvramBindData>().schema;
	}
};

static unique_ptr<FunctionData> AvramBind(ClientContext &context, ScalarFunction &,
                                          vector<unique_ptr<Expression>> &arguments) {
	auto bind = make_uniq<AvramBindData>();
	if (arguments[2]->IsFoldable()) {
		auto schema_json = ExpressionExecutor::EvaluateScalar(context, *arguments[2]);
		if (!schema_json.IsNull()) {
			try {
				bind->schema = make_shared_ptr<marc::AvramSchema>(marc::ParseAvramSchema(schema_json.ToString()));
			} catch (marc::MarcError &e) {
				throw BinderException("marc_validate_avram: %s", e.what());
			}
		}
	}
	return std::move(bind);
}

static void AvramExec(DataChunk &args, ExpressionState &state, Vector &result) {
	auto &func_expr = state.expr.Cast<BoundFunctionExpression>();
	auto &bind = func_expr.bind_info->Cast<AvramBindData>();
	for (idx_t i = 0; i < args.size(); i++) {
		auto leader = args.data[0].GetValue(i);
		auto fields = args.data[1].GetValue(i);
		try {
			marc::AvramSchema per_row;
			const marc::AvramSchema *schema = bind.schema.get();
			if (!schema) {
				auto schema_json = args.data[2].GetValue(i);
				if (schema_json.IsNull()) {
					result.SetValue(i, Value(LogicalType::LIST(LogicalType::VARCHAR)));
					continue;
				}
				per_row = marc::ParseAvramSchema(schema_json.ToString());
				schema = &per_row;
			}
			auto rec = MarcValuesToRecord(leader, fields);
			result.SetValue(i, MarcStringsToList(marc::AvramValidate(*schema, rec)));
		} catch (marc::MarcError &e) {
			throw InvalidInputException("marc_validate_avram: %s", e.what());
		}
	}
	if (args.AllConstant()) {
		result.SetVectorType(VectorType::CONSTANT_VECTOR);
	}
}

} // namespace

void RegisterMarcScalars(ExtensionLoader &loader) {
	auto fields_type = LogicalType::LIST(MarcFieldStructType());
	auto list_varchar = LogicalType::LIST(LogicalType::VARCHAR);

	ScalarFunction spec("marc_spec", {LogicalType::VARCHAR, fields_type, LogicalType::VARCHAR}, list_varchar,
	                    MarcSpecExec, MarcSpecBind);
	loader.RegisterFunction(spec);

	ScalarFunction avram("marc_validate_avram", {LogicalType::VARCHAR, fields_type, LogicalType::VARCHAR},
	                     list_varchar, AvramExec, AvramBind);
	loader.RegisterFunction(avram);
}

} // namespace duckdb
