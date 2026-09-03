cmake_minimum_required(VERSION 3.5)

set(TARGET_NAME marc21)
set(EXTENSION_NAME ${TARGET_NAME}_extension)
set(LOADABLE_EXTENSION_NAME ${TARGET_NAME}_loadable_extension)

project(${TARGET_NAME})

include_directories(src/include)

# Embed src/macros.sql as a raw-string header at configure time.
file(READ ${CMAKE_CURRENT_SOURCE_DIR}/src/macros.sql MARC21_MACROS_SQL)
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/marc21_gen/marc/macros_sql.hpp
     "// GENERATED from src/macros.sql by CMake; do not edit.\n#pragma once\nnamespace marc {\ninline constexpr const char *MACROS_SQL = R\"MARCSQL(\n${MARC21_MACROS_SQL})MARCSQL\";\n} // namespace marc\n")
include_directories(${CMAKE_CURRENT_BINARY_DIR}/marc21_gen)

set(EXTENSION_SOURCES
    src/marc_extension.cpp
    src/marc_copy.cpp
    src/marc_scalars.cpp
    src/marc_edit_scalars.cpp
    src/marc_z3950.cpp
    src/core/avram.cpp
    src/core/marcspec.cpp
    src/core/edit.cpp
    src/core/idnorm.cpp
    src/core/json.cpp
    src/core/marcjson.cpp
    src/core/textwriters.cpp
    src/core/aleph.cpp
    src/core/catalog.cpp
    src/core/callnum.cpp
    src/core/iso2709.cpp
    src/core/marc8.cpp
    src/core/unicode_nfc.cpp
    src/core/writer.cpp
    src/core/breaker.cpp
    src/core/marcxml.cpp
    src/core/z3950.cpp
    src/core/z3950_socket.cpp)

build_static_extension(${TARGET_NAME} ${EXTENSION_SOURCES})
build_loadable_extension(${TARGET_NAME} " " ${EXTENSION_SOURCES})

# The core uses C++17 (DuckDB's own targets default to C++11).
set_target_properties(${EXTENSION_NAME} ${LOADABLE_EXTENSION_NAME}
                      PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)

# The Z39.50 transport uses Winsock on Windows.
if(WIN32)
  target_link_libraries(${EXTENSION_NAME} ws2_32)
  target_link_libraries(${LOADABLE_EXTENSION_NAME} ws2_32)
endif()

install(
  TARGETS ${EXTENSION_NAME}
  EXPORT "${DUCKDB_EXPORT_SET}"
  LIBRARY DESTINATION "${INSTALL_LIB_DIR}"
  ARCHIVE DESTINATION "${INSTALL_LIB_DIR}")
