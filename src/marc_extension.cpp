//! DuckDB binding layer.
//!
//! Table functions over the DuckDB-free core in src/core/:
//!   read_marc(path, ...)            — one row per record, nested fields column
//!   read_marc_subfields(path, ...)  — one row per subfield
//!   read_marc_raw(path, ...)        — one row per record, original bytes
//!   read_marc_breaker(path, [tags]) — .mrk text, subfields shape
//!   read_marcxml(path, [tags])      — MARCXML, subfields shape
//! plus COPY (FORMAT marc) (marc_copy.cpp) and the SQL macro layer.
//!
//! The binary readers parallelise per file: a glob expands to work units that
//! threads claim from the global state, so record_no is 1-based within each
//! file and `file` is part of every reader's output.  Projection pushdown
//! skips character decoding when no projected column needs it.

#include "marc21_extension.hpp"
#include "marc/compat.hpp"

#include "duckdb.hpp"
#include "duckdb/common/compressed_file_system.hpp"
#include "duckdb/common/file_system.hpp"
#include "duckdb/common/gzip_file_system.hpp"
#include "duckdb/main/extension/extension_loader.hpp"
#include "duckdb/main/extension_helper.hpp"
#include "duckdb/main/settings.hpp"
#include "duckdb/parser/parsed_data/create_function_info.hpp"
#include "duckdb/parser/statement/create_statement.hpp"

#include "marc/core.hpp"
#include "marc/formats.hpp"
#include "marc/macros_sql.hpp"

#include <atomic>
#include <deque>
#include <mutex>
#include <unordered_set>

namespace duckdb {
namespace {

constexpr idx_t READ_CHUNK = 1ULL << 20;

// ---------------------------------------------------------------------------
// Streaming record source over DuckDB's FileSystem
// ---------------------------------------------------------------------------

static bool HasGzExtension(const string &path) {
	return StringUtil::EndsWith(StringUtil::Lower(path), ".gz");
}

static vector<string> ExpandPaths(ClientContext &context, const string &pattern) {
	auto &fs = FileSystem::GetFileSystem(context);
	vector<string> paths;
	if (!FileSystem::HasGlob(pattern)) {
		paths.push_back(pattern);
		return paths;
	}
	for (auto &info : fs.GlobFiles(pattern, FileGlobOptions::DISALLOW_EMPTY)) {
		paths.push_back(info.path);
	}
	std::sort(paths.begin(), paths.end());
	return paths;
}

//! One file, streamed; records split on RT with inter-record whitespace
//! skipped and a trailing RT-less fragment yielded so its error is visible.
class RecordStream {
public:
	RecordStream(ClientContext &context, const string &path) {
		auto &fs = FileSystem::GetFileSystem(context);
		auto handle = fs.OpenFile(path, FileOpenFlags(FileOpenFlags::FILE_FLAGS_READ));
		if (HasGzExtension(path)) {
			gzip_ = make_uniq<GZipFileSystem>();
			handle = gzip_->OpenCompressedFile(QueryContext(context), std::move(handle), false);
		}
		handle_ = std::move(handle);
	}

	//! Next raw record into `out`; false at end of file.
	bool NextRaw(string &out) {
		while (true) {
			size_t skip = 0;
			while (skip < buf_.size() && (buf_[skip] == 0x0A || buf_[skip] == 0x0D || buf_[skip] == 0x20)) {
				skip++;
			}
			if (skip > 0) {
				buf_.erase(0, skip);
			}
			size_t rt = buf_.find(static_cast<char>(marc::RT));
			if (rt != string::npos) {
				out = buf_.substr(0, rt + 1);
				buf_.erase(0, rt + 1);
				return true;
			}
			if (eof_) {
				if (buf_.empty()) {
					return false;
				}
				out = std::move(buf_);
				buf_.clear();
				return true;
			}
			auto old = buf_.size();
			buf_.resize(old + READ_CHUNK);
			auto n = handle_->Read(&buf_[old], READ_CHUNK);
			buf_.resize(old + static_cast<size_t>(std::max<int64_t>(n, 0)));
			if (n <= 0) {
				eof_ = true;
			}
		}
	}

private:
	unique_ptr<GZipFileSystem> gzip_; // must outlive the compressed handle
	unique_ptr<FileHandle> handle_;
	string buf_;
	bool eof_ = false;
};

// ---------------------------------------------------------------------------
// Shared bind plumbing
// ---------------------------------------------------------------------------

struct MarcBindData : public TableFunctionData {
	string path;
	marc::Encoding encoding = marc::Encoding::AUTO;
	bool has_tag_filter = false;
	std::unordered_set<string> tags;
	bool ignore_errors = false;

