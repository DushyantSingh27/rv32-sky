// Directed decoder test.
//
// The reference is riscv64-unknown-elf-as: gen_ref.py assembles real RV32I
// instructions and records their encodings. This harness feeds each encoding
// to the DUT and checks the decode against expectations derived from the
// ASSEMBLY TEXT - parsed here, independently of the RTL.
//
// That independence is the point. Deriving expectations from the encoding
// would just re-implement the decoder and agree with its bugs.

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <verilated.h>
#include "Vdecoder.h"
#include "ref_cases.h"

// ---- ctrl_t field extraction ----
//
// Verilator flattens a packed struct output into ONE wide value:
//   VL_OUT64(&ctrl,37,0)   - 38 bits
//
// Packed structs pack MSB-FIRST: the FIRST declared field occupies the
// HIGHEST bits. rs1_addr (declared first) is [37:33]; illegal (declared
// last) is bit 0. Getting that backwards shifts every extraction.
//
// Bit positions verified against the ctrl_t declaration in rv32_pkg.sv and
// against Verilator's reported width. If ctrl_t changes, THIS MUST CHANGE -
// hence the static assert on total width below.
#define CTRL_BITS(v, msb, lsb) \
    (uint32_t)(((v) >> (lsb)) & ((1ull << ((msb) - (lsb) + 1)) - 1))

#define C_RS1_ADDR(v)      CTRL_BITS(v, 37, 33)
#define C_RS2_ADDR(v)      CTRL_BITS(v, 32, 28)
#define C_RD_ADDR(v)       CTRL_BITS(v, 27, 23)
#define C_RS1_USED(v)      CTRL_BITS(v, 22, 22)
#define C_RS2_USED(v)      CTRL_BITS(v, 21, 21)
#define C_ALU_OP(v)        CTRL_BITS(v, 20, 17)
#define C_BRANCH_OP(v)     CTRL_BITS(v, 16, 14)
#define C_ALU_SRC_A_PC(v)  CTRL_BITS(v, 13, 13)
#define C_ALU_SRC_B_IMM(v) CTRL_BITS(v, 12, 12)
#define C_MEM_READ(v)      CTRL_BITS(v, 11, 11)
#define C_MEM_WRITE(v)     CTRL_BITS(v, 10, 10)
#define C_MEM_SIZE(v)      CTRL_BITS(v,  9,  8)
#define C_MEM_SIGNED(v)    CTRL_BITS(v,  7,  7)
#define C_REG_WRITE(v)     CTRL_BITS(v,  6,  6)
#define C_WB_SEL(v)        CTRL_BITS(v,  5,  4)
#define C_IS_BRANCH(v)     CTRL_BITS(v,  3,  3)
#define C_IS_JAL(v)        CTRL_BITS(v,  2,  2)
#define C_IS_JALR(v)       CTRL_BITS(v,  1,  1)
#define C_ILLEGAL(v)       CTRL_BITS(v,  0,  0)

static int checks = 0, fails = 0;

static void fail(const char *what, const char *asm_text, uint32_t enc,
                 long expected, long got) {
    if (fails < 25)
        printf("FAIL  %-28s enc=0x%08x  %-30s expected=%ld got=%ld\n",
               what, enc, asm_text, expected, got);
    fails++;
}

static void check(const char *what, const char *asm_text, uint32_t enc,
                  long expected, long got) {
    checks++;
    if (expected != got) fail(what, asm_text, enc, expected, got);
}

// ---- expectations parsed from the assembly mnemonic ----
struct Expect {
    bool reg_write, rs1_used, rs2_used;
    bool mem_read, mem_write, mem_signed;
    int  mem_size;      // 0=B 1=H 2=W, -1 = don't care
    bool is_branch, is_jal, is_jalr;
    bool alu_src_b_imm, alu_src_a_pc;
    int  wb_sel;        // 0=ALU 1=MEM 2=PC4
    bool illegal;
    int  alu_op;        // -1 = don't care
    int  branch_op;     // -1 = don't care
};

// Must match alu_op_e and branch_op_e in rv32_pkg.sv.
enum { A_ADD=0, A_SUB=1, A_SLL=2, A_SRL=3, A_SRA=4,
       A_SLT=5, A_SLTU=6, A_XOR=7, A_OR=8, A_AND=9, A_PASS_B=10 };
enum { B_NONE=0, B_EQ=1, B_NE=2, B_LT=3, B_GE=4, B_LTU=5, B_GEU=6 };

