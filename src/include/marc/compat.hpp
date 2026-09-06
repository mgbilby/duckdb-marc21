#pragma once
#include <type_traits>
#include "duckdb/common/string_util.hpp"
#include "duckdb/function/copy_function.hpp"
#include "duckdb/function/table_function.hpp"

namespace duckdb {
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
} // namespace duckdb
