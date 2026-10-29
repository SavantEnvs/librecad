#!/usr/bin/env bash
#
# mayhem/build.sh — build LibreCAD's libdxfrw (the DXF/DWG reader library, no Qt dependency) in two
# independent configurations, plus the fuzz harnesses and the project's own Catch2 test lane:
#   build/fuzz/   sanitized (ASan+UBSan, halting) + DWARF 3 objects -> /mayhem/<fuzzer>, <fuzzer>-standalone
#   build/tests/  NORMAL flags (-O1, no sanitizers)                 -> build/tests/libdxfrw_fast_tests
# Mirrors upstream's `libdxfrw_fast_tests` CMake target (CMakeLists.txt) without configuring the Qt GUI
# application. Re-runnable (everything is rebuilt into build/, which upstream's .gitignore covers) and
# offline (system headers only; Catch2 comes from the image's apt package).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
LIB=libraries/libdxfrw
INC=(-I"$LIB/src" -I"$LIB/src/intern" -I"$LIB/tests/fuzz")
LIBSRCS=("$LIB"/src/[!.]*.cpp "$LIB"/src/intern/[!.]*.cpp)

# compile_objs <outdir> <compile flags...> -- <sources...>   (parallel; one .o per source)
compile_objs() {
  local out="$1"; shift
  local flags=()
  while [ "$1" != "--" ]; do flags+=("$1"); shift; done
  shift
  mkdir -p "$out"
  printf '%s\n' "$@" | xargs -P "$MAYHEM_JOBS" -I{} bash -c '
    src="$1"; out="$2"; shift 2
    o="$out/$(echo "$src" | tr / _).o"
    '"$CXX"' "$@" -c "$src" -o "$o"' _ {} "$out" "${flags[@]}"
}

# 1) sanitized + DWARF-3 libdxfrw objects for the fuzz harnesses. -fsanitize=fuzzer-no-link instruments the
#    LIBRARY for libFuzzer coverage (without it only the harness TU is instrumented and the fuzzer is blind).
#    The sanitizer runtimes supply the coverage callbacks, so the standalone reproducer can reuse these
#    objects; with an empty SANITIZER_FLAGS it gets its own uninstrumented set.
# shellcheck disable=SC2086
compile_objs build/fuzz -std=c++17 -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -DDWGSUPPORT -D_USE_MATH_DEFINES "${INC[@]}" -- "${LIBSRCS[@]}"
STANDALONE_OBJS=build/fuzz
if [ -z "$SANITIZER_FLAGS" ]; then
  STANDALONE_OBJS=build/standalone
  # shellcheck disable=SC2086
  compile_objs build/standalone -std=c++17 -O1 $DEBUG_FLAGS -DDWGSUPPORT -D_USE_MATH_DEFINES "${INC[@]}" -- "${LIBSRCS[@]}"
fi

# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build/fuzz/lsan_off.o
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build/fuzz/standalone_main.o

# 2) harnesses: libFuzzer binary + run-once standalone reproducer
for h in fuzz_dxf_read fuzz_dwg_read; do
  # shellcheck disable=SC2086
  $CXX -std=c++17 -O1 $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "${INC[@]}" \
      "mayhem/harnesses/$h.cpp" build/fuzz/libraries_*.o build/fuzz/lsan_off.o -o "/mayhem/$h"
  # shellcheck disable=SC2086
  $CXX -std=c++17 -O1 $SANITIZER_FLAGS $DEBUG_FLAGS "${INC[@]}" \
      "mayhem/harnesses/$h.cpp" "$STANDALONE_OBJS"/libraries_*.o build/fuzz/lsan_off.o build/fuzz/standalone_main.o \
      -o "/mayhem/$h-standalone"
done

# 3) upstream's Qt-free libdxfrw Catch2 lane (libdxfrw_fast_tests), NORMAL flags
TESTS=librecad/src/lib/filters/tests
TEST_SRCS=(
  librecad/src/test/lc_testtempdirectory.cpp
  $TESTS/dwg_buffer_round_trip_tests.cpp $TESTS/dwg_decompress18_tests.cpp
  $TESTS/dwg_entity_encode_round_trip_tests.cpp $TESTS/lc_attrib_embedded_mtext_dwg_tests.cpp
  $TESTS/dwg_header_encode_round_trip_tests.cpp $TESTS/dwg_handseed_tests.cpp $TESTS/dynblock_tests.cpp
  $TESTS/dwg_object_encode_round_trip_tests.cpp $TESTS/dwg_object_frame_tests.cpp $TESTS/dwg_safety_tests.cpp
  $TESTS/mesh_tests.cpp $TESTS/dxf_attribute_tests.cpp $TESTS/dxf_object_tests.cpp
  $TESTS/field_dxf_tests.cpp $TESTS/mleader_dxf_context_tests.cpp
)
TDEFS=(-DBUILD_TESTS=1 -DDWGSUPPORT -D_USE_MATH_DEFINES
       -DLIBRECAD_SOURCE_DIR="\"$SRC\"" -DLIBRECAD_TEST_DIR="\"$SRC/$TESTS/testdata\"")
compile_objs build/tests -std=c++17 -O1 $COVERAGE_FLAGS "${TDEFS[@]}" "${INC[@]}" -Ilibrecad/src/test -Ilibrecad/src/lib/engine/document -- "${LIBSRCS[@]}" "${TEST_SRCS[@]}"
# shellcheck disable=SC2086
$CXX -std=c++17 $COVERAGE_FLAGS build/tests/*.o -lCatch2Main -lCatch2 -o build/tests/libdxfrw_fast_tests
