//! The XSLT crosswalk registry: the shipped stylesheets and their catalog,
//! carried inside the extension binary.
//!
//!   marc_xslt_functions()               -> alias, path, source_format,
//!                                          target_format, description
//!   marc_xslt_stylesheet(alias_or_path) -> stylesheet text (NULL if unknown)
//!   marc_xslt_library()                 -> the shared lib/marc-utils.xsl text
//!
//! The catalog is xslt/registry.tsv and the stylesheet text is the file each
//! row names; CMake reads both at configure time into marc21_gen/marc/
//! xslt_embedded.hpp, so an installed extension resolves an alias with no
//! files on disk — including in WASM, where there is no filesystem to ship to.
//!
//! This extension does not execute XSLT: it registers, catalogs and hands out
//! the stylesheets (compose with xsltproc, Saxon, or the browser's own
//! XSLTProcessor — docs/ECOSYSTEM.md). `marc_xslt_command()` in
//! src/macros/xslt.sql builds the xsltproc command line for an alias, and
//! COPY writes a sheet to disk next to an exported lib/marc-utils.xsl.
//!
//! Lookup accepts a registry alias case-insensitively ("MARC=>MODS",
//! "marc=>mods") or a registry path exactly as the catalog spells it
//! ("xslt/marcxml-to-mods.xsl").

#include "marc21_extension.hpp"
#include "marc/compat.hpp"

#include "duckdb.hpp"
#include "duckdb/main/extension/extension_loader.hpp"

#include "marc/xslt_embedded.hpp"

#include <cstring>
#include <string>

namespace duckdb {
namespace {

//! One registry row by alias (case-insensitive) or by its exact path.
const marc::XsltSheet *FindSheet(const std::string &key) {
	for (size_t i = 0; i < marc::XSLT_SHEET_COUNT; i++) {
		if (key == marc::XSLT_SHEETS[i].path) {
			return &marc::XSLT_SHEETS[i];
		}
	}
	auto upper = StringUtil::Upper(key);
	for (size_t i = 0; i < marc::XSLT_SHEET_COUNT; i++) {
		if (upper == StringUtil::Upper(std::string(marc::XSLT_SHEETS[i].alias))) {
			return &marc::XSLT_SHEETS[i];
		}
	}
	return nullptr;
}

// ---------------------------------------------------------------------------
// marc_xslt_functions() — the catalog as a table
// ---------------------------------------------------------------------------

//! The catalog is a compile-time constant, so every bind is equal to any other.
struct XsltCatalogBindData : public TableFunctionData {
	unique_ptr<FunctionData> Copy() const override {
		return make_uniq<XsltCatalogBindData>();
	}
	bool Equals(const FunctionData &) const override {
		return true;
	}
};

struct XsltCatalogState : public GlobalTableFunctionState {
	idx_t next_row = 0;

	idx_t MaxThreads() const override {
		return 1;
	}
};

unique_ptr<FunctionData> XsltCatalogBind(ClientContext &, TableFunctionBindInput &, vector<LogicalType> &types,
                                         MarcBindNames &names) {
	auto V = LogicalType::VARCHAR;
	types = {V, V, V, V, V};
	names = {"alias", "path", "source_format", "target_format", "description"};
	return make_uniq<XsltCatalogBindData>();
}

unique_ptr<GlobalTableFunctionState> XsltCatalogInitGlobal(ClientContext &, TableFunctionInitInput &) {
	return make_uniq<XsltCatalogState>();
}

void XsltCatalogScan(ClientContext &, TableFunctionInput &data, DataChunk &output) {
	auto &state = data.global_state->Cast<XsltCatalogState>();
	idx_t n = 0;
	while (n < STANDARD_VECTOR_SIZE && state.next_row < marc::XSLT_SHEET_COUNT) {
		auto &sheet = marc::XSLT_SHEETS[state.next_row];
		MarcSetValue(output, 0, n, Value(sheet.alias));
		MarcSetValue(output, 1, n, Value(sheet.path));
		MarcSetValue(output, 2, n, Value(sheet.source_format));
		MarcSetValue(output, 3, n, Value(sheet.target_format));
		MarcSetValue(output, 4, n, Value(sheet.description));
		state.next_row++;
		n++;
	}
	MarcSetCardinality(output, n);
}

// ---------------------------------------------------------------------------
// marc_xslt_stylesheet(alias_or_path), marc_xslt_library()
// ---------------------------------------------------------------------------

void StylesheetExec(DataChunk &args, ExpressionState &, Vector &result) {
	MarcUnaryWithNulls<string_t, string_t>(
	    args.data[0], result, args.size(), [&](string_t input, bool &is_null) {
		    auto sheet = FindSheet(std::string(input.GetData(), input.GetSize()));
		    if (!sheet) {
			    is_null = true;
			    return string_t();
		    }
		    return StringVector::AddString(result, sheet->text, std::strlen(sheet->text));
	    });
}

void LibraryExec(DataChunk &args, ExpressionState &, Vector &result) {
	MarcReferenceValue(result, Value(std::string(marc::XSLT_LIBRARY_TEXT)), args.size());
}

} // namespace

void RegisterMarcXslt(ExtensionLoader &loader) {
	TableFunction catalog("marc_xslt_functions", {}, XsltCatalogScan, XsltCatalogBind, XsltCatalogInitGlobal);
	MarcRegisterTable(loader, std::move(catalog), "marc_xslt_functions");

	auto V = LogicalType::VARCHAR;
	MarcRegisterScalar(loader,ScalarFunction("marc_xslt_stylesheet", {V}, V, StylesheetExec));
	MarcRegisterScalar(loader,ScalarFunction("marc_xslt_library", {}, V, LibraryExec));
}

} // namespace duckdb
