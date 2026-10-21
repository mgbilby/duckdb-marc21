#pragma once

//! Shims over the DuckDB C++ API surfaces that moved between v1.5.x and v2.0.

// Detection keys on a header that only v2.0 has.  It used to key on
// duckdb/common/identifier.hpp, but v1.5.6 backported Identifier (as an
// implicit string wrapper, with every API still taking std::string), so that
// header no longer tells the two apart; the FlatVector move it came with was
// not backported.
#if defined(DUCKDB_MAJOR_VERSION) && DUCKDB_MAJOR_VERSION >= 2
#define MARC21_DUCKDB_V2 1
#elif __has_include("duckdb/common/vector/flat_vector.hpp")
#define MARC21_DUCKDB_V2 1
#else
#define MARC21_DUCKDB_V2 0
#endif

#include <type_traits>

#include "duckdb/common/string_util.hpp"
#include "duckdb/common/types/vector.hpp"
#include "duckdb/common/vector_operations/unary_executor.hpp"
#include "duckdb/function/copy_function.hpp"
#include "duckdb/function/scalar_function.hpp"
#include "duckdb/function/table_function.hpp"
#include "duckdb/catalog/catalog_entry/table_function_catalog_entry.hpp"
#include "duckdb/main/extension/extension_loader.hpp"
#include "duckdb/parser/parsed_data/create_function_info.hpp"
#include "duckdb/parser/parsed_data/create_scalar_function_info.hpp"
#include "duckdb/parser/parsed_data/create_table_function_info.hpp"
#include "duckdb/parser/sql_statement.hpp"
#include "duckdb/parser/statement/create_statement.hpp"
#include "duckdb/planner/expression/bound_function_expression.hpp"

#include "marc/function_docs.hpp"

#if MARC21_DUCKDB_V2
#include "duckdb/common/multi_file/table_function_multi_file.hpp"
#include "duckdb/storage/external_file_cache/caching_file_system.hpp"
#include "duckdb/common/optional.hpp"
#include "duckdb/common/vector/flat_vector.hpp"
#endif

