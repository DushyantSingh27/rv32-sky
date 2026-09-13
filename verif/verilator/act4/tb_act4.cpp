// ACT4 compliance harness.
//
// Loads a RISC-V ELF into the TCM, runs it, and decodes HTIF. Invoked by
// riscv-arch-test's run_tests.py via config/cores/rv32sky/run_cmd.txt, which
// appends the ELF path as the final argument.
//
// TWO SIGNALS ARE REQUIRED, NOT ONE.
// run_tests.py computes:
//     failed = exit_failed or summary_failed or summary_sigrun or no_summary
// so a test passes only if the exit code is 0 AND an RVCP-SUMMARY line appears
// on stdout. That line is printed BY THE TEST, through RVMODEL_IO_WRITE_STR,
// as HTIF console characters. Decoding the console path is therefore mandatory:
// a harness that terminates correctly but drops console writes reports
// "exit code 0 but no RVCP-SUMMARY line found" on every test.
//
// HTIF PROTOCOL, from verif/compliance/rv32sky/rvmodel_macros.h:
//   Both halves of the 64-bit tohost are written INSIDE the loop, low first:
//     terminate: low = 1 (pass) or 3 (fail), high = 0
//     console:   low = character,            high = 0x01010000 (dev 1, cmd 1)
//   A single store is ignored by Sail HTIF and produced a 10.5 GB trace
//   (PROJECT_CONTEXT section 9, verified 2026-08-20). We latch on the low
//   store and dispatch on the high store, matching the order the macro writes.
//
// WHY THE ELF IS PARSED HERE RATHER THAN VIA objcopy/nm.
// run_tests.py defaults to one job per core (20 here) with a 300s timeout.
// Two subprocesses per test across 240 parallel runs makes failures harder to
// attribute and adds toolchain paths to the harness. The cost is that a parser
// bug produces a plausible-looking wrong image, which is failure mode #1. That
// is why --dump-hex exists and why the objdump cross-check is a gate before
// any suite run, not an optional extra.
//
// WHY --force-fail EXISTS.
// docs/results/0018: a checker that cannot fail is not evidence. run_lockstep.sh
// carries NOEXPECT=1 for the same reason - it blanks the expected values and
// must reproduce a failure on known-good data. --force-fail inverts a PASS
// termination into a failure, so the decode can be shown to fail on input it
// should fail on before a green suite is trusted.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cstdarg>
#include <unistd.h>
#include <elf.h>
#include <map>
#include <string>
#include <vector>
#include <verilated.h>
#include "Vcore_tb_top.h"

// ---------------------------------------------------------------------------
// ELF loading
// ---------------------------------------------------------------------------

struct LoadedElf {
    std::map<uint32_t, uint32_t> words;   // word index -> value
    uint32_t tohost   = 0;
    bool     have_tohost = false;
    uint32_t entry    = 0;
    uint32_t top_byte = 0;                // highest byte address touched
};

static void die(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "harness: FATAL: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    exit(2);
}

static std::vector<uint8_t> read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) die("cannot open %s", path);
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    if (n <= 0) die("%s is empty", path);
    fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> buf((size_t)n);
    if (fread(buf.data(), 1, (size_t)n, f) != (size_t)n) die("short read on %s", path);
    fclose(f);
    return buf;
}

