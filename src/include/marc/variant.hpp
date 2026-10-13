//! Registration entry point for the VARIANT rendering of a MARC record.
//!
//! Kept out of marc21_extension.hpp because the whole surface is conditional:
//! VARIANT construction is spelled differently on DuckDB v1.5.x and v2.0 (see
//! marc_variant.cpp), so the one declaration that crosses translation units
//! lives next to the code that has to reason about that split.
#pragma once

namespace duckdb {

class ExtensionLoader;

//! marc_variant(leader, fields) and marc_variant_record(record) -> VARIANT.
void RegisterMarcVariant(ExtensionLoader &loader);

} // namespace duckdb
