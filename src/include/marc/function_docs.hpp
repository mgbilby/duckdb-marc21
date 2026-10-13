#pragma once

//! Catalog documentation for every function marc21 registers.
//!
//! An agent or tool connected to a database learns what an extension offers
//! only through duckdb_functions(): the README is not reachable from a SQL
//! connection.  So each function -- C++ scalar, reader, or embedded macro --
//! is registered with a FunctionDescription carrying a one-line description,
//! a runnable example, categories and, for the C++ functions, real argument
//! names in place of col0, col1, ...  The community-extensions site builds a
//! page's "Added Functions" table from the same columns.
//!
//! The text lives in one table (src/marc_function_docs.cpp) keyed by function
//! name, so the registration sites stay as they were and a missing entry is
//! caught by test/sql/marc_function_docs.test rather than by a reader.

#include "duckdb/parser/parsed_data/create_function_info.hpp"

namespace duckdb {

struct MarcFunctionDoc {
	const char *name;
	//! Positional argument names, comma separated.  C++ signatures carry types
	//! only, so these replace col0, col1, ...  Empty for macros, whose own
	//! parameter names are already what duckdb_functions() reports, and for
	//! functions without arguments.  A reader's named parameters (encoding,
	//! tags, ...) are added at registration from the function itself.
	const char *parameters;
	//! One line: duckdb_functions() and the community-extensions page show it
	//! as is, and the page keeps only the first line.
	const char *description;
	//! One runnable call: a bare expression where the arguments can be
	//! literals, otherwise a full statement over a file.
	const char *example;
	//! Comma-separated tags.
	const char *categories;
};

//! The entry for `name`, or nullptr when the table has none.
const MarcFunctionDoc *MarcFindFunctionDoc(const string &name);

//! The FunctionDescription for `name`, or nothing when the table has no entry
//! -- an undocumented function still registers, it just has no description.
vector<FunctionDescription> MarcFunctionDescriptions(const string &name);

} // namespace duckdb
