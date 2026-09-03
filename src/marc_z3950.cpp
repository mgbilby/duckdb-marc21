//! read_z3950(host, port, database, query) — live retrieval from a Z39.50
//! server (LC's z3950.loc.gov:7090/Voyager, OCLC, most ILSes) using the
//! independently implemented client core in src/core/z3950.cpp over a plain
//! TCP transport.
//!
//! One row per returned record in the same nested shape as read_marc
//! (leader + fields), plus the server's total hit count on every row
//! (max_records := 1 makes a cheap hit-count probe).  The whole conversation
//! happens on the first scan call of a single-threaded scan: Z39.50 is a
//! stateful session protocol, so there is nothing to parallelise.
#include "marc21_extension.hpp"

#include "duckdb.hpp"
#include "duckdb/main/extension/extension_loader.hpp"
#include "duckdb/main/settings.hpp"

#include "marc/core.hpp"
#include "marc/z3950.hpp"
#include "marc/z3950_socket.hpp"

namespace duckdb {
namespace {

struct Z3950BindData : public TableFunctionData {
	string host;
	int32_t port = 210;
	string database;
	string query;
	int32_t max_records = 10;
	int32_t timeout_seconds = 15;
	bool ignore_errors = false;
};

struct Z3950GlobalState : public GlobalTableFunctionState {
	bool fetched = false;
	int64_t hits = 0;
	vector<marc::Record> records;
	idx_t next_row = 0;

	idx_t MaxThreads() const override {
		return 1;
	}
};

static unique_ptr<FunctionData> Z3950Bind(ClientContext &context, TableFunctionBindInput &input,
                                          vector<LogicalType> &types, vector<string> &names) {
	if (!Settings::Get<EnableExternalAccessSetting>(DBConfig::GetConfig(context))) {
		throw PermissionException("Z39.50 access is disabled through configuration");
	}
	auto result = make_uniq<Z3950BindData>();
	result->host = input.inputs[0].GetValue<string>();
	result->port = input.inputs[1].GetValue<int32_t>();
	result->database = input.inputs[2].GetValue<string>();
	result->query = input.inputs[3].GetValue<string>();
	for (auto &kv : input.named_parameters) {
		auto name = StringUtil::Lower(kv.first);
		if (name == "max_records") {
			result->max_records = kv.second.GetValue<int32_t>();
		} else if (name == "timeout") {
			result->timeout_seconds = kv.second.GetValue<int32_t>();
		} else if (name == "ignore_errors") {
			result->ignore_errors = kv.second.GetValue<bool>();
		}
	}
	if (result->host.empty()) {
		throw BinderException("read_z3950: host must not be empty");
	}
	types = {LogicalType::BIGINT, LogicalType::BIGINT, LogicalType::VARCHAR, LogicalType::VARCHAR,
	         LogicalType::LIST(MarcFieldStructType())};
	names = {"record_no", "hits", "control_number", "leader", "fields"};
	return std::move(result);
}

static unique_ptr<GlobalTableFunctionState> Z3950InitGlobal(ClientContext &, TableFunctionInitInput &) {
	return make_uniq<Z3950GlobalState>();
}

//! Init -> Search -> Present, then parse; called once from the first Scan.
static void Z3950Fetch(const Z3950BindData &bind, Z3950GlobalState &state) {
	state.fetched = true;
	marc::Z3950Result result;
	try {
		marc::SocketTransport transport(bind.host, bind.port, bind.timeout_seconds);
		result = marc::Z3950Search(transport, bind.database, bind.query, bind.max_records);
	} catch (marc::MarcError &e) {
		throw IOException("read_z3950: %s", e.what());
	}
	state.hits = result.hit_count;
	state.records.reserve(result.raw_records.size());
	for (idx_t i = 0; i < result.raw_records.size(); i++) {
		try {
			state.records.push_back(marc::ParseRecord(result.raw_records[i], marc::Encoding::AUTO));
		} catch (marc::MarcError &e) {
			if (!bind.ignore_errors) {
				throw InvalidInputException("read_z3950: returned record %lld: %s",
				                            static_cast<int64_t>(i) + 1, e.what());
			}
		}
	}
}

static void Z3950Scan(ClientContext &, TableFunctionInput &data, DataChunk &output) {
	auto &bind = data.bind_data->Cast<Z3950BindData>();
	auto &state = data.global_state->Cast<Z3950GlobalState>();
	if (!state.fetched) {
		Z3950Fetch(bind, state);
	}
	idx_t n = 0;
	while (n < STANDARD_VECTOR_SIZE && state.next_row < state.records.size()) {
		auto &rec = state.records[state.next_row];
		output.SetValue(0, n, Value::BIGINT(static_cast<int64_t>(state.next_row) + 1));
		output.SetValue(1, n, Value::BIGINT(state.hits));
		auto cn = rec.ControlNumber();
		output.SetValue(2, n, cn ? Value(*cn) : Value(LogicalType::VARCHAR));
		output.SetValue(3, n, Value(rec.leader));
		output.SetValue(4, n, MarcFieldsToValue(rec));
		state.next_row++;
		n++;
	}
	output.SetCardinality(n);
}

} // namespace

void RegisterMarcZ3950(ExtensionLoader &loader) {
	TableFunction z3950("read_z3950",
	                    {LogicalType::VARCHAR, LogicalType::INTEGER, LogicalType::VARCHAR, LogicalType::VARCHAR},
	                    Z3950Scan, Z3950Bind, Z3950InitGlobal);
	z3950.named_parameters["max_records"] = LogicalType::INTEGER;
	z3950.named_parameters["timeout"] = LogicalType::INTEGER;
	z3950.named_parameters["ignore_errors"] = LogicalType::BOOLEAN;
	loader.RegisterFunction(z3950);
}

} // namespace duckdb