namespace duckdb {

// ---------------------------------------------------------------------------
// Identifier vs string in function signatures
// ---------------------------------------------------------------------------

template <class T> struct MarcFnArg;
template <class R, class A, class B, class C, class D>
struct MarcFnArg<R (*)(A, B, C, D)> {
	using Third = C;
	using Fourth = D;
};
using MarcCopyNames = MarcFnArg<copy_to_bind_t>::Third;
using MarcBindNames = std::remove_reference<MarcFnArg<table_function_bind_t>::Fourth>::type;

//! Works for both std::string and duckdb::Identifier.
template <class T>
inline string MarcName(const T &s) {
	return string(s.c_str(), s.size());
}

// ---------------------------------------------------------------------------
// Vector data access
// ---------------------------------------------------------------------------

//! Writable access to a flat vector's data array.  v2.0 made FlatVector::GetData
//! return a const pointer and moved the writable overload to GetDataMutable, as
//! part of the vector const-correctness rework; the class also moved from
//! types/vector.hpp to common/vector/flat_vector.hpp.
template <class T>
inline T *MarcFlatData(Vector &vec) {
#if MARC21_DUCKDB_V2
	return FlatVector::GetDataMutable<T>(vec);
#else
	return FlatVector::GetData<T>(vec);
#endif
}

//! Point a vector at one constant value repeated `count` times.  v2.0 made the
//! row count an explicit argument rather than deriving it from the chunk.
inline void MarcReferenceValue(Vector &vec, const Value &value, idx_t count) {
#if MARC21_DUCKDB_V2
	vec.Reference(value, count_t(count));
#else
	(void)count;
	vec.Reference(value);
#endif
}

// ---------------------------------------------------------------------------
// Unary execution that can yield SQL NULL
// ---------------------------------------------------------------------------

//! v1.x spelled this UnaryExecutor::ExecuteWithNulls, whose callback received
//! the result mask and the row index and invalidated the row itself.  v2.0
//! removed it: the callback now returns optional<RESULT_TYPE> and nullability
//! is deduced from that return type.

template <class INPUT_TYPE, class RESULT_TYPE, class FUNC>
inline void MarcUnaryWithNulls(Vector &input, Vector &result, idx_t count, FUNC fn) {
#if MARC21_DUCKDB_V2
	UnaryExecutor::Execute<INPUT_TYPE, RESULT_TYPE>(input, result, count,
	                                                [&](INPUT_TYPE in) -> optional<RESULT_TYPE> {
		                                                bool is_null = false;
		                                                auto value = fn(in, is_null);
		                                                if (is_null) {
			                                                return nullopt;
		                                                }
		                                                return value;
	                                                });
#else
	UnaryExecutor::ExecuteWithNulls<INPUT_TYPE, RESULT_TYPE>(
	    input, result, count, [&](INPUT_TYPE in, ValidityMask &mask, idx_t idx) -> RESULT_TYPE {
		    bool is_null = false;
		    auto value = fn(in, is_null);
		    if (is_null) {
			    mask.SetInvalid(idx);
		    }
		    return value;
	    });
#endif
}

// ---------------------------------------------------------------------------
// Scalar function bind
// ---------------------------------------------------------------------------

//! v2.0 collapsed the scalar bind callback's three arguments into a single
//! BindScalarFunctionInput.  Bind bodies are written against the shape both
//! versions can supply -- (ClientContext &, vector<unique_ptr<Expression>> &) --
//! and registered through this adapter, e.g. MarcScalarBind<MarcSpecBind>.
using MarcScalarBindBody = unique_ptr<FunctionData> (*)(ClientContext &, vector<unique_ptr<Expression>> &);

#if MARC21_DUCKDB_V2
template <MarcScalarBindBody BODY>
inline unique_ptr<FunctionData> MarcScalarBind(BindScalarFunctionInput &input) {
	return BODY(input.GetClientContext(), input.GetArguments());
}
#else
template <MarcScalarBindBody BODY>
inline unique_ptr<FunctionData> MarcScalarBind(ClientContext &context, ScalarFunction &,
                                               vector<unique_ptr<Expression>> &arguments) {
	return BODY(context, arguments);
}
#endif

//! The bind data attached to a bound function call.  v2.0 made the member
//! private behind an accessor.
inline const FunctionData &MarcBoundBindData(const BoundFunctionExpression &expr) {
#if MARC21_DUCKDB_V2
	return *expr.BindInfo();
#else
	return *expr.bind_info;
#endif
}

// ---------------------------------------------------------------------------
// Parser / catalog info
// ---------------------------------------------------------------------------

//! The name a CREATE MACRO statement defines.  v2.0 replaced the public `name`
//! member with a qualified name behind GetFunctionName().
inline string MarcFunctionName(const CreateFunctionInfo &info) {
#if MARC21_DUCKDB_V2
	return MarcName(info.GetFunctionName());
#else
	return info.name;
#endif
}

//! The source text of one statement within the query it was parsed from.  v2.0
//! replaced the separate stmt_location/stmt_length members with a single
//! QueryLocation, which can also be invalid.
inline string MarcStatementText(const SQLStatement &statement) {
#if MARC21_DUCKDB_V2
	if (!statement.stmt_location.IsValid()) {
		return statement.query;
	}
	return statement.query.substr(statement.stmt_location.offset, statement.stmt_location.length);
#else
	return statement.query.substr(statement.stmt_location, statement.stmt_length);
#endif
}

// ---------------------------------------------------------------------------
// Documented table functions
// ---------------------------------------------------------------------------

//! Complete a table function's parameter names once it is in the catalog.
//!
//! On v1.5.x duckdb_functions() lists a table function's parameters as its
//! positional arguments followed by its named parameters, and once a
//! description carries any names it takes every name from there by that
//! index -- so naming only `path` would turn encoding, tags and ignore_errors
//! into col1..col3.  The named parameters live in an unordered map, and
//! duckdb_functions() iterates a copy of it taken from the catalog entry,
//! whose order is the standard library's to choose (libc++ and libstdc++
//! disagree).  So the names are appended here from the stored entry, by the
//! same GetFunctionByOffset copy duckdb_functions() makes, rather than from
//! the TableFunction before it was registered.
//!
//! v2.0 reads names from the function's own signature and uses a
//! description's only when the counts disagree, so there is nothing to do.
inline void MarcNameTableParameters(ExtensionLoader &loader, const string &name) {
#if MARC21_DUCKDB_V2
	(void)loader;
	(void)name;
#else
	auto &entry = loader.GetTableFunction(name);
	if (entry.descriptions.size() != 1 || entry.functions.Size() != 1) {
		return;
	}
	auto function = entry.functions.GetFunctionByOffset(0);
	auto &names = entry.descriptions[0].parameter_names;
	if (names.empty() && function.named_parameters.empty()) {
		return;
	}
	for (idx_t i = names.size(); i < function.arguments.size(); i++) {
		names.push_back("col" + to_string(i));
	}
	names.resize(function.arguments.size());
	for (auto &param : function.named_parameters) {
		names.push_back(param.first);
	}
#endif
}

//! Register a table function (or set) with its catalog documentation.  The
//! same as the bare RegisterFunction overload -- which builds this info with
//! ALTER_ON_CONFLICT internally -- plus the description.
template <class FUNCTION_OR_SET>
inline void MarcRegisterTable(ExtensionLoader &loader, FUNCTION_OR_SET function, const string &name) {
	CreateTableFunctionInfo info(std::move(function));
	info.descriptions = MarcFunctionDescriptions(name);
	info.on_conflict = OnCreateConflict::ALTER_ON_CONFLICT;
	loader.RegisterFunction(std::move(info));
	MarcNameTableParameters(loader, name);
}

// ---------------------------------------------------------------------------
// DataChunk writes
// ---------------------------------------------------------------------------

//! Set a chunk's row count after the child vectors were written directly.
//! v1.5.x only has SetCardinality; v2.0.0 deprecates it in favour of
//! CheckCardinality, but keeps its exact behavior under the name
//! SetCardinalityUnsafe (check-then-set, no resize) - which is what a scan
//! that writes the child vectors itself needs, so that is what this uses.
inline void MarcSetCardinality(DataChunk &chunk, idx_t count) {
#if MARC21_DUCKDB_V2
	chunk.SetCardinalityUnsafe(count);
#else
	chunk.SetCardinality(count);
#endif
}

//! Write a Value at an index of one column.  DataChunk::SetValue is
//! deprecated on v2.0.0 in favour of writing the child vector; v1.5.x only
//! has the DataChunk method, so this keeps one call site for both.
inline void MarcSetValue(DataChunk &chunk, idx_t col, idx_t index, Value value) {
#if MARC21_DUCKDB_V2
	chunk.data[col].SetValue(index, value);
#else
	chunk.SetValue(col, index, value);
#endif
}

// ---------------------------------------------------------------------------
// Named parameters and batch-at-a-time scanning
// ---------------------------------------------------------------------------

//! Give a reader's positional parameters real names.  v2.0's brace-list
//! constructors fall back to positional-only parameters named col0..colN,
//! which is what duckdb_functions() then reports - and what the catalog's
//! parameter-name test refuses.  v1.5 reports the names a description
//! carries (MarcNameTableParameters fills them), so there is nothing to do.
inline void MarcNameParameters(TableFunction &function, std::initializer_list<const char *> names) {
#if MARC21_DUCKDB_V2
	auto &signature = function.GetSignature();
	idx_t i = 0;
	for (auto name : names) {
		signature.GetParameter(i++).SetName(name);
	}
#else
	(void)function;
	(void)names;
#endif
}

//! Add a named parameter to a table function.  v1.5.x keeps them in the
//! named_parameters map; v2.0.0 removed that map.
//!
//! On v2.0 the shape depends on how the function reaches the catalog:
//! a reader is wrapped by the multi-file framework, whose outer
//! function takes options through a typed "**kwargs" schema
//! (TableFunctionMultiFileWrapper::CreateFunction merges the wrapped
//! function's schema into its own, and ParseNamedParameter routes a
//! passed option to the wrapped bind) -- so a reader's options are
//! declared as TypedKwargs, like parquet's.  A function registered
//! as-is (read_z3950) has no "**kwargs" to ride in, so its options
//! are keyword-only parameters -- and those need a default, because
//! v2.0's binder refuses a call that leaves one without a value
//! (ResolveArguments: "Missing value for parameter", surfaced as "No
//! function matches"); a NULL of the parameter's type restores the
//! implicit-optional semantics of the v1.5 map, and MarcBindSkips
//! makes the bind side treat it as "not passed".
//!
//! MarcAddReaderOption declares a wrapped reader's option;
//! MarcAddNamedParameter declares an unwrapped function's.
inline void MarcAddReaderOption(TableFunction &function, const char *name, LogicalType type) {
#if MARC21_DUCKDB_V2
	auto &signature = function.GetSignature();
	auto add_option = [&](TypedKwargs &options) { options.Add(name, std::move(type)); };
	if (signature.GetTypedKwargs()) {
		signature.ExtendTypedKwargs(add_option);
	} else {
		signature.WithTypedKwargs("options", add_option);
	}
#else
	function.named_parameters[name] = std::move(type);
#endif
}

inline void MarcAddNamedParameter(TableFunction &function, const char *name, LogicalType type) {
#if MARC21_DUCKDB_V2
	function.GetSignature().AddKeywordOnly(name, std::move(type), Value(type));
#else
	function.named_parameters[name] = std::move(type);
#endif
}

//! Whether the bind loop should skip this named argument: on v2.0 it is the
//! injected default for a parameter the caller did not pass.
inline bool MarcBindSkips(const Value &value) {
#if MARC21_DUCKDB_V2
	return value.IsNull();
#else
	(void)value;
	return false;
#endif
}

//! Wire a binary reader into v2.0's batch-at-a-time scanning.  On v2.0.0
//! the claim/finish callbacks are not fields of TableFunction: a single-file
//! function is handed to the multi-file framework, and the callbacks go into
//! TableFunctionMultiFileSettings, from where the wrapper drives them.
//! MarcRegisterReader and MarcSetCopyFrom carry them through this struct.
//! It is empty on v1.5.x, which has no such callbacks.
struct MarcBatchCallbacks {
#if MARC21_DUCKDB_V2
	table_function_claim_batch_t claim_batch = nullptr;
	table_function_finish_batch_t finish_batch = nullptr;
#endif
};

#if MARC21_DUCKDB_V2
inline void MarcApplyBatchCallbacks(const MarcBatchCallbacks &callbacks, TableFunctionMultiFileSettings &settings) {
	settings.claim_batch = callbacks.claim_batch;
	settings.finish_batch = callbacks.finish_batch;
}
#endif

// ---------------------------------------------------------------------------
// Multi-file scanning
// ---------------------------------------------------------------------------

//! Register a reader that takes a single VARCHAR path plus named parameters.
//!
//! On v2.0 the reader is a *single-file* function wrapped by the multi-file
//! framework, which then supplies the glob, the LIST overload, union_by_name,
//! hive partitioning and partition pruning, and the filename and file_index
//! virtual columns, and schedules the files of one scan across threads --
//! which is what makes a glob over object storage scale.  On v1.5.x no such
//! framework exists for extension readers, so the function is registered
//! as-is and expands the glob itself.
//!
//! Three things the framework does NOT give a wrapped function, checked
//! against the v2.0 source rather than assumed:
//!   - file_row_number.  TableFunctionFileReader::AddVirtualColumn throws
//!     NotImplementedException; only filename and file_index are available,
//!     and those because they resolve without opening the file.
//!   - COPY ... FROM.  MultiFileBindCopy exists but has to be wired to a
//!     CopyFunction explicitly; see RegisterMarcCopy.
//!   - Asynchronous execution of the reader.  TableFunctionFileReader::Scan
//!     pins the wrapped call to AsyncResultsExecutionMode::SYNCHRONOUS and
//!     drives async itself, so the parallelism a reader gets is across
//!     files, not overlapping reads inside one.
//!
//! `reader_type` is how the files are named in error messages.
inline void MarcRegisterReader(ExtensionLoader &loader, TableFunction function, const char *name,
                               const char *reader_type,
                               const MarcBatchCallbacks &batch_callbacks = MarcBatchCallbacks()) {
#if MARC21_DUCKDB_V2
	TableFunctionMultiFileSettings settings;
	settings.reader_type = reader_type;
	// Every marc21 reader has a fixed column list, so one file determines the
	// schema and there is nothing to combine across files.
	settings.maximum_sample_files = 1;
	MarcApplyBatchCallbacks(batch_callbacks, settings);
	MarcRegisterTable(
	    loader,
	    TableFunctionMultiFileWrapper::CreateFunctionSet(std::move(function), Identifier(name), std::move(settings)),
	    name);
#else
	(void)reader_type;
	MarcRegisterTable(loader, std::move(function), name);
#endif
}

//! Give a COPY format a FROM side, reading through the multi-file wrapper
//! around `reader`.  marc21 could write four formats and read none of them
//! back through COPY; this is what closes that.  COPY takes its columns from
//! the target table, and the framework maps the reader's columns onto them by
//! name.  v1.5.x has no MultiFileBindCopy, so the FROM side is v2.0 only and
//! COPY ... FROM there keeps reporting the format as write-only.
inline void MarcSetCopyFrom(CopyFunction &function, TableFunction reader, const char *name, const char *reader_type,
                            const MarcBatchCallbacks &batch_callbacks = MarcBatchCallbacks()) {
#if MARC21_DUCKDB_V2
	TableFunctionMultiFileSettings settings;
	settings.reader_type = reader_type;
	settings.maximum_sample_files = 1;
	MarcApplyBatchCallbacks(batch_callbacks, settings);
	function.copy_from_bind = TableFunctionMultiFileWrapper::MultiFileBindCopy;
	function.copy_from_function =
	    TableFunctionMultiFileWrapper::CreateFunction(std::move(reader), Identifier(name), std::move(settings));
#else
	(void)function;
	(void)reader;
	(void)name;
	(void)reader_type;
#endif
}

//! Whether this build expands globs itself.  True only on v1.5.x: under the
//! v2.0 multi-file framework the reader is handed one concrete file and must
//! not glob, or the pattern would be expanded twice.
inline constexpr bool MarcReaderGlobsItself() {
	return !MARC21_DUCKDB_V2;
}

// ---------------------------------------------------------------------------
// Dedicated extension schema
// ---------------------------------------------------------------------------

//! Whether to give this extension's functions a schema of their own.
//!
//! v2.0 offers UseDedicatedSchemaForExtension, and marc21 tried it: readers,
//! scalars and macros into a `marc21` schema instead of crowding `main`.
//! It is deliberately NOT used, on the evidence of an actual v2.0 build.
//!
//! DuckDB does append extension schemas to a context's search path, and in the
//! CLI unqualified calls resolved fine.  But in the sqllogictest harness -- the
//! one the community CI runs -- they did not: 41 of the 42 test files failed
//! with "Table Function with name read_marc_breaker does not exist! Did you
//! mean system.marc21.read_marc_breaker?".  Resolution therefore depends on how
//! the embedding context was constructed, which is not something an extension
//! can control.
//!
//! For a library whose users have years of `read_marc(...)` in their scripts,
//! a schema move that resolves in one embedding and not another is a breaking
//! change dressed up as tidiness.  The namespace stays flat.
inline void MarcUseExtensionSchema(ExtensionLoader &loader) {
	(void)loader;
}


// ---------------------------------------------------------------------------
// Byte source
// ---------------------------------------------------------------------------

//! A sequential reader over one file, which on v2.0 goes through DuckDB's
//! external file cache.
//!
//! The cache is what makes a MARC dump on object storage behave: blocks are
//! held by the buffer manager and shared across scans, so reading the same
//! s3:// dump twice does not fetch it twice, and reads are recorded into the
//! engine's network throughput estimate the way Parquet's are.
//!
//! What this is not: the reads themselves are still synchronous. The wrapped
//! reader is pinned to synchronous execution by the multi-file framework, so
//! concurrency on a remote scan comes from reading several files at once, not
//! from overlapping requests within one file.
//!
//! Two cases stay on a plain handle: v1.5.x, which has no caching file system,
//! and gzip, whose decompressing wrapper needs to own a unique_ptr<FileHandle>
//! that the caching handle cannot hand over.  Callers see one interface either
//! way.
class MarcByteSource {
public:
	MarcByteSource(ClientContext &context, const string &path, bool compressed) {
#if MARC21_DUCKDB_V2
		if (!compressed) {
			// A failure here is not worth failing the scan over: fall back to
			// the plain handle, which reads the same bytes uncached.
			try {
				caching_fs = make_uniq<CachingFileSystem>(CachingFileSystem::Get(context));
				cached = caching_fs->OpenFile(path, FileOpenFlags(FileOpenFlags::FILE_FLAGS_READ));
				if (cached) {
					return;
				}
			} catch (const std::exception &) {
				cached.reset();
				caching_fs.reset();
			}
		}
#else
		(void)compressed;
#endif
		auto &fs = FileSystem::GetFileSystem(context);
		plain = fs.OpenFile(path, FileOpenFlags(FileOpenFlags::FILE_FLAGS_READ));
	}

