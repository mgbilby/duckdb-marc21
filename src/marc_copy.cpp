//! COPY ... TO 'file.mrc' (FORMAT marc) — serialise query results as ISO 2709.
//!
//! Input shape: a `fields` column with the nested LIST(STRUCT(tag, ind1,
//! ind2, value, subfields LIST(STRUCT(code, value)))) layout produced by
//! read_marc(), plus an optional `leader` VARCHAR column.  Any other columns
//! (record_no, control_number, ...) are ignored, so
//!   COPY (SELECT * FROM read_marc('in.mrc')) TO 'out.mrc' (FORMAT marc)
//! round-trips.  Output is UTF-8 (leader/09 = 'a') with record lengths and
//! base addresses recomputed by the writer.

#include "marc21_extension.hpp"

#include "duckdb.hpp"
#include "duckdb/common/file_system.hpp"
#include "duckdb/function/copy_function.hpp"

#include "marc/core.hpp"
#include "marc/formats.hpp"

#include <mutex>

namespace duckdb {
namespace {

enum class MarcOutputFormat { ISO2709, MARCXML, MRK, MARCJSON };

struct MarcCopyBindData : public TableFunctionData {
	MarcOutputFormat format = MarcOutputFormat::ISO2709;
	bool marc8 = false;
	idx_t fields_col = DConstants::INVALID_INDEX;
	idx_t leader_col = DConstants::INVALID_INDEX;
	// Child positions inside the field / subfield STRUCTs.
	idx_t f_tag, f_ind1, f_ind2, f_value, f_subfields;
	idx_t sf_code, sf_value;
};

struct MarcCopyGlobalState : public GlobalFunctionData {
	std::mutex lock;
	unique_ptr<FileHandle> handle;
};

struct MarcCopyLocalState : public LocalFunctionData {};

static idx_t StructChild(const LogicalType &type, const string &name) {
	auto &children = StructType::GetChildTypes(type);
	for (idx_t i = 0; i < children.size(); i++) {
		if (StringUtil::CIEquals(children[i].first, name)) {
			return i;
		}
	}
	throw BinderException("COPY (FORMAT marc): fields column is missing STRUCT member \"%s\"", name);
}

static unique_ptr<FunctionData> MarcCopyBindFormat(MarcOutputFormat format, CopyFunctionBindInput &input,
                                                   const vector<string> &names,
                                                   const vector<LogicalType> &sql_types) {
	auto bind = make_uniq<MarcCopyBindData>();
	bind->format = format;
	for (idx_t i = 0; i < names.size(); i++) {
		if (StringUtil::CIEquals(names[i], "fields")) {
			bind->fields_col = i;
		} else if (StringUtil::CIEquals(names[i], "leader")) {
			bind->leader_col = i;
		}
	}
	if (bind->fields_col == DConstants::INVALID_INDEX) {
		throw BinderException("COPY (FORMAT marc) requires a \"fields\" column with the nested "
		                      "LIST(STRUCT(...)) layout produced by read_marc()");
	}
	auto &fields_type = sql_types[bind->fields_col];
	if (fields_type.id() != LogicalTypeId::LIST || ListType::GetChildType(fields_type).id() != LogicalTypeId::STRUCT) {
		throw BinderException("COPY (FORMAT marc): \"fields\" must be a LIST of STRUCTs");
	}
	auto &field_struct = ListType::GetChildType(fields_type);
	bind->f_tag = StructChild(field_struct, "tag");
	bind->f_ind1 = StructChild(field_struct, "ind1");
	bind->f_ind2 = StructChild(field_struct, "ind2");
	bind->f_value = StructChild(field_struct, "value");
	bind->f_subfields = StructChild(field_struct, "subfields");
	auto &subfields_type = StructType::GetChildTypes(field_struct)[bind->f_subfields].second;
	if (subfields_type.id() != LogicalTypeId::LIST ||
	    ListType::GetChildType(subfields_type).id() != LogicalTypeId::STRUCT) {
		throw BinderException("COPY (FORMAT marc): \"subfields\" must be a LIST of STRUCT(code, value)");
	}
	auto &sf_struct = ListType::GetChildType(subfields_type);
	bind->sf_code = StructChild(sf_struct, "code");
	bind->sf_value = StructChild(sf_struct, "value");

	for (auto &kv : input.info.options) {
		auto name = StringUtil::Lower(kv.first);
		if (name == "encoding" && format == MarcOutputFormat::ISO2709) {
			auto v = kv.second.empty() ? "" : StringUtil::Lower(kv.second[0].ToString());
			if (v == "marc8" || v == "marc-8") {
				bind->marc8 = true;
			} else if (v != "utf8" && v != "utf-8") {
				throw BinderException("COPY (FORMAT marc): unsupported encoding \"%s\" (utf8 or marc8)", v);
			}
		} else {
			throw BinderException("COPY (FORMAT marc): unknown option \"%s\"", kv.first);
		}
	}
	return std::move(bind);
}

template <MarcOutputFormat FMT>
static unique_ptr<FunctionData> MarcCopyBind(ClientContext &, CopyFunctionBindInput &input,
                                             const vector<string> &names, const vector<LogicalType> &sql_types) {
	return MarcCopyBindFormat(FMT, input, names, sql_types);
}

static unique_ptr<GlobalFunctionData> MarcCopyInitGlobal(ClientContext &context, FunctionData &bind_data,
                                                         const string &file_path) {
	auto state = make_uniq<MarcCopyGlobalState>();
	auto &fs = FileSystem::GetFileSystem(context);
	state->handle = fs.OpenFile(file_path, FileOpenFlags(FileOpenFlags::FILE_FLAGS_WRITE |
	                                                     FileOpenFlags::FILE_FLAGS_FILE_CREATE_NEW));
	auto &bind = bind_data.Cast<MarcCopyBindData>();
	if (bind.format == MarcOutputFormat::MARCXML) {
		string header = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
		                "<collection xmlns=\"http://www.loc.gov/MARC21/slim\">\n";
		state->handle->Write(const_cast<char *>(header.data()), header.size());
	}
	return std::move(state);
}

static unique_ptr<LocalFunctionData> MarcCopyInitLocal(ExecutionContext &, FunctionData &) {
	return make_uniq<MarcCopyLocalState>();
}

static string OneScalarOrSpace(const Value &v) {
	if (v.IsNull()) {
		return " ";
	}
	auto s = v.ToString();
	return s.empty() ? " " : s;
}

static marc::Record RowToRecord(const MarcCopyBindData &bind, DataChunk &input, idx_t row) {
	marc::Record rec;
	if (bind.leader_col != DConstants::INVALID_INDEX) {
		auto v = input.GetValue(bind.leader_col, row);
		if (!v.IsNull()) {
			rec.leader = v.ToString();
		}
	}
	if (rec.leader.size() != 24) {
		rec.leader = "00000nam a2200000 a 4500";
	}
	auto fields_value = input.GetValue(bind.fields_col, row);
	if (fields_value.IsNull()) {
		return rec;
	}
	for (auto &fv : ListValue::GetChildren(fields_value)) {
		if (fv.IsNull()) {
			continue;
		}
		auto &children = StructValue::GetChildren(fv);
		marc::Field field;
		field.tag = children[bind.f_tag].IsNull() ? "" : children[bind.f_tag].ToString();
		auto &control_value = children[bind.f_value];
		auto &subfields = children[bind.f_subfields];
		if (!control_value.IsNull() && subfields.IsNull()) {
			field.is_control = true;
			field.control_value = control_value.ToString();
		} else {
			field.ind1 = OneScalarOrSpace(children[bind.f_ind1]);
			field.ind2 = OneScalarOrSpace(children[bind.f_ind2]);
			if (!subfields.IsNull()) {
				for (auto &sv : ListValue::GetChildren(subfields)) {
					if (sv.IsNull()) {
						continue;
					}
					auto &sf = StructValue::GetChildren(sv);
					marc::Subfield out;
					out.code = OneScalarOrSpace(sf[bind.sf_code]);
					out.value = sf[bind.sf_value].IsNull() ? "" : sf[bind.sf_value].ToString();
					field.subfields.push_back(std::move(out));
				}
			}
		}
		rec.fields.push_back(std::move(field));
	}
	return rec;
}

static void MarcCopySink(ExecutionContext &, FunctionData &bind_data, GlobalFunctionData &gstate, LocalFunctionData &,
                         DataChunk &input) {
	auto &bind = bind_data.Cast<MarcCopyBindData>();
	auto &state = gstate.Cast<MarcCopyGlobalState>();
	string buffer;
	for (idx_t row = 0; row < input.size(); row++) {
		auto rec = RowToRecord(bind, input, row);
		try {
			switch (bind.format) {
			case MarcOutputFormat::ISO2709:
				buffer += bind.marc8 ? marc::WriteRecordMarc8(rec) : marc::WriteRecord(rec);
				break;
			case MarcOutputFormat::MARCXML:
				buffer += marc::WriteMarcXml(rec);
				buffer += "\n";
				break;
			case MarcOutputFormat::MRK:
				buffer += marc::WriteBreaker(rec);
				buffer += "\n";
				break;
			case MarcOutputFormat::MARCJSON:
				buffer += marc::WriteMarcJson(rec);
				buffer += "\n";
				break;
			}
		} catch (marc::MarcError &e) {
			throw InvalidInputException("COPY (FORMAT marc): %s", e.what());
		}
	}
	std::lock_guard<std::mutex> guard(state.lock);
	state.handle->Write(const_cast<char *>(buffer.data()), buffer.size());
}

static void MarcCopyCombine(ExecutionContext &, FunctionData &, GlobalFunctionData &, LocalFunctionData &) {
}

static void MarcCopyFinalize(ClientContext &, FunctionData &bind_data, GlobalFunctionData &gstate) {
	auto &state = gstate.Cast<MarcCopyGlobalState>();
	if (bind_data.Cast<MarcCopyBindData>().format == MarcOutputFormat::MARCXML) {
		string footer = "</collection>\n";
		state.handle->Write(const_cast<char *>(footer.data()), footer.size());
	}
	state.handle->Sync();
	state.handle.reset();
}

} // namespace

template <MarcOutputFormat FMT>
static void RegisterOne(ExtensionLoader &loader, const char *name, const char *ext) {
	CopyFunction function(name);
	function.copy_to_bind = MarcCopyBind<FMT>;
	function.copy_to_initialize_global = MarcCopyInitGlobal;
	function.copy_to_initialize_local = MarcCopyInitLocal;
	function.copy_to_sink = MarcCopySink;
	function.copy_to_combine = MarcCopyCombine;
	function.copy_to_finalize = MarcCopyFinalize;
	function.extension = ext;
	loader.RegisterFunction(function);
}

void RegisterMarcCopy(ExtensionLoader &loader) {
	RegisterOne<MarcOutputFormat::ISO2709>(loader, "marc", "mrc");
	RegisterOne<MarcOutputFormat::MARCXML>(loader, "marcxml", "xml");
	RegisterOne<MarcOutputFormat::MRK>(loader, "mrk", "mrk");
	RegisterOne<MarcOutputFormat::MARCJSON>(loader, "marcjson", "json");
}

} // namespace duckdb
