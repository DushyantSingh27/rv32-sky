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
#include "../common/harness_cov.h"

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
    HarnessCov cov;
    // --reset-at N: a SECOND reset at cycle N, held 5 cycles. Verilator
    // starts every flop at zero, so a flop whose reset is missing and whose
    // reset value is zero passes every run that resets only once. Asserting
    // reset again after the state has gone non-zero is what exposes it.
    // docs/results/0028.
    long reset_at     = 0;
    long reset_req_pc = -1;    // --reset-require-pc: the pre-reset run must retire here
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--hex") && i + 1 < argc)       hex = argv[++i];
        else if (!strcmp(argv[i], "--cycles") && i + 1 < argc) max_cycles = atol(argv[++i]);
        else if (!strcmp(argv[i], "--trace"))                 trace = true;
        else if (!strcmp(argv[i], "--expect") && i + 1 < argc) {
            expect = (uint32_t)strtoul(argv[++i], nullptr, 0);
            have_expect = true;
        }
        else if (!strcmp(argv[i], "--reset-at") && i + 1 < argc)
            reset_at = atol(argv[++i]);
        else if (!strcmp(argv[i], "--reset-require-pc") && i + 1 < argc)
            reset_req_pc = (long)strtoul(argv[++i], nullptr, 0);
        else if (cov.parse(argc, argv, i)) {}
    }
    cov.check();
    if (!hex) { printf("usage: %s --hex prog.hex [--cycles N] [--trace]\n", argv[0]); return 2; }
    if (reset_at != 0 && reset_at <= 10) {
        printf("FATAL: --reset-at %ld: must be > 10 (the first reset releases at cycle 5)\n", reset_at);
        return 2;
    }
    if (reset_req_pc >= 0 && !reset_at) {
        printf("FATAL: --reset-require-pc needs --reset-at\n");
        return 2;
    }

    Vcore_tb_top *dut = new Vcore_tb_top;
    // Every exit from here on goes through finish(): coverage is written
    // while the model, which owns the counters, still exists. harness_cov.h
    auto finish = [&](int rc) { cov.write(); delete dut; return rc; };

    // The RTL's initial block has already run $readmemh by this point, driven
    // by the +HEX= plusarg forwarded through Verilated::commandArgs.
    dut->clk = 0; dut->rst_n = 0;
    dut->eval();
    read_image(hex);

    long cycle = 0, retired = 0;

    // Reset-twice bookkeeping. `pre` is every retirement before the second
    // reset - a prefix of a clean run, which lockstep matches against Sail.
    // `post` is every retirement after it - a full run from reset. PASS
    // requires post to begin with pre, exactly.
    struct Rec { uint32_t pc, rd, val; };
    std::vector<Rec> pre, post;
    int phase = 0;             // 0 before the second reset, 1 held in it, 2 after
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

        if (reset_at) {
            if (phase == 0 && cycle == reset_at) {
                dut->rst_n = 0;
                phase = 1;
                printf("harness: second reset asserted at cycle %ld, after %zu retirements\n",
                       cycle, pre.size());
            }
            if (phase == 1) {
                if (cycle == reset_at + 5) {
                    dut->rst_n = 1;
                    phase = 2;
                    printf("harness: second reset released at cycle %ld\n", cycle);
                }
                continue;
            }
        }

        if (dut->trace_valid) {
            retired++;
            if (reset_at) {
                const bool w = dut->trace_rd_we && dut->trace_rd_addr;
                Rec r{(uint32_t)dut->trace_pc,
                      w ? (uint32_t)dut->trace_rd_addr : 0u,
                      w ? (uint32_t)dut->trace_rd_data : 0u};
                (phase == 0 ? pre : post).push_back(r);
            }
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
        return finish(1);
    }
    printf("stored value: 0x%08x\n", result);

    if (reset_at) {
        char why[256] = "";
        bool seen_pc = (reset_req_pc < 0);
        for (const Rec &r : pre) if ((long)r.pc == reset_req_pc) seen_pc = true;
        if (phase != 2)
            snprintf(why, sizeof why, "the program finished before the second reset at cycle %ld", reset_at);
        else if (pre.size() < 30)
            snprintf(why, sizeof why, "only %zu retirements before the second reset; at least 30 are required", pre.size());
        else if (!seen_pc)
            snprintf(why, sizeof why, "the pre-reset run never retired an instruction at 0x%08lx", reset_req_pc);
        else if (post.size() < pre.size())
            snprintf(why, sizeof why, "%zu retirements after the second reset, fewer than the %zu before it", post.size(), pre.size());
        else
            for (size_t i = 0; i < pre.size(); i++)
                if (pre[i].pc != post[i].pc || pre[i].rd != post[i].rd || pre[i].val != post[i].val) {
                    snprintf(why, sizeof why,
                             "retirement %zu differs: before pc=0x%08x x%u=0x%08x, after pc=0x%08x x%u=0x%08x",
                             i, pre[i].pc, pre[i].rd, pre[i].val, post[i].pc, post[i].rd, post[i].val);
                    break;
                }
        if (why[0]) { printf("RESULT: FAIL (reset-twice: %s)\n", why); return finish(1); }
        printf("reset-twice: all %zu pre-reset retirements match the first %zu of %zu after it\n",
               pre.size(), pre.size(), post.size());
    }

    // With --expect, the stored value is a CHECKSUM compared against a golden
    // value. Without it, the convention is 0 = pass (t01, t02).
    if (have_expect) {
        if (result == expect) { printf("RESULT: PASS\n"); return finish(0); }
        printf("RESULT: FAIL (expected 0x%08x, got 0x%08x)\n", expect, result);
        return finish(1);
    }
    if (result == 0) { printf("RESULT: PASS\n");  return finish(0); }
    printf("RESULT: FAIL (code %u / 0x%x)\n", result, result);
    return finish(1);
}