	bool KeepTag(const string &tag) const {
		return !has_tag_filter || tags.count(tag) > 0;
	}
};

static unique_ptr<FunctionData> BindCommon(ClientContext &context, TableFunctionBindInput &input, bool with_encoding) {
	if (!Settings::Get<EnableExternalAccessSetting>(DBConfig::GetConfig(context))) {
		throw PermissionException("Reading MARC files is disabled through configuration");
	}
	auto result = make_uniq<MarcBindData>();
	result->path = input.inputs[0].GetValue<string>();
	for (auto &kv : input.named_parameters) {
		auto name = StringUtil::Lower(MarcName(kv.first));
		if (name == "encoding" && with_encoding) {
			try {
				result->encoding = marc::ParseEncoding(kv.second.GetValue<string>());
			} catch (marc::MarcError &e) {
				throw BinderException("read_marc: %s", e.what());
			}
		} else if (name == "tags") {
			result->has_tag_filter = true;
			for (auto &t : StringUtil::Split(kv.second.GetValue<string>(), ',')) {
				auto trimmed = t;
				StringUtil::Trim(trimmed);
				if (!trimmed.empty()) {
					result->tags.insert(trimmed);
				}
			}
		} else if (name == "ignore_errors") {
			result->ignore_errors = kv.second.GetValue<bool>();
		}
	}
	return std::move(result);
}

//! One raw record plus its identity, handed from the splitter to a
//! decode thread.
struct RawWorkItem {
	string raw;
	int64_t record_no;
	idx_t path_idx;
};

//! Global state for the parallel binary readers.  A single reader (under
//! io_lock) splits raw records off the current file and hands them out in
//! batches with their exact per-file ordinals; parsing and character
//! decoding — where the time goes — run on every scan thread outside the
//! lock.  This parallelises within one large file, not just across files.
struct ScanGlobalState : public GlobalTableFunctionState {
	vector<string> paths;
	vector<column_t> column_ids;
	marc::DecodeMode mode = marc::DecodeMode::ALL;

	std::mutex io_lock;
	idx_t current_path = 0;
	unique_ptr<RecordStream> stream; // stream over paths[current_path - 1] once opened
	int64_t next_record_no = 1;
	bool exhausted = false;

	idx_t MaxThreads() const override {
		// The scheduler clamps this to the configured thread count.
		return 1ULL << 16;
	}
	bool Projected(column_t col) const {
		for (auto id : column_ids) {
			if (id == col) {
				return true;
			}
		}
		return false;
	}

	//! Fill up to `max_items` work items; false when the scan is done and
	//! nothing was produced.
	bool FillBatch(ClientContext &context, std::vector<RawWorkItem> &batch, idx_t max_items) {
		std::lock_guard<std::mutex> guard(io_lock);
		while (batch.size() < max_items && !exhausted) {
			if (!stream) {
				if (current_path >= paths.size()) {
					exhausted = true;
					break;
				}
				stream = make_uniq<RecordStream>(context, paths[current_path]);
				current_path++;
				next_record_no = 1;
			}
			RawWorkItem item;
			if (stream->NextRaw(item.raw)) {
				item.record_no = next_record_no++;
				item.path_idx = current_path - 1;
				batch.push_back(std::move(item));
			} else {
				stream.reset();
			}
		}
		return !batch.empty();
	}
};

//! Per-thread state: the claimed batch being decoded.
struct ScanLocalState : public LocalTableFunctionState {
	static constexpr idx_t BATCH = 48;
	std::vector<RawWorkItem> batch;
	idx_t batch_pos = 0;
	string raw;      // current item's bytes
	string path;     // current item's file
	int64_t record_no = 0;