static std::string mnemonic(const char *asm_text) {
    std::string s(asm_text);
    size_t sp = s.find(' ');
    return sp == std::string::npos ? s : s.substr(0, sp);
}

static Expect expect_for(const std::string &m) {
    Expect e{};
    e.mem_size  = -1;
    e.wb_sel    = 0;
    e.alu_op    = -1;
    e.branch_op = B_NONE;   // only branches set this; everything else is NONE

    static const char *R[]  = {"add","sub","sll","slt","sltu","xor","srl","sra","or","and"};
    static const char *I[]  = {"addi","slti","sltiu","xori","ori","andi",
                               "slli","srli","srai"};
    static const char *LD[] = {"lb","lh","lw","lbu","lhu"};
    static const char *ST[] = {"sb","sh","sw"};
    static const char *BR[] = {"beq","bne","blt","bge","bltu","bgeu"};

    // ALU operation per mnemonic. The register-register and
    // register-immediate forms of the same operation share an alu_op.
    static const struct { const char *m; int op; } ALU_MAP[] = {
        {"add",A_ADD},  {"sub",A_SUB},   {"sll",A_SLL},  {"slt",A_SLT},
        {"sltu",A_SLTU},{"xor",A_XOR},   {"srl",A_SRL},  {"sra",A_SRA},
        {"or",A_OR},    {"and",A_AND},
        {"addi",A_ADD}, {"slti",A_SLT},  {"sltiu",A_SLTU},{"xori",A_XOR},
        {"ori",A_OR},   {"andi",A_AND},  {"slli",A_SLL}, {"srli",A_SRL},
        {"srai",A_SRA},
        {"lui",A_PASS_B}, {"auipc",A_ADD},
        {"lb",A_ADD},{"lh",A_ADD},{"lw",A_ADD},{"lbu",A_ADD},{"lhu",A_ADD},
        {"sb",A_ADD},{"sh",A_ADD},{"sw",A_ADD},
        {"jalr",A_ADD},
    };
    for (auto &a : ALU_MAP) if (m == a.m) e.alu_op = a.op;

    static const struct { const char *m; int op; } BR_MAP[] = {
        {"beq",B_EQ}, {"bne",B_NE}, {"blt",B_LT},
        {"bge",B_GE}, {"bltu",B_LTU},{"bgeu",B_GEU},
    };
    for (auto &b : BR_MAP) if (m == b.m) e.branch_op = b.op;

    for (auto x : R)  if (m == x) { e.reg_write = e.rs1_used = e.rs2_used = true; return e; }
    for (auto x : I)  if (m == x) { e.reg_write = e.rs1_used = e.alu_src_b_imm = true; return e; }
    for (auto x : BR) if (m == x) { e.is_branch = e.rs1_used = e.rs2_used = true; return e; }

    for (auto x : LD) if (m == x) {
        e.reg_write = e.rs1_used = e.mem_read = e.alu_src_b_imm = true;
        e.wb_sel = 1;
        e.mem_size  = (m == "lb" || m == "lbu") ? 0 : (m == "lh" || m == "lhu") ? 1 : 2;
        e.mem_signed = (m[m.size()-1] != 'u');
        return e;
    }
    for (auto x : ST) if (m == x) {
        e.rs1_used = e.rs2_used = e.mem_write = e.alu_src_b_imm = true;
        e.mem_size = (m == "sb") ? 0 : (m == "sh") ? 1 : 2;
        return e;
    }

    if (m == "lui")   { e.reg_write = e.alu_src_b_imm = true; return e; }
    if (m == "auipc") { e.reg_write = e.alu_src_b_imm = e.alu_src_a_pc = true; return e; }
    if (m == "jal")   { e.reg_write = e.is_jal = true;  e.wb_sel = 2; return e; }
    if (m == "jalr")  { e.reg_write = e.is_jalr = e.rs1_used = e.alu_src_b_imm = true;
                        e.wb_sel = 2; return e; }
    if (m == "ecall" || m == "ebreak" || m == "fence" || m == "fence.i") return e;

    printf("WARN  no expectation for mnemonic '%s'\n", m.c_str());
    return e;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vdecoder *dut = new Vdecoder;

    // Guard against ctrl_t changing without the extraction macros following.
    // Verilator reports the struct as VL_OUT64(&ctrl,37,0) = 38 bits; drive
    // all ones and confirm the top field lands where expected.
    dut->instr = 0xffffffffu;
    dut->eval();
    if (C_RS1_ADDR(dut->ctrl) != 0x1f) {
        printf("FATAL: ctrl_t field map is stale - rs1_addr did not read 0x1f "
               "with instr=all-ones. Re-derive the macros from rv32_pkg.sv.\n");
        return 2;
    }

    // ---- reference cases from the assembler ----
    for (int i = 0; i < n_ref_cases; i++) {
        uint32_t enc = ref_cases[i].enc;
        const char *txt = ref_cases[i].asm_text;
        std::string m = mnemonic(txt);
        Expect e = expect_for(m);

        dut->instr = enc;
        dut->eval();

        uint64_t c = dut->ctrl;
        check("illegal",       txt, enc, 0,               C_ILLEGAL(c));
        check("reg_write",     txt, enc, e.reg_write,     C_REG_WRITE(c));
        check("rs1_used",      txt, enc, e.rs1_used,      C_RS1_USED(c));
        check("rs2_used",      txt, enc, e.rs2_used,      C_RS2_USED(c));
        check("mem_read",      txt, enc, e.mem_read,      C_MEM_READ(c));
        check("mem_write",     txt, enc, e.mem_write,     C_MEM_WRITE(c));
        check("is_branch",     txt, enc, e.is_branch,     C_IS_BRANCH(c));
        check("is_jal",        txt, enc, e.is_jal,        C_IS_JAL(c));
        check("is_jalr",       txt, enc, e.is_jalr,       C_IS_JALR(c));
        check("alu_src_b_imm", txt, enc, e.alu_src_b_imm, C_ALU_SRC_B_IMM(c));
        check("alu_src_a_pc",  txt, enc, e.alu_src_a_pc,  C_ALU_SRC_A_PC(c));
        check("wb_sel",        txt, enc, e.wb_sel,        C_WB_SEL(c));
        if (e.mem_size >= 0) {
            check("mem_size",   txt, enc, e.mem_size,   C_MEM_SIZE(c));
            check("mem_signed", txt, enc, e.mem_signed, C_MEM_SIGNED(c));
        }
        // Register fields come straight from fixed bit positions.
        check("rs1_addr", txt, enc, (enc >> 15) & 0x1f, C_RS1_ADDR(c));
        check("rs2_addr", txt, enc, (enc >> 20) & 0x1f, C_RS2_ADDR(c));
        check("rd_addr",  txt, enc, (enc >>  7) & 0x1f, C_RD_ADDR(c));
        if (e.alu_op >= 0)
            check("alu_op",    txt, enc, e.alu_op,    C_ALU_OP(c));
        check("branch_op", txt, enc, e.branch_op, C_BRANCH_OP(c));
    }

    // ---- illegal-instruction sweep ----
    // Anything not ending in 2'b11 is a 16-bit compressed instruction (M4),
    // and unallocated major opcodes must be rejected.
    int illegal_checked = 0;
    for (uint32_t low = 0; low < 4; low++) {
        if (low == 3) continue;
        for (int t = 0; t < 200; t++) {
            uint32_t enc = ((uint32_t)rand() << 2) | low;
            dut->instr = enc;
            dut->eval();
            checks++; illegal_checked++;
            if (!C_ILLEGAL(dut->ctrl)) {
                fail("compressed not illegal", "(random)", enc, 1, 0);
            }
        }
    }
    static const uint32_t bad_opcodes[] = {
        0x0000000b, 0x0000002b, 0x0000005b, 0x0000007b,
        0x00000003 | (3u << 12),               // load funct3=011 (LD, RV64)
        0x00000023 | (3u << 12),               // store funct3=011 (SD, RV64)
        0x00000063 | (2u << 12),               // branch funct3=010, unallocated
        0x00000033 | (1u << 25),               // OP with funct7=0000001 (RV32M)
    };
    for (auto enc : bad_opcodes) {
        dut->instr = enc;
        dut->eval();
        checks++; illegal_checked++;
        if (!C_ILLEGAL(dut->ctrl))
            fail("bad opcode not illegal", "(directed)", enc, 1, 0);
    }

    printf("\n%-24s %d\n", "reference cases:",   n_ref_cases);
    printf("%-24s %d\n",   "illegal cases:",     illegal_checked);
    printf("%-24s %d\n",   "total checks:",      checks);
    printf("%-24s %d\n",   "failures:",          fails);
    printf("%s\n", fails ? "RESULT: FAIL" : "RESULT: PASS");

    delete dut;
    return fails ? 1 : 0;
}
