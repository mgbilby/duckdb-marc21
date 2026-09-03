#pragma once

#include "duckdb.hpp"

namespace marc {
struct Record;
}

namespace duckdb {

class ExtensionLoader;
void RegisterMarcCopy(ExtensionLoader &loader);
void RegisterMarcScalars(ExtensionLoader &loader);
//! The STRUCT type of one element of the nested `fields` column.
const LogicalType &MarcFieldStructType();
//! A record's fields as the nested LIST(STRUCT) value (no tag filtering).
Value MarcFieldsToValue(const marc::Record &rec);
//! The inverse: a (leader, fields) value pair as a core Record.
marc::Record MarcValuesToRecord(const Value &leader, const Value &fields);
Value MarcStringsToList(const std::vector<std::string> &strings);
void RegisterMarcEditScalars(ExtensionLoader &loader);
void RegisterMarcZ3950(ExtensionLoader &loader);

class Marc21Extension : public Extension {
public:
	void Load(ExtensionLoader &loader) override;
	std::string Name() override;
	std::string Version() const override;
};

} // namespace duckdb