	bool NextRaw(ClientContext &context, ScanGlobalState &global, string &out) {
		if (batch_pos >= batch.size()) {
			batch.clear();
			batch_pos = 0;
			if (!global.FillBatch(context, batch, BATCH)) {
				return false;
			}
		}
		auto &item = batch[batch_pos++];
		out = std::move(item.raw);
		record_no = item.record_no;
		path = global.paths[item.path_idx];
		return true;
	}
};

static unique_ptr<LocalTableFunctionState> ScanInitLocal(ExecutionContext &, TableFunctionInitInput &,
                                                         GlobalTableFunctionState *) {
	return make_uniq<ScanLocalState>();
}

// ---------------------------------------------------------------------------
// read_marc_subfields (and the text readers, which share its row shape)
// Columns: 0 record_no, 1 file, 2 control_number, 3 leader, 4 field_no,
//          5 tag, 6 ind1, 7 ind2, 8 subfield_no, 9 code, 10 value
// ---------------------------------------------------------------------------

struct SubfieldRow {
	int64_t record_no;
	string file;
	bool has_control_number;
	string control_number;
	string leader;
	int32_t field_no;
	string tag;
	bool is_control;
	string ind1, ind2;
	int32_t subfield_no;
	string code;
	string value;
};

static void PushRecordRows(const marc::Record &rec, int64_t record_no, const string &file, const MarcBindData &bind,
                           std::deque<SubfieldRow> &out) {
	const std::string *cn = rec.ControlNumber();
	int32_t field_no = 0;
	for (auto &f : rec.fields) {
		field_no++;
		if (!bind.KeepTag(f.tag)) {
			continue;
		}
		SubfieldRow base;
		base.record_no = record_no;
		base.file = file;
		base.has_control_number = cn != nullptr;
		base.control_number = cn ? *cn : "";
		base.leader = rec.leader;
		base.field_no = field_no;
		base.tag = f.tag;
		base.is_control = f.is_control;
		if (f.is_control) {
			base.subfield_no = 1;
			base.value = f.control_value;
			out.push_back(std::move(base));
		} else {
			int32_t subfield_no = 0;
			for (auto &sf : f.subfields) {
				subfield_no++;
				SubfieldRow row = base;
				row.ind1 = f.ind1;
				row.ind2 = f.ind2;
				row.subfield_no = subfield_no;
				row.code = sf.code;
				row.value = sf.value;
				out.push_back(std::move(row));
			}
		}
	}
}

//! Write one vector's worth of pending rows into the (projected) output.
static void EmitSubfieldRows(std::deque<SubfieldRow> &pending, const vector<column_t> &column_ids, DataChunk &output) {
	idx_t n = MinValue<idx_t>(pending.size(), STANDARD_VECTOR_SIZE);
	output.SetCardinality(n);
	if (n == 0) {
		return;
	}
	for (idx_t out_col = 0; out_col < column_ids.size(); out_col++) {
		auto col = column_ids[out_col];
		auto &vec = output.data[out_col];
		for (idx_t i = 0; i < n; i++) {
			auto &row = pending[i];
			switch (col) {
			case 0:
				FlatVector::GetData<int64_t>(vec)[i] = row.record_no;
				break;
			case 1:
				FlatVector::GetData<string_t>(vec)[i] = StringVector::AddString(vec, row.file);
				break;
			case 2:
				if (row.has_control_number) {
					FlatVector::GetData<string_t>(vec)[i] = StringVector::AddString(vec, row.control_number);
				} else {
					FlatVector::SetNull(vec, i, true);
				}
				break;
			case 3:
				FlatVector::GetData<string_t>(vec)[i] = StringVector::AddString(vec, row.leader);
				break;
			case 4:
				FlatVector::GetData<int32_t>(vec)[i] = row.field_no;
				break;
			case 5:
				FlatVector::GetData<string_t>(vec)[i] = StringVector::AddString(vec, row.tag);
				break;
			case 6:
			case 7:
			case 9: {
				if (row.is_control) {
					FlatVector::SetNull(vec, i, true);
				} else {
					auto &s = col == 6 ? row.ind1 : (col == 7 ? row.ind2 : row.code);
					FlatVector::GetData<string_t>(vec)[i] = StringVector::AddString(vec, s);
				}
				break;
			}
			case 8:
				FlatVector::GetData<int32_t>(vec)[i] = row.subfield_no;
				break;
			case 10:
				FlatVector::GetData<string_t>(vec)[i] = StringVector::AddString(vec, row.value);
				break;
			default:
				FlatVector::SetNull(vec, i, true);
				break;
			}
		}
	}
	pending.erase(pending.begin(), pending.begin() + static_cast<int64_t>(n));
}

static void AddSubfieldColumns(vector<LogicalType> &types, MarcBindNames &names) {
	types = {LogicalType::BIGINT,  LogicalType::VARCHAR, LogicalType::VARCHAR, LogicalType::VARCHAR,
	         LogicalType::INTEGER, LogicalType::VARCHAR, LogicalType::VARCHAR, LogicalType::VARCHAR,
	         LogicalType::INTEGER, LogicalType::VARCHAR, LogicalType::VARCHAR};
	names = {"record_no", "file", "control_number", "leader", "field_no", "tag",
	         "ind1",      "ind2", "subfield_no",    "code",   "value"};
}

//! Decode only what the projection needs: `value` forces full decoding,
//! `control_number` alone needs just the control fields.
static marc::DecodeMode ModeForProjection(const ScanGlobalState &state, column_t value_col, column_t cn_col) {
	if (state.Projected(value_col)) {
		return marc::DecodeMode::ALL;
	}
	if (state.Projected(cn_col)) {
		return marc::DecodeMode::CONTROL_ONLY;
	}
	return marc::DecodeMode::NONE;
}

struct SubfieldsGlobalState : public ScanGlobalState {
	// Per-thread pending queues live in the local state instead.
};

struct SubfieldsLocalState : public ScanLocalState {
	std::deque<SubfieldRow> pending;
};

static unique_ptr<FunctionData> SubfieldsBind(ClientContext &context, TableFunctionBindInput &input,
                                              vector<LogicalType> &types, MarcBindNames &names) {
	AddSubfieldColumns(types, names);
	return BindCommon(context, input, true);
}

static unique_ptr<GlobalTableFunctionState> SubfieldsInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
	auto state = make_uniq<SubfieldsGlobalState>();
	state->paths = ExpandPaths(context, input.bind_data->Cast<MarcBindData>().path);
	state->column_ids = input.column_ids;
	state->mode = ModeForProjection(*state, 10, 2);
	return std::move(state);
}

static unique_ptr<LocalTableFunctionState> SubfieldsInitLocal(ExecutionContext &, TableFunctionInitInput &,
                                                              GlobalTableFunctionState *) {
	return make_uniq<SubfieldsLocalState>();
}

static void SubfieldsScan(ClientContext &context, TableFunctionInput &data, DataChunk &output) {
	auto &bind = data.bind_data->Cast<MarcBindData>();
	auto &global = data.global_state->Cast<SubfieldsGlobalState>();
	auto &local = data.local_state->Cast<SubfieldsLocalState>();

	string raw;
	while (local.pending.size() < STANDARD_VECTOR_SIZE && local.NextRaw(context, global, raw)) {
		try {
			auto rec = marc::ParseRecord(raw, bind.encoding, global.mode);
			PushRecordRows(rec, local.record_no, local.path, bind, local.pending);
		} catch (marc::MarcError &e) {
			if (!bind.ignore_errors) {
				throw InvalidInputException("read_marc_subfields: %s record %lld: %s", local.path.c_str(),
				                            local.record_no, e.what());
			}
		}
	}
	EmitSubfieldRows(local.pending, global.column_ids, output);
}

// ---------------------------------------------------------------------------
// read_marc — one row per record with the nested fields column
// Columns: 0 record_no, 1 file, 2 control_number, 3 leader, 4 fields
// ---------------------------------------------------------------------------

static const LogicalType &SubfieldStructType() {
	static const LogicalType type =
	    LogicalType::STRUCT({{"code", LogicalType::VARCHAR}, {"value", LogicalType::VARCHAR}});
	return type;
}

static const LogicalType &FieldStructType() {
	static const LogicalType type = LogicalType::STRUCT({{"tag", LogicalType::VARCHAR},
	                                                     {"ind1", LogicalType::VARCHAR},
	                                                     {"ind2", LogicalType::VARCHAR},
	                                                     {"value", LogicalType::VARCHAR},
	                                                     {"subfields", LogicalType::LIST(SubfieldStructType())}});
	return type;
}

static Value FieldsToValue(const marc::Record &rec, const MarcBindData &bind) {
	vector<Value> fields;
	fields.reserve(rec.fields.size());
	for (auto &f : rec.fields) {
		if (!bind.KeepTag(f.tag)) {
			continue;
		}
		vector<Value> members;
		members.emplace_back(f.tag);
		if (f.is_control) {
			members.emplace_back(Value(LogicalType::VARCHAR));
			members.emplace_back(Value(LogicalType::VARCHAR));
			members.emplace_back(f.control_value);
			members.emplace_back(Value(LogicalType::LIST(SubfieldStructType())));
		} else {
			members.emplace_back(f.ind1);
			members.emplace_back(f.ind2);
			members.emplace_back(Value(LogicalType::VARCHAR));
			vector<Value> subfields;
			subfields.reserve(f.subfields.size());
			for (auto &sf : f.subfields) {
				subfields.push_back(Value::STRUCT({{"code", Value(sf.code)}, {"value", Value(sf.value)}}));
			}
			members.emplace_back(Value::LIST(SubfieldStructType(), std::move(subfields)));
		}
		fields.push_back(Value::STRUCT(FieldStructType(), std::move(members)));
	}
	return Value::LIST(FieldStructType(), std::move(fields));
}

struct NestedGlobalState : public ScanGlobalState {};

static unique_ptr<FunctionData> NestedBind(ClientContext &context, TableFunctionBindInput &input,
                                           vector<LogicalType> &types, MarcBindNames &names) {
	types = {LogicalType::BIGINT, LogicalType::VARCHAR, LogicalType::VARCHAR, LogicalType::VARCHAR,
	         LogicalType::LIST(FieldStructType())};
	names = {"record_no", "file", "control_number", "leader", "fields"};
	return BindCommon(context, input, true);
}

static unique_ptr<GlobalTableFunctionState> NestedInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
	auto state = make_uniq<NestedGlobalState>();
	state->paths = ExpandPaths(context, input.bind_data->Cast<MarcBindData>().path);
	state->column_ids = input.column_ids;
	// The nested fields column carries every value; anything less than full
	// decoding would change it.
	state->mode = state->Projected(4) ? marc::DecodeMode::ALL : ModeForProjection(*state, COLUMN_IDENTIFIER_ROW_ID, 2);
	return std::move(state);
}