// Little-endian scalar reads. The ELF is checked for ELFDATA2LSB below, so
// these are safe; they are explicit rather than memcpy-of-struct so a
// misaligned field cannot silently read garbage.
static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static LoadedElf load_elf(const char *path, uint32_t tcm_bytes) {
    std::vector<uint8_t> b = read_file(path);
    LoadedElf out;

    if (b.size() < sizeof(Elf32_Ehdr)) die("%s too small to be an ELF", path);
    if (memcmp(b.data(), ELFMAG, SELFMAG) != 0) die("%s is not an ELF", path);
    if (b[EI_CLASS] != ELFCLASS32)  die("%s is not ELF32", path);
    if (b[EI_DATA]  != ELFDATA2LSB) die("%s is not little-endian", path);

    const uint8_t *eh = b.data();
    uint16_t e_machine = rd16(eh + 18);
    if (e_machine != EM_RISCV) die("%s is not RISC-V (e_machine=%u)", path, e_machine);

    out.entry        = rd32(eh + 24);
    uint32_t e_phoff = rd32(eh + 28);
    uint32_t e_shoff = rd32(eh + 32);
    uint16_t e_phentsize = rd16(eh + 42);
    uint16_t e_phnum     = rd16(eh + 44);
    uint16_t e_shentsize = rd16(eh + 46);
    uint16_t e_shnum     = rd16(eh + 48);

    if (out.entry != 0)
        fprintf(stderr, "harness: WARNING: entry point is 0x%08x, not 0 "
                        "(RESET_VECTOR in rv32_pkg.sv is 0)\n", out.entry);

    // ---- PT_LOAD segments ----
    int loaded = 0;
    for (uint16_t i = 0; i < e_phnum; i++) {
        const uint8_t *ph = b.data() + e_phoff + (size_t)i * e_phentsize;
        if ((size_t)(e_phoff + (size_t)(i + 1) * e_phentsize) > b.size())
            die("program header %u runs past end of file", i);

        uint32_t p_type   = rd32(ph + 0);
        uint32_t p_offset = rd32(ph + 4);
        uint32_t p_paddr  = rd32(ph + 12);
        uint32_t p_filesz = rd32(ph + 16);
        uint32_t p_memsz  = rd32(ph + 20);
        if (p_type != PT_LOAD) continue;

        if (p_paddr % 4) die("segment %u paddr 0x%08x is not word-aligned", i, p_paddr);
        if ((size_t)p_offset + p_filesz > b.size())
            die("segment %u extends past end of file", i);
        if (p_paddr + p_memsz > tcm_bytes)
            die("segment %u ends at 0x%08x, past the %u-byte TCM. Raise TCM_BYTES, "
                "RAM_LENGTH in link.ld and DUT_RAM_SIZE in gen_act4_sail_config.py together.",
                i, p_paddr + p_memsz, tcm_bytes);

        // p_memsz > p_filesz is BSS: the TCM initial block pre-fills every
        // word with NOP (0x13), so trailing zero-fill must be written
        // explicitly rather than left to the default.
        for (uint32_t off = 0; off < p_memsz; off += 4) {
            uint32_t w = 0;
            if (off < p_filesz) {
                uint32_t remaining = p_filesz - off;
                const uint8_t *src = b.data() + p_offset + off;
                if (remaining >= 4) {
                    w = rd32(src);
                } else {  // tail shorter than a word: pad with zeros
                    for (uint32_t k = 0; k < remaining; k++) w |= (uint32_t)src[k] << (8 * k);
                }
            }
            out.words[(p_paddr + off) / 4] = w;
        }
        uint32_t top = p_paddr + p_memsz;
        if (top > out.top_byte) out.top_byte = top;
        loaded++;
    }
    if (loaded == 0) die("%s has no PT_LOAD segments", path);

    // ---- tohost, from the symbol table ----
    // Read from the symbol table rather than hardcoded: link.ld places .tohost
    // by section, and docs/results/0018 records a probe whose hardcoded
    // .org 0x1400 collided with .tohost at 0x1000. A symbol cannot drift with
    // the linker script.
    for (uint16_t i = 0; i < e_shnum && !out.have_tohost; i++) {
        const uint8_t *sh = b.data() + e_shoff + (size_t)i * e_shentsize;
        if ((size_t)(e_shoff + (size_t)(i + 1) * e_shentsize) > b.size())
            die("section header %u runs past end of file", i);
        if (rd32(sh + 4) != SHT_SYMTAB) continue;

        uint32_t sh_offset  = rd32(sh + 16);
        uint32_t sh_size    = rd32(sh + 20);
        uint32_t sh_link    = rd32(sh + 24);   // index of the string table
        uint32_t sh_entsize = rd32(sh + 36);
        if (sh_entsize == 0) die("symtab has zero entsize");

        const uint8_t *strsh = b.data() + e_shoff + (size_t)sh_link * e_shentsize;
        uint32_t str_offset = rd32(strsh + 16);
        uint32_t str_size   = rd32(strsh + 20);

        for (uint32_t o = 0; o + sh_entsize <= sh_size; o += sh_entsize) {
            const uint8_t *sym = b.data() + sh_offset + o;
            uint32_t st_name  = rd32(sym + 0);
            uint32_t st_value = rd32(sym + 4);
            if (st_name == 0 || st_name >= str_size) continue;
            const char *nm = (const char *)(b.data() + str_offset + st_name);
            if (strcmp(nm, "tohost") == 0) {
                out.tohost = st_value;
                out.have_tohost = true;
                break;
            }
        }
    }
    if (!out.have_tohost)
        die("%s has no 'tohost' symbol - is RVMODEL_DATA_SECTION defined?", path);
    if (out.tohost % 8)
        fprintf(stderr, "harness: WARNING: tohost 0x%08x is not 8-byte aligned\n", out.tohost);

    return out;
}

// Emit sparse hex for $readmemh.
//
// CRITICAL: tcm.sv declares `logic [31:0] mem [0:WORDS-1]`, so $readmemh
// indexes by WORD, not by byte. An @ directive is a word index. Emitting a
// byte address here would place every segment at four times its address and
// the tohost decode would never fire.
static void write_hex(const LoadedElf &e, const std::string &path) {
    FILE *f = fopen(path.c_str(), "w");
    if (!f) die("cannot write %s", path.c_str());
    uint32_t expect = 0xffffffffu;
    for (const auto &kv : e.words) {
        if (kv.first != expect) fprintf(f, "@%x\n", kv.first);
        fprintf(f, "%08x\n", kv.second);
        expect = kv.first + 1;
    }
    fclose(f);
}

