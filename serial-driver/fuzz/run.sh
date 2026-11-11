#!/bin/sh
# SPDX-License-Identifier: CC0-1.0
# Build the fuzz harness and run it. Needs clang with libFuzzer.
# Ubuntu: apt-get install clang libclang-rt-18-dev
# macOS:  any LLVM clang 22 (MacPorts, Homebrew, llvm.org). Xcode's clang has
#         no libFuzzer, and the AddressSanitizer of LLVM 19 hangs at start on
#         macOS 27. Set CXX to choose the compiler yourself.
# Usage: fuzz/run.sh [seconds]        fuzz for that long (default 60)
#        fuzz/run.sh --replay FILE    run one saved input and print the calls
set -eu
cd "$(dirname "$0")"
mkdir -p build corpus
if [ "$(uname)" = Darwin ]; then
    if [ -z "${CXX:-}" ]; then
        # Take the first clang that has libFuzzer.
        for c in clang++ /opt/homebrew/opt/llvm/bin/clang++ \
                 /usr/local/opt/llvm/bin/clang++ clang++-mp-22; do
            if [ -e "$("$c" -print-runtime-dir 2>/dev/null)/libclang_rt.fuzzer_osx.a" ]; then
                CXX=$c
                break
            fi
        done
    fi
    if [ -z "${CXX:-}" ]; then
        echo "run.sh: no clang with libFuzzer found (Xcode's has none)." >&2
        echo "Install LLVM clang 22 and run again with CXX=/path/to/clang++" >&2
        exit 1
    fi
    echo "run.sh: using $CXX" >&2
    # Leak detection is on by default on Linux but off on macOS. There it
    # also reports a thread that libFuzzer itself never frees; hide only that.
    export ASAN_OPTIONS="detect_leaks=1${ASAN_OPTIONS:+:$ASAN_OPTIONS}"
    export LSAN_OPTIONS="suppressions=$PWD/lsan-macos.supp:print_suppressions=0${LSAN_OPTIONS:+:$LSAN_OPTIONS}"
fi
${CXX:-clang++} -std=c++17 -g -O1 -fsanitize=fuzzer,address,undefined \
    -fno-sanitize-recover=undefined -Wall -Wextra -Ishim \
    fuzz_driver.cpp ../Driver/QuectelSerialInterface.cpp ../Driver/QuectelSerialPort.cpp \
    -o build/fuzz_driver
if [ "${1:-}" = --replay ]; then
    FUZZ_TRACE=1 exec build/fuzz_driver "$2"
fi
# Inputs that found bugs before must stay clean.
build/fuzz_driver regressions/*
exec build/fuzz_driver -max_total_time="${1:-60}" -max_len=256 -timeout=10 \
    -artifact_prefix=build/ corpus regressions