static void NestedScan(ClientContext &context, TableFunctionInput &data, DataChunk &output) {
	auto &bind = data.bind_data->Cast<MarcBindData>();
	auto &global = data.global_state->Cast<NestedGlobalState>();
	auto &local = data.local_state->Cast<ScanLocalState>();

	idx_t n = 0;
	string raw;
	while (n < STANDARD_VECTOR_SIZE && local.NextRaw(context, global, raw)) {
		marc::Record rec;
		try {
			rec = marc::ParseRecord(raw, bind.encoding, global.mode);
		} catch (marc::MarcError &e) {
			if (bind.ignore_errors) {
				continue;
			}
			throw InvalidInputException("read_marc: %s record %lld: %s", local.path.c_str(), local.record_no,
			                            e.what());
		}
		for (idx_t out_col = 0; out_col < global.column_ids.size(); out_col++) {
			switch (global.column_ids[out_col]) {
			case 0:
				output.SetValue(out_col, n, Value::BIGINT(local.record_no));
				break;
			case 1:
				output.SetValue(out_col, n, Value(local.path));
				break;
			case 2: {
				auto cn = rec.ControlNumber();
				output.SetValue(out_col, n, cn ? Value(*cn) : Value(LogicalType::VARCHAR));
				break;
			}
			case 3:
				output.SetValue(out_col, n, Value(rec.leader));
				break;
			case 4:
				output.SetValue(out_col, n, FieldsToValue(rec, bind));
				break;
			default:
				break;
			}
		}
		n++;
	}
	output.SetCardinality(n);
}