// ---------------------------------------------------------------------------

int main(int argc, char **argv) {
    const char *elf_path  = nullptr;
    const char *dump_hex  = nullptr;
    long        max_cycles = 10000000;      // ACT4 tests are far longer than t01-t06
    uint32_t    tcm_bytes  = 1048576;       // must match TCM_BYTES / RAM_LENGTH / DUT_RAM_SIZE
    bool        force_fail = false;
    bool        verbose    = false;

    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--cycles")    && i + 1 < argc) max_cycles = atol(argv[++i]);
        else if (!strcmp(argv[i], "--tcm-bytes") && i + 1 < argc) tcm_bytes  = (uint32_t)strtoul(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--dump-hex")  && i + 1 < argc) dump_hex   = argv[++i];
        else if (!strcmp(argv[i], "--force-fail"))                force_fail = true;
        else if (!strcmp(argv[i], "--verbose"))                   verbose    = true;
        else if (argv[i][0] != '-')                               elf_path   = argv[i];
    }
    if (!elf_path) {
        fprintf(stderr, "usage: %s [--cycles N] [--tcm-bytes N] [--dump-hex F] "
                        "[--force-fail] [--verbose] <elf>\n", argv[0]);
        return 2;
    }

    LoadedElf e = load_elf(elf_path, tcm_bytes);

    std::string hex = dump_hex
        ? std::string(dump_hex)
        : "/tmp/rv32sky_act4_" + std::to_string((long)getpid()) + ".hex";
    write_hex(e, hex);

    if (verbose)
        printf("harness: %s  words=%zu  top=0x%08x  tohost=0x%08x  hex=%s\n",
               elf_path, e.words.size(), e.top_byte, e.tohost, hex.c_str());

    // tcm.sv reads the filename from a +HEX= plusarg in its initial block, so
    // commandArgs must be set BEFORE the DUT is constructed.
    std::string plusarg = "+HEX=" + hex;
    std::vector<const char *> vargs = { argv[0], plusarg.c_str() };
    Verilated::commandArgs((int)vargs.size(), vargs.data());

    Vcore_tb_top *dut = new Vcore_tb_top;
    dut->clk = 0;
    dut->rst_n = 0;
    dut->eval();

    const uint32_t TOHOST_LO = e.tohost;
    const uint32_t TOHOST_HI = e.tohost + 4;

    uint32_t htif_lo = 0;
    bool     done = false, pass = false;
    long     cycle = 0, retired = 0;

    for (; cycle < max_cycles && !done; cycle++) {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();

        if (cycle == 5) dut->rst_n = 1;
        if (cycle < 5)  continue;

        if (dut->trace_valid) retired++;

        // Gated on trace_valid as well as trace_mem_we. rv32_core.sv:603 drives
        // trace_mem_we from mem_wb_mem_we without gating it here; whether the
        // pipeline register itself qualifies it by valid is not visible at this
        // boundary. docs/results/0018 mutation A is a case where a valid-gate
        // turned out unreachable AND the recorded explanation for it was wrong,
        // so this gate is deliberately redundant rather than assumed away.
        if (dut->trace_valid && dut->trace_mem_we) {
            uint32_t a = (uint32_t)dut->trace_mem_addr;
            uint32_t d = (uint32_t)dut->trace_mem_wdata;

            if (a == TOHOST_LO) {
                htif_lo = d;
            } else if (a == TOHOST_HI) {
                if (d == 0) {
                    done = true;
                    pass = (htif_lo == 1);
                    if (!pass && htif_lo != 3)
                        printf("\nharness: unexpected tohost value 0x%08x "
                               "(1=pass, 3=fail)\n", htif_lo);
                } else {
                    // Console. Upper half carries device and command; the macro
                    // uses 0x01010000 = device 1 (terminal), cmd 1 (output).
                    putchar((char)(htif_lo & 0xff));
                    fflush(stdout);
                }
            }
        }
    }

    printf("\nharness: cycles=%ld retired=%ld\n", cycle, retired);

    if (!dump_hex) remove(hex.c_str());
    delete dut;

    if (!done) {
        // Distinct from FAIL on purpose: run_tests.py reports "exit code N, no
        // RVCP-SUMMARY" for abnormal termination, and conflating a hang with a
        // real failure would misattribute it.
        printf("harness: TIMEOUT after %ld cycles, no HTIF termination\n", max_cycles);
        return 1;
    }

    if (force_fail) {
        // Proves the checker can fail on data it should fail on. See the header.
        printf("harness: --force-fail set, inverting verdict (was %s)\n", pass ? "PASS" : "FAIL");
        pass = !pass;
    }

    printf("harness: %s (tohost=%u)\n", pass ? "PASS" : "FAIL", htif_lo);
    return pass ? 0 : 1;
}
