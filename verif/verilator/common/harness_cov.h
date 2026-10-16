// harness_cov.h -- coverage output for the hand-written Verilator harnesses.
//
// Shared by tb_core.cpp, tb_decoder.cpp and tb_act4.cpp so the three cannot
// drift apart. M3.7 stage 1; docs/results/0028.
//
// WHY EACH PIECE EXISTS
//
// None of the three harnesses wrote coverage before this. A binary built with
// --coverage-* ran, passed, and left no file: a silent zero.
//
// --cov-file is parsed from the harness's OWN argv, not taken from Verilator's
// +verilator+coverage+file+ plusarg. tb_act4.cpp rebuilds argv for Verilated
// as {argv[0], "+HEX=..."}, so a plusarg would be discarded and all 47 ACT4
// tests would write one default coverage.dat, 20 at a time. A second write
// OVERWRITES the first (measured, verif/verilator/cov_semantics T1).
//
// check() refuses the wrong configuration IN BOTH DIRECTIONS. Verilator
// defines VM_COVERAGE=1 in a coverage build. Instrumented with no destination
// would silently write nothing; not instrumented with a destination would let
// a caller believe coverage was collected when nothing could be.
//
// write() must run BEFORE the model is deleted. Coverage points hold POINTERS
// to counters inside the model (_inserti(uint32_t*) in verilated_cov.h), so a
// write after `delete` reads freed memory. Every harness routes every exit
// through one finish path that calls write() first.
//
// write() checks the file it wrote exists and is non-empty, rather than
// trusting the call. PROJECT_INSTRUCTIONS 4.5: a step that reports success
// without verifying the work happened has cost this project four times.

#pragma once

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#if VM_COVERAGE
#include <verilated_cov.h>
#endif

struct HarnessCov {
    std::string file;
    bool        written = false;

    // Call from the harness's argument loop. Returns true if argv[i] was
    // --cov-file, in which case its value has been consumed (i advanced).
    bool parse(int argc, char **argv, int &i) {
        if (std::strcmp(argv[i], "--cov-file") != 0) return false;
        if (i + 1 >= argc) {
            std::fprintf(stderr, "harness: FATAL: --cov-file needs a path\n");
            std::exit(2);
        }
        file = argv[++i];
        return true;
    }

    // Call once, after argument parsing and before the model is built.
    void check() const {
#if VM_COVERAGE
        if (file.empty()) {
            std::fprintf(stderr,
                "harness: FATAL: this binary is built WITH coverage and no "
                "--cov-file was given; nothing would be written\n");
            std::exit(2);
        }
#else
        if (!file.empty()) {
            std::fprintf(stderr,
                "harness: FATAL: this binary is built WITHOUT coverage; "
                "--cov-file %s would never be written\n", file.c_str());
            std::exit(2);
        }
#endif
    }

    // Call at every exit, BEFORE the model is deleted. No-op in a normal build.
    void write() {
#if VM_COVERAGE
        if (written) return;
        // c_str(): 5.050 declares write(const std::string&), 5.020
        // write(const char*). A const char* satisfies both.
        VerilatedCov::write(file.c_str());
        written = true;
        std::FILE *f = std::fopen(file.c_str(), "rb");
        if (!f) {
            std::fprintf(stderr, "harness: FATAL: coverage write reported no "
                                 "error but %s does not exist\n", file.c_str());
            std::exit(2);
        }
        std::fseek(f, 0, SEEK_END);
        long n = std::ftell(f);
        std::fclose(f);
        if (n <= 0) {
            std::fprintf(stderr, "harness: FATAL: coverage file %s is empty\n",
                         file.c_str());
            std::exit(2);
        }
        std::fprintf(stderr, "harness: coverage written to %s (%ld bytes)\n",
                     file.c_str(), n);
#endif
    }
};