// ---------------------------------------------------------------------------
// read_marc_raw
// Columns: 0 record_no, 1 file, 2 control_number, 3 leader, 4 raw, 5 error
// ---------------------------------------------------------------------------

struct RawGlobalState : public ScanGlobalState {};

static unique_ptr<FunctionData> RawBind(ClientContext &context, TableFunctionBindInput &input,
                                        vector<LogicalType> &types, MarcBindNames &names) {
	types = {LogicalType::BIGINT, LogicalType::VARCHAR, LogicalType::VARCHAR,
	         LogicalType::VARCHAR, LogicalType::BLOB,   LogicalType::VARCHAR};
	names = {"record_no", "file", "control_number", "leader", "raw", "error"};
	return BindCommon(context, input, true);
}

static unique_ptr<GlobalTableFunctionState> RawInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
	auto state = make_uniq<RawGlobalState>();
	state->paths = ExpandPaths(context, input.bind_data->Cast<MarcBindData>().path);
	state->column_ids = input.column_ids;
	state->mode = state->Projected(2) ? marc::DecodeMode::CONTROL_ONLY : marc::DecodeMode::NONE;
	return std::move(state);
}

static void RawScan(ClientContext &context, TableFunctionInput &data, DataChunk &output) {
	auto &bind = data.bind_data->Cast<MarcBindData>();
	auto &global = data.global_state->Cast<RawGlobalState>();
	auto &local = data.local_state->Cast<ScanLocalState>();

	idx_t n = 0;
	string raw;
	while (n < STANDARD_VECTOR_SIZE && local.NextRaw(context, global, raw)) {
		bool parsed = true;
		string error;
		marc::Record rec;
		try {
			rec = marc::ParseRecord(raw, bind.encoding, global.mode);
		} catch (marc::MarcError &e) {
			parsed = false;
			error = e.what();
		}
		for (idx_t out_col = 0; out_col < global.column_ids.size(); out_col++) {
			auto &vec = output.data[out_col];
			switch (global.column_ids[out_col]) {
			case 0:
				FlatVector::GetData<int64_t>(vec)[n] = local.record_no;
				break;
			case 1:
				FlatVector::GetData<string_t>(vec)[n] = StringVector::AddString(vec, local.path);
				break;
			case 2: {
				auto cn = parsed ? rec.ControlNumber() : nullptr;
				if (cn) {
					FlatVector::GetData<string_t>(vec)[n] = StringVector::AddString(vec, *cn);
				} else {
					FlatVector::SetNull(vec, n, true);
				}
				break;
			}
			case 3:
				if (parsed) {
					FlatVector::GetData<string_t>(vec)[n] = StringVector::AddString(vec, rec.leader);
				} else if (raw.size() >= 24) {
					FlatVector::GetData<string_t>(vec)[n] = StringVector::AddString(
					    vec, marc::Latin1ToUtf8(std::string_view(raw).substr(0, 24)));
				} else {
					FlatVector::SetNull(vec, n, true);
				}
				break;
			case 4:
				FlatVector::GetData<string_t>(vec)[n] = StringVector::AddStringOrBlob(vec, raw);
				break;
			case 5:
				if (parsed) {
					FlatVector::SetNull(vec, n, true);
				} else {
					FlatVector::GetData<string_t>(vec)[n] = StringVector::AddString(vec, error);
				}
				break;
			default:
				FlatVector::SetNull(vec, n, true);
				break;
			}
		}
		n++;
	}
	output.SetCardinality(n);
}

// ---------------------------------------------------------------------------
// read_marc_breaker / read_marcxml — streamed record-at-a-time, glob-parallel
// like the binary readers.  A text "record" is a bounded slice of the input
// (=LDR to =LDR for breaker, <record> element for MARCXML) handed to the core
// parser, so memory stays proportional to one record, not the file.
// ---------------------------------------------------------------------------

//! Chunked reader over a (possibly gzipped) text file.
class TextChunkReader {
public:
	TextChunkReader(ClientContext &context, const string &path) {
		auto &fs = FileSystem::GetFileSystem(context);
		auto handle = fs.OpenFile(path, FileOpenFlags(FileOpenFlags::FILE_FLAGS_READ));
		if (HasGzExtension(path)) {
			gzip_ = make_uniq<GZipFileSystem>();
			handle = gzip_->OpenCompressedFile(QueryContext(context), std::move(handle), false);
		}
		handle_ = std::move(handle);
	}