	//! Hand over the plain handle, for the gzip wrapper to take ownership of.
	//! Only ever set when this source was opened on the plain path.
	unique_ptr<FileHandle> ReleasePlain() {
		return std::move(plain);
	}
	bool HasPlain() const {
		return plain != nullptr;
	}

	//! Read up to `nr_bytes` into `dest`; returns the bytes actually read, 0 at
	//! end of file.
	int64_t Read(void *dest, int64_t nr_bytes) {
#if MARC21_DUCKDB_V2
		if (cached) {
			auto wanted = static_cast<idx_t>(nr_bytes);
			auto group = cached->Read(wanted);
			if (wanted == 0) {
				return 0;
			}
			group.CopyTo(reinterpret_cast<data_ptr_t>(dest), wanted);
			return static_cast<int64_t>(wanted);
		}
#endif
		return plain->Read(dest, nr_bytes);
	}

private:
	unique_ptr<FileHandle> plain;
#if MARC21_DUCKDB_V2
	unique_ptr<CachingFileSystem> caching_fs;
	unique_ptr<CachingFileHandle> cached;
#endif
};

// ---------------------------------------------------------------------------
// Fallible scalar functions
// ---------------------------------------------------------------------------

//! Register a scalar function that may raise a runtime error.
//!
//! v2.0 requires a scalar that can throw to say so: the engine assumes a
//! function is infallible and, when one throws anyway, converts the error into
//! an INTERNAL error telling the author to call SetFallible().  That turns a
//! clear message like `marc edit: cannot swap 001 and 650` into an assertion
//! failure, which is how this surfaced -- a real v2.0 build failed five test
//! files this way.
//!
//! Every marc21 scalar parses or edits MARC supplied by the caller, and raising
//! a specific error on malformed input is the point of them, so they are all
//! registered through here.  v1.5.x has no such concept and ignores it.
//!
//! Registration goes through CreateScalarFunctionInfo rather than the bare
//! overload, which has nowhere to put the catalog documentation; the conflict
//! policy is the one the bare overload sets internally.
inline void MarcRegisterScalar(ExtensionLoader &loader, ScalarFunction function) {
#if MARC21_DUCKDB_V2
	function.SetFallible();
#endif
	auto name = MarcName(function.name);
#if MARC21_DUCKDB_V2
	// v2.0's duckdb_functions() reports parameter names from the signature,
	// and the brace-list constructor names them col0..colN; the catalog
	// documentation is where the real names live, so put them on the signature.
	// A docs entry with no parameter list (macros, zero-argument functions)
	// names nothing, and a signature whose parameter count disagrees with the
	// docs is left alone rather than half-renamed.
	auto descriptions = MarcFunctionDescriptions(name);
	if (!descriptions.empty() && !descriptions[0].parameter_names.empty() &&
	    descriptions[0].parameter_names.size() == function.GetSignature().GetParameterCount()) {
		auto &signature = function.GetSignature();
		for (idx_t i = 0; i < signature.GetParameterCount(); i++) {
			signature.GetParameter(i).SetName(Identifier(descriptions[0].parameter_names[i]));
		}
	}
	CreateScalarFunctionInfo info(std::move(function));
	info.descriptions = std::move(descriptions);
#else
	CreateScalarFunctionInfo info(std::move(function));
	info.descriptions = MarcFunctionDescriptions(name);
#endif
	info.on_conflict = OnCreateConflict::ALTER_ON_CONFLICT;
	loader.RegisterFunction(std::move(info));
}

} // namespace duckdb
