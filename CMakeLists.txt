cmake_minimum_required(VERSION 3.5)

set(TARGET_NAME marc21)
set(EXTENSION_NAME ${TARGET_NAME}_extension)
set(LOADABLE_EXTENSION_NAME ${TARGET_NAME}_loadable_extension)

project(${TARGET_NAME})

include_directories(src/include)

# Embed src/macros.sql, plus every src/macros/*.sql (sorted), as one
# raw-string header at configure time.
file(READ ${CMAKE_CURRENT_SOURCE_DIR}/src/macros.sql MARC21_MACROS_SQL)
file(GLOB MARC21_EXTRA_MACRO_FILES ${CMAKE_CURRENT_SOURCE_DIR}/src/macros/*.sql)
list(SORT MARC21_EXTRA_MACRO_FILES)
foreach(MARC21_MACRO_FILE ${MARC21_EXTRA_MACRO_FILES})
  file(READ ${MARC21_MACRO_FILE} MARC21_ONE_MACRO_FILE)
  string(APPEND MARC21_MACROS_SQL "\n" "${MARC21_ONE_MACRO_FILE}")
endforeach()
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/marc21_gen/marc/macros_sql.hpp
     "// GENERATED from src/macros.sql by CMake; do not edit.\n#pragma once\nnamespace marc {\ninline constexpr const char *MACROS_SQL = R\"MARCSQL(\n${MARC21_MACROS_SQL})MARCSQL\";\n} // namespace marc\n")

# Embed the XSLT crosswalk catalog (xslt/registry.tsv), every stylesheet it
# names, and the shared helper library, as one generated header at configure
# time - the same read-at-configure pattern as the macro layer above, so an
# installed extension carries its stylesheets inside the binary.
#
# Registry fields may contain any character except a tab (the column
# separator) and a double quote (they are emitted as C string literals).
# Stylesheet text goes in as raw string literals with a delimiter no
# stylesheet uses; MSVC caps one string literal near 16 KB, so each sheet is
# cut at line boundaries into adjacent literals the compiler concatenates.
set(MARC21_XSLT_CHUNK 8000)

function(marc21_xslt_literal OUTVAR TEXT)
  set(_out "")
  string(LENGTH "${TEXT}" _len)
  set(_pos 0)
  while(_pos LESS _len)
    math(EXPR _remain "${_len} - ${_pos}")
    if(_remain LESS_EQUAL ${MARC21_XSLT_CHUNK})
      set(_take ${_remain})
    else()
      string(SUBSTRING "${TEXT}" ${_pos} ${MARC21_XSLT_CHUNK} _probe)
      string(FIND "${_probe}" "\n" _nl REVERSE)
      if(_nl LESS 0)
        set(_take ${MARC21_XSLT_CHUNK})
      else()
        math(EXPR _take "${_nl} + 1")
      endif()
    endif()
    string(SUBSTRING "${TEXT}" ${_pos} ${_take} _piece)
    string(APPEND _out "     R\"MARCXSLT_EMBED(${_piece})MARCXSLT_EMBED\"\n")
    math(EXPR _pos "${_pos} + ${_take}")
  endwhile()
  if(_out STREQUAL "")
    set(_out "     \"\"\n")
  endif()
  set(${OUTVAR} "${_out}" PARENT_SCOPE)
endfunction()

set(MARC21_XSLT_REGISTRY ${CMAKE_CURRENT_SOURCE_DIR}/xslt/registry.tsv)
set(MARC21_XSLT_LIBRARY ${CMAKE_CURRENT_SOURCE_DIR}/xslt/marc-utils.xsl)
file(STRINGS ${MARC21_XSLT_REGISTRY} MARC21_XSLT_LINES)
set(MARC21_XSLT_ROWS "")
set(MARC21_XSLT_COUNT 0)
set(MARC21_XSLT_DEPENDS ${MARC21_XSLT_REGISTRY} ${MARC21_XSLT_LIBRARY})
foreach(MARC21_XSLT_LINE IN LISTS MARC21_XSLT_LINES)
  if(MARC21_XSLT_LINE STREQUAL "" OR MARC21_XSLT_LINE MATCHES "^#")
    continue()
  endif()
  if(NOT MARC21_XSLT_LINE MATCHES "^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
    message(FATAL_ERROR "xslt/registry.tsv: expected five tab-separated columns in: ${MARC21_XSLT_LINE}")
  endif()
  set(MARC21_XSLT_ALIAS "${CMAKE_MATCH_1}")
  set(MARC21_XSLT_PATH "${CMAKE_MATCH_2}")
  set(MARC21_XSLT_SRC "${CMAKE_MATCH_3}")
  set(MARC21_XSLT_TGT "${CMAKE_MATCH_4}")
  set(MARC21_XSLT_DESC "${CMAKE_MATCH_5}")
  if(MARC21_XSLT_ALIAS STREQUAL "alias")
    continue()
  endif()
  file(READ ${CMAKE_CURRENT_SOURCE_DIR}/${MARC21_XSLT_PATH} MARC21_XSLT_TEXT)
  marc21_xslt_literal(MARC21_XSLT_LIT "${MARC21_XSLT_TEXT}")
  string(APPEND MARC21_XSLT_ROWS
         "    {\"${MARC21_XSLT_ALIAS}\", \"${MARC21_XSLT_PATH}\", \"${MARC21_XSLT_SRC}\", \"${MARC21_XSLT_TGT}\",\n"
         "     \"${MARC21_XSLT_DESC}\",\n${MARC21_XSLT_LIT}    },\n")
  list(APPEND MARC21_XSLT_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/${MARC21_XSLT_PATH})
  math(EXPR MARC21_XSLT_COUNT "${MARC21_XSLT_COUNT} + 1")
endforeach()
file(READ ${MARC21_XSLT_LIBRARY} MARC21_XSLT_LIB_TEXT)
marc21_xslt_literal(MARC21_XSLT_LIB_LIT "${MARC21_XSLT_LIB_TEXT}")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${MARC21_XSLT_DEPENDS})
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/marc21_gen/marc/xslt_embedded.hpp
     "// GENERATED from xslt/registry.tsv and the stylesheets it names by CMake; do not edit.\n"
     "#pragma once\n\n"
     "#include <cstddef>\n\n"
     "namespace marc {\n\n"
     "//! One shipped crosswalk: catalog row plus the stylesheet text itself.\n"
     "struct XsltSheet {\n"
     "\tconst char *alias;\n\tconst char *path;\n\tconst char *source_format;\n"
     "\tconst char *target_format;\n\tconst char *description;\n\tconst char *text;\n};\n\n"
     "inline constexpr XsltSheet XSLT_SHEETS[] = {\n${MARC21_XSLT_ROWS}};\n\n"
     "inline constexpr size_t XSLT_SHEET_COUNT = ${MARC21_XSLT_COUNT};\n\n"
     "//! The shared helper library every stylesheet includes as lib/marc-utils.xsl.\n"
     "inline constexpr const char *XSLT_LIBRARY_PATH = \"xslt/marc-utils.xsl\";\n"
     "inline constexpr const char *XSLT_LIBRARY_TEXT =\n${MARC21_XSLT_LIB_LIT}    ;\n\n"
     "} // namespace marc\n")

include_directories(${CMAKE_CURRENT_BINARY_DIR}/marc21_gen)

set(EXTENSION_SOURCES
    src/marc_extension.cpp
    src/marc_copy.cpp
    src/marc_scalars.cpp
    src/marc_edit_scalars.cpp
    src/marc_cluster_scalars.cpp
    src/marc_authlink_scalars.cpp
    src/marc_z3950.cpp
    src/marc_xslt.cpp
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
    src/core/microlif.cpp
    src/core/cluster.cpp
    src/core/authlink.cpp
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