	//! Append more bytes to `buf`; false at end of file.
	bool Fill(string &buf) {
		if (eof_) {
			return false;
		}
		auto old = buf.size();
		buf.resize(old + READ_CHUNK);
		auto n = handle_->Read(&buf[old], READ_CHUNK);
		buf.resize(old + static_cast<size_t>(std::max<int64_t>(n, 0)));
		if (n <= 0) {
			eof_ = true;
		}
		return n > 0;
	}

private:
	unique_ptr<GZipFileSystem> gzip_;
	unique_ptr<FileHandle> handle_;
	bool eof_ = false;
};

//! Yields one record's worth of text at a time.
class TextRecordSource {
public:
	TextRecordSource(ClientContext &context, const string &path, bool xml)
	    : reader_(context, path), xml_(xml) {
	}

	bool Next(string &out) {
		while (true) {
			size_t end;
			if (FindBoundary(end)) {
				out = buf_.substr(0, end);
				buf_.erase(0, end);
				return true;
			}
			if (!reader_.Fill(buf_)) {
				if (drained_) {
					return false;
				}
				drained_ = true;
				if (buf_.empty()) {
					return false;
				}
				out = std::move(buf_);
				buf_.clear();
				return true;
			}
		}
	}

private:
	//! End offset of the first complete record in the buffer, if any.
	bool FindBoundary(size_t &end) {
		if (xml_) {
			// A record ends at "</record>" (any namespace prefix).
			size_t pos = 0;
			while ((pos = buf_.find("record>", pos)) != string::npos) {
				size_t name_start = pos;
				while (name_start > 0 &&
				       (isalnum(static_cast<unsigned char>(buf_[name_start - 1])) || buf_[name_start - 1] == ':' ||
				        buf_[name_start - 1] == '.' || buf_[name_start - 1] == '_' || buf_[name_start - 1] == '-')) {
					name_start--;
				}
				if (name_start >= 2 && buf_.compare(name_start - 2, 2, "</") == 0 &&
				    (name_start == pos || buf_[pos - 1] == ':')) {
					end = pos + 7;
					return true;
				}
				pos += 7;
			}
			return false;
		}
		// Breaker: a record ends where the NEXT "=LDR" line begins.
		size_t search = 0;
		bool past_first = false;
		while (true) {
			size_t ldr = buf_.compare(0, 4, "=LDR") == 0 && search == 0 ? 0 : buf_.find("\n=LDR", search);
			if (ldr == string::npos) {
				return false;
			}
			if (ldr == 0 && !past_first) {
				past_first = true;
				search = 1;
				continue;
			}
			if (ldr != 0) {
				if (past_first || HasContentBefore(ldr + 1)) {
					end = ldr + 1;
					return true;
				}
				past_first = true;
				search = ldr + 1;
				continue;
			}
			return false;
		}
	}

	//! Whether any field line precedes offset `limit` (a leaderless record).
	bool HasContentBefore(size_t limit) const {
		for (size_t i = 0; i < limit && i < buf_.size(); i++) {
			if (buf_[i] == '=') {
				return true;
			}
			if (buf_[i] != '\n' && buf_[i] != '\r' && buf_[i] != ' ' && buf_[i] != '\t') {
				return false;
			}
			// skip to end of a non-field line
			if (buf_[i] != '\n') {
				while (i < limit && buf_[i] != '\n') {
					i++;
				}
			}
		}
		return false;
	}

	TextChunkReader reader_;
	bool xml_;
	string buf_;
	bool drained_ = false;
};

struct TextGlobalState : public ScanGlobalState {
	std::atomic<idx_t> next_text_path {0}; // text readers keep per-file sources
};

struct TextLocalState : public LocalTableFunctionState {
	unique_ptr<TextRecordSource> source;
	string path;
	int64_t record_no = 0;
	std::deque<SubfieldRow> pending;

	bool NextRecordText(ClientContext &context, TextGlobalState &global, bool xml, string &out) {
		while (true) {
			if (source && source->Next(out)) {
				return true;
			}
			auto idx = global.next_text_path.fetch_add(1);
			if (idx >= global.paths.size()) {
				source.reset();
				return false;
			}
			path = global.paths[idx];
			source = make_uniq<TextRecordSource>(context, path, xml);
			record_no = 0;
		}
	}
};

static unique_ptr<FunctionData> TextBind(ClientContext &context, TableFunctionBindInput &input,
                                         vector<LogicalType> &types, MarcBindNames &names) {
	AddSubfieldColumns(types, names);
	return BindCommon(context, input, false);
}

static unique_ptr<GlobalTableFunctionState> TextInitGlobal(ClientContext &context, TableFunctionInitInput &input) {
	auto state = make_uniq<TextGlobalState>();
	state->paths = ExpandPaths(context, input.bind_data->Cast<MarcBindData>().path);
	state->column_ids = input.column_ids;
	return std::move(state);
}

