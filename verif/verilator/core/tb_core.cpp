// M3.2 core harness.
//
// Loads a hex program into the TCM via DPI, releases reset, runs until the
// program stores to ADDR_TESTCTL (0 = PASS, anything else = FAIL) or the cycle
// budget expires.
//
// A retirement trace is printed on request. The instruction word is looked up
// from the loaded image by PC rather than carried through the pipeline - the
// TCM is not self-modifying in any test here, so PC determines it uniquely.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>
#include <verilated.h>
#include "Vcore_tb_top.h"

static std::vector<uint32_t> image;      // program image, for PC -> instr lookup

// The RTL loads the memory itself via $readmemh and a +HEX= plusarg. This
// only mirrors the image so the trace can look an instruction up by PC.
static void read_image(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) { printf("FATAL: cannot open %s\n", path); exit(2); }
    char line[256];
    while (fgets(line, sizeof line, f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\0' || *p == '\n' || *p == '/' || *p == '#') continue;
        image.push_back((uint32_t)strtoul(p, nullptr, 16));
    }
    fclose(f);
    printf("harness: mirrored %zu words from %s\n", image.size(), path);
}

static uint32_t instr_at(uint32_t pc) {
    uint32_t idx = pc >> 2;
    return idx < image.size() ? image[idx] : 0x00000013u;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    const char *hex   = nullptr;
    long max_cycles   = 10000;
    bool trace        = false;
    bool have_expect  = false;
    uint32_t expect   = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--hex") && i + 1 < argc)       hex = argv[++i];
        else if (!strcmp(argv[i], "--cycles") && i + 1 < argc) max_cycles = atol(argv[++i]);
        else if (!strcmp(argv[i], "--trace"))                 trace = true;
        else if (!strcmp(argv[i], "--expect") && i + 1 < argc) {
            expect = (uint32_t)strtoul(argv[++i], nullptr, 0);
            have_expect = true;
        }
    }
    if (!hex) { printf("usage: %s --hex prog.hex [--cycles N] [--trace]\n", argv[0]); return 2; }

    Vcore_tb_top *dut = new Vcore_tb_top;

    // The RTL's initial block has already run $readmemh by this point, driven
    // by the +HEX= plusarg forwarded through Verilated::commandArgs.
    dut->clk = 0; dut->rst_n = 0;
    dut->eval();
    read_image(hex);

    long cycle = 0, retired = 0;
    // `done` is separate from `result`. Overloading result's SIGN to also mean
    // "never assigned" was a bug: a checksum of 0xeffe3c3e is NEGATIVE as a
    // signed int, so a correct run reported TIMEOUT.
    bool     done   = false;
    uint32_t result = 0;

    for (; cycle < max_cycles; cycle++) {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();

        if (cycle == 5) dut->rst_n = 1;
        if (cycle < 5)  continue;

        if (dut->trace_valid) {
            retired++;
            if (trace) {
                printf("%6ld  pc=0x%08x  instr=0x%08x", cycle,
                       (uint32_t)dut->trace_pc, instr_at(dut->trace_pc));
                if (dut->trace_rd_we && dut->trace_rd_addr)
                    printf("  x%-2d <= 0x%08x", dut->trace_rd_addr,
                           (uint32_t)dut->trace_rd_data);
                if (dut->trace_mem_we)
                    printf("  mem[0x%08x] <= 0x%08x",
                           (uint32_t)dut->trace_mem_addr,
                           (uint32_t)dut->trace_mem_wdata);
                printf("\n");
            }
        }

        if (dut->console_we) { putchar((char)dut->console_char); fflush(stdout); }

        if (dut->misaligned)
            printf("WARN cycle %ld: misaligned data access\n", cycle);

        if (dut->testctl_we) {
            result = (uint32_t)dut->testctl_data;
            done   = true;
            break;
        }
    }

    printf("\ncycles=%ld  retired=%ld\n", cycle, retired);
    if (!done) {
        printf("RESULT: TIMEOUT (no write to test control after %ld cycles)\n", max_cycles);
        delete dut; return 1;
    }
    printf("stored value: 0x%08x\n", result);

    // With --expect, the stored value is a CHECKSUM compared against a golden
    // value. Without it, the convention is 0 = pass (t01, t02).
    if (have_expect) {
        if (result == expect) { printf("RESULT: PASS\n"); delete dut; return 0; }
        printf("RESULT: FAIL (expected 0x%08x, got 0x%08x)\n", expect, result);
        delete dut; return 1;
    }
    if (result == 0) { printf("RESULT: PASS\n");  delete dut; return 0; }
    printf("RESULT: FAIL (code %u / 0x%x)\n", result, result);
    delete dut; return 1;
}