static unique_ptr<LocalTableFunctionState> TextInitLocal(ExecutionContext &, TableFunctionInitInput &,
                                                         GlobalTableFunctionState *) {
	return make_uniq<TextLocalState>();
}

template <std::vector<marc::Record> (*PARSE)(std::string_view), const char *FN_NAME, bool XML>
static void TextScan(ClientContext &context, TableFunctionInput &data, DataChunk &output) {
	auto &bind = data.bind_data->Cast<MarcBindData>();
	auto &global = data.global_state->Cast<TextGlobalState>();
	auto &local = data.local_state->Cast<TextLocalState>();

	string text;
	while (local.pending.size() < STANDARD_VECTOR_SIZE && local.NextRecordText(context, global, XML, text)) {
		std::vector<marc::Record> records;
		try {
			records = PARSE(text);
		} catch (marc::MarcError &e) {
			throw InvalidInputException("%s: %s: %s", FN_NAME, local.path.c_str(), e.what());
		}
		for (auto &rec : records) {
			PushRecordRows(rec, ++local.record_no, local.path, bind, local.pending);
		}
	}
	EmitSubfieldRows(local.pending, global.column_ids, output);
}


//! Whole-file text formats (JSON, Aleph sequential): each glob match is one
//! work unit; the file is read fully, parsed, and emitted as subfield rows.
struct WholeFileLocalState : public LocalTableFunctionState {
	string path;
	std::deque<SubfieldRow> pending;
};

static unique_ptr<LocalTableFunctionState> WholeFileInitLocal(ExecutionContext &, TableFunctionInitInput &,
                                                              GlobalTableFunctionState *) {
	return make_uniq<WholeFileLocalState>();
}

template <std::vector<marc::Record> (*PARSE)(std::string_view), const char *FN_NAME>
static void WholeFileScan(ClientContext &context, TableFunctionInput &data, DataChunk &output) {
	auto &bind = data.bind_data->Cast<MarcBindData>();
	auto &global = data.global_state->Cast<TextGlobalState>();
	auto &local = data.local_state->Cast<WholeFileLocalState>();

	while (local.pending.empty()) {
		auto idx = global.next_text_path.fetch_add(1);
		if (idx >= global.paths.size()) {
			break;
		}
		local.path = global.paths[idx];
		TextChunkReader reader(context, local.path);
		string text;
		while (reader.Fill(text)) {
		}
		std::vector<marc::Record> records;
		try {
			records = PARSE(text);
		} catch (marc::MarcError &e) {
			throw InvalidInputException("%s: %s: %s", FN_NAME, local.path.c_str(), e.what());
		}
		int64_t record_no = 0;
		for (auto &rec : records) {
			PushRecordRows(rec, ++record_no, local.path, bind, local.pending);
		}
	}
	EmitSubfieldRows(local.pending, global.column_ids, output);
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

constexpr char BREAKER_NAME[] = "read_marc_breaker";
constexpr char MARCJSON_NAME[] = "read_marcjson_file";
constexpr char ALEPH_NAME[] = "read_alephseq";
constexpr char MICROLIF_NAME[] = "read_microlif";
constexpr char MARCXML_NAME[] = "read_marcxml";

//! The macro a statement of the embedded SQL defines, for error messages.
//! Anything else falls back to the statement's own first line, so a failure
//! always points at something.
string MacroLabel(const SQLStatement &statement) {
	if (statement.type == StatementType::CREATE_STATEMENT) {
		auto &info = *statement.Cast<CreateStatement>().info;
		if (info.type == CatalogType::MACRO_ENTRY || info.type == CatalogType::TABLE_MACRO_ENTRY) {
			return info.Cast<CreateFunctionInfo>().name;
		}
	}
	auto text = statement.query.substr(statement.stmt_location, statement.stmt_length);
	auto line_end = text.find('\n');
	return line_end == string::npos ? text : text.substr(0, line_end);
}

void LoadInternal(ExtensionLoader &loader) {
	TableFunction nested("read_marc", {LogicalType::VARCHAR}, NestedScan, NestedBind, NestedInitGlobal, ScanInitLocal);
	nested.named_parameters["encoding"] = LogicalType::VARCHAR;
	nested.named_parameters["tags"] = LogicalType::VARCHAR;
	nested.named_parameters["ignore_errors"] = LogicalType::BOOLEAN;
	nested.projection_pushdown = true;
	loader.RegisterFunction(nested);

	TableFunction subfields("read_marc_subfields", {LogicalType::VARCHAR}, SubfieldsScan, SubfieldsBind,
	                        SubfieldsInitGlobal, SubfieldsInitLocal);
	subfields.named_parameters["encoding"] = LogicalType::VARCHAR;
	subfields.named_parameters["tags"] = LogicalType::VARCHAR;
	subfields.named_parameters["ignore_errors"] = LogicalType::BOOLEAN;
	subfields.projection_pushdown = true;
	loader.RegisterFunction(subfields);

	TableFunction raw("read_marc_raw", {LogicalType::VARCHAR}, RawScan, RawBind, RawInitGlobal, ScanInitLocal);
	raw.named_parameters["encoding"] = LogicalType::VARCHAR;
	raw.projection_pushdown = true;
	loader.RegisterFunction(raw);

	TableFunction breaker("read_marc_breaker", {LogicalType::VARCHAR},
	                      TextScan<marc::ParseBreaker, BREAKER_NAME, false>, TextBind, TextInitGlobal, TextInitLocal);
	breaker.named_parameters["tags"] = LogicalType::VARCHAR;
	breaker.projection_pushdown = true;
	loader.RegisterFunction(breaker);

	TableFunction marcxml("read_marcxml", {LogicalType::VARCHAR}, TextScan<marc::ParseMarcXml, MARCXML_NAME, true>,
	                      TextBind, TextInitGlobal, TextInitLocal);
	marcxml.named_parameters["tags"] = LogicalType::VARCHAR;
	marcxml.projection_pushdown = true;
	loader.RegisterFunction(marcxml);

	TableFunction marcjson("read_marcjson", {LogicalType::VARCHAR},
	                       WholeFileScan<marc::ParseMarcJson, MARCJSON_NAME>, TextBind, TextInitGlobal,
	                       WholeFileInitLocal);
	marcjson.named_parameters["tags"] = LogicalType::VARCHAR;
	marcjson.projection_pushdown = true;
	loader.RegisterFunction(marcjson);

	TableFunction aleph("read_alephseq", {LogicalType::VARCHAR}, WholeFileScan<marc::ParseAlephSeq, ALEPH_NAME>,
	                    TextBind, TextInitGlobal, WholeFileInitLocal);
	aleph.named_parameters["tags"] = LogicalType::VARCHAR;
	aleph.projection_pushdown = true;
	loader.RegisterFunction(aleph);

	TableFunction microlif("read_microlif", {LogicalType::VARCHAR}, WholeFileScan<marc::ParseMicroLif, MICROLIF_NAME>,
	                       TextBind, TextInitGlobal, WholeFileInitLocal);
	microlif.named_parameters["tags"] = LogicalType::VARCHAR;
	microlif.projection_pushdown = true;
	loader.RegisterFunction(microlif);

	RegisterMarcCopy(loader);
	RegisterMarcScalars(loader);
	RegisterMarcEditScalars(loader);
	RegisterMarcClusterScalars(loader);
	RegisterMarcAuthlinkScalars(loader);
	RegisterMarcZ3950(loader);
	RegisterMarcXslt(loader);

	// Macro layer (nested shapes over the text readers, marc_* helpers) —
	// plain SQL over the table functions above.  Those bodies call
	// list_filter, list_transform, list_contains and jaro_winkler_similarity,
	// which the core_functions extension supplies rather than the engine:
	// released DuckDB binaries link it statically, a bare extension-template
	// build does not, and the order two extensions load in is not a documented
	// guarantee — nor is this binary necessarily the one that built the
	// .duckdb_extension being loaded.  Ask for it before binding anything; a
	// no-op when it is already there.
	auto &instance = loader.GetDatabaseInstance();
	ExtensionHelper::AutoLoadExtension(instance, "core_functions");

	Connection con(instance);
	vector<unique_ptr<SQLStatement>> statements;
	try {
		statements = con.ExtractStatements(marc::MACROS_SQL);
	} catch (const std::exception &e) {
		throw InternalException("marc extension: parsing the embedded macros failed: %s", e.what());
	}
	// One statement at a time, so a failure names the macro that caused it:
	// registering the batch in one call reports the missing function without
	// saying which of the 150-odd bodies asked for it.
	for (auto &statement : statements) {
		auto label = MacroLabel(*statement);
		unique_ptr<MaterializedQueryResult> result;
		try {
			result = con.Query(std::move(statement));
		} catch (const std::exception &e) {
			throw InternalException("marc extension: registering macro %s failed: %s", label, e.what());
		}
		if (result->HasError()) {
			throw InternalException("marc extension: registering macro %s failed: %s", label,
			                        result->GetError());
		}
	}
}

} // namespace

const LogicalType &MarcFieldStructType() {
	return FieldStructType();
}

Value MarcFieldsToValue(const marc::Record &rec) {
	MarcBindData no_filter;
	return FieldsToValue(rec, no_filter);
}

void Marc21Extension::Load(ExtensionLoader &loader) {
	LoadInternal(loader);
}
std::string Marc21Extension::Name() {
	return "marc21";
}
std::string Marc21Extension::Version() const {
#ifdef EXT_VERSION_MARC21
	return EXT_VERSION_MARC21;
#else
	return "";
#endif
}

} // namespace duckdb

extern "C" {
DUCKDB_CPP_EXTENSION_ENTRY(marc21, loader) {
	duckdb::LoadInternal(loader);
}
}
