// RV32 shared types and constants. Grown incrementally, one block at a time.
// A shared package inevitably contains members that any given importing
// module does not use - the ALU does not need the CSR addresses, the CSR block
// does not need the ALU opcodes. UNUSEDPARAM is suppressed package-wide for
// that reason. It is NOT suppressed in modules, where an unused parameter is a
// genuine smell.
/* verilator lint_off UNUSEDPARAM */
package rv32_pkg;

  localparam int unsigned XLEN = 32;

  // ALU operations. PASS_B is for LUI only - the JAL/JALR link value is PC+4,
  // which uses ALU_ADD.
  typedef enum logic [3:0] {
    ALU_ADD    = 4'd0,
    ALU_SUB    = 4'd1,
    ALU_SLL    = 4'd2,
    ALU_SRL    = 4'd3,
    ALU_SRA    = 4'd4,
    ALU_SLT    = 4'd5,
    ALU_SLTU   = 4'd6,
    ALU_XOR    = 4'd7,
    ALU_OR     = 4'd8,
    ALU_AND    = 4'd9,
    ALU_PASS_B = 4'd10
  } alu_op_e;

  // Branch comparison. BR_NONE means this is not a branch instruction.
  typedef enum logic [2:0] {
    BR_NONE = 3'd0,
    BR_EQ   = 3'd1,
    BR_NE   = 3'd2,
    BR_LT   = 3'd3,
    BR_GE   = 3'd4,
    BR_LTU  = 3'd5,
    BR_GEU  = 3'd6
  } branch_op_e;

  // RV32M operations.
  typedef enum logic [2:0] {
    MD_MUL    = 3'd0,   // low 32 bits of a * b
    MD_MULH   = 3'd1,   // high 32, signed   x signed
    MD_MULHSU = 3'd2,   // high 32, signed   x unsigned
    MD_MULHU  = 3'd3,   // high 32, unsigned x unsigned
    MD_DIV    = 3'd4,
    MD_DIVU   = 3'd5,
    MD_REM    = 3'd6,
    MD_REMU   = 3'd7
  } muldiv_op_e;

  // ------------------------------------------------------------------
  // Zicsr - CSR access operations.
  //
  // CSR_NONE covers the case where the instruction is not a CSR instruction.
  // The read/write SUPPRESSION rules (rd==x0 suppresses the read, rs1==x0 or
  // uimm==0 suppresses the write) are decoded in the pipeline and arrive as
  // separate csr_read / csr_write strobes, keeping this block free of
  // instruction-format knowledge.
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {
    CSR_NONE = 2'b00,
    CSR_RW   = 2'b01,   // CSRRW  / CSRRWI - write wdata
    CSR_RS   = 2'b10,   // CSRRS  / CSRRSI - set bits
    CSR_RC   = 2'b11    // CSRRC  / CSRRCI - clear bits
  } csr_op_e;

  // Machine-mode CSR addresses (RISC-V privileged spec, M-mode only).
  localparam logic [11:0] CSR_MSTATUS   = 12'h300;
  localparam logic [11:0] CSR_MISA      = 12'h301;
  localparam logic [11:0] CSR_MIE       = 12'h304;
  localparam logic [11:0] CSR_MTVEC     = 12'h305;
  localparam logic [11:0] CSR_MSTATUSH  = 12'h310;
  localparam logic [11:0] CSR_MSCRATCH  = 12'h340;
  localparam logic [11:0] CSR_MEPC      = 12'h341;
  localparam logic [11:0] CSR_MCAUSE    = 12'h342;
  localparam logic [11:0] CSR_MTVAL     = 12'h343;
  localparam logic [11:0] CSR_MIP       = 12'h344;
  localparam logic [11:0] CSR_MCYCLE    = 12'hB00;
  localparam logic [11:0] CSR_MINSTRET  = 12'hB02;
  localparam logic [11:0] CSR_MCYCLEH   = 12'hB80;
  localparam logic [11:0] CSR_MINSTRETH = 12'hB82;
  localparam logic [11:0] CSR_MVENDORID = 12'hF11;
  localparam logic [11:0] CSR_MARCHID   = 12'hF12;
  localparam logic [11:0] CSR_MIMPID    = 12'hF13;
  localparam logic [11:0] CSR_MHARTID   = 12'hF14;

  // mstatus bit positions
  localparam int MSTATUS_MIE_BIT  = 3;
  localparam int MSTATUS_MPIE_BIT = 7;
  localparam int MSTATUS_MPP_LSB  = 11;

  // mie / mip bit positions
  localparam int IRQ_SOFT_BIT = 3;
  localparam int IRQ_TIMER_BIT = 7;
  localparam int IRQ_EXT_BIT   = 11;

  // misa: MXL=1 (32-bit) in bits [31:30], extensions C, I, M in [25:0].
  // Extension letters map to bits 0..25 as A..Z: bit 2 = C, bit 8 = I,
  // bit 12 = M. Written as an explicit bit-position expression rather than a
  // hand-counted binary literal - the literal form had bit 6 (G) set and
  // bit 8 (I) clear, caught by uvm_reg_hw_reset_seq in env 4.
  localparam logic [XLEN-1:0] MISA_VALUE =
      {2'b01, 4'b0000, 26'd0}                   // MXL = 1 (RV32)
      | (32'd1 << 2)                            // C - compressed
      | (32'd1 << 8)                            // I - base integer
      | (32'd1 << 12);                          // M - mul/div


  // ------------------------------------------------------------------
  // RV32I instruction formats and decode.
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {
    FMT_R = 3'd0,
    FMT_I = 3'd1,
    FMT_S = 3'd2,
    FMT_B = 3'd3,
    FMT_U = 3'd4,
    FMT_J = 3'd5,
    FMT_NONE = 3'd7
  } instr_fmt_e;

  // Major opcodes (inst[6:0]). All RV32I opcodes end in 2'b11.
  localparam logic [6:0] OP_LOAD   = 7'b0000011;
  localparam logic [6:0] OP_OPIMM  = 7'b0010011;
  localparam logic [6:0] OP_AUIPC  = 7'b0010111;
  localparam logic [6:0] OP_STORE  = 7'b0100011;
  localparam logic [6:0] OP_OP     = 7'b0110011;
  localparam logic [6:0] OP_LUI    = 7'b0110111;
  localparam logic [6:0] OP_BRANCH = 7'b1100011;
  localparam logic [6:0] OP_JALR   = 7'b1100111;
  localparam logic [6:0] OP_JAL    = 7'b1101111;
  localparam logic [6:0] OP_SYSTEM = 7'b1110011;
  localparam logic [6:0] OP_MISCMEM = 7'b0001111;   // FENCE

  // Memory access size, encoded to match funct3[1:0] for loads and stores.
  localparam logic [1:0] MEM_B = 2'b00;
  localparam logic [1:0] MEM_H = 2'b01;
  localparam logic [1:0] MEM_W = 2'b10;

  // Writeback source select.
  localparam logic [1:0] WB_ALU  = 2'b00;
  localparam logic [1:0] WB_MEM  = 2'b01;
  localparam logic [1:0] WB_PC4  = 2'b10;   // JAL/JALR link value

  // Decoded control bundle. A packed struct rather than ~20 flat ports -
  // permitted by PROJECT_INSTRUCTIONS 4.2 and confirmed through yosys-slang
  // by the M0 smoke design.
  typedef struct packed {
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    logic [4:0]  rd_addr;
    // Whether the instruction ACTUALLY reads each source register. The hazard
    // unit at M3.3 needs this: forwarding must not trigger on a register the
    // instruction never reads. LUI has no rs1; branches have no rd.
    logic        rs1_used;
    logic        rs2_used;
    alu_op_e     alu_op;
    branch_op_e  branch_op;
    logic        alu_src_a_pc;    // PC instead of rs1  (AUIPC, JAL)
    logic        alu_src_b_imm;   // immediate instead of rs2
    logic        mem_read;
    logic        mem_write;
    logic [1:0]  mem_size;
    logic        mem_signed;      // LB/LH sign-extend vs LBU/LHU zero-extend
    logic        reg_write;
    logic [1:0]  wb_sel;
    logic        is_branch;
    logic        is_jal;
    logic        is_jalr;
    logic        illegal;
  } ctrl_t;


  // ------------------------------------------------------------------
  // Memory map (M3.2). Bit 31 distinguishes peripheral from memory, so the
  // test is a single bit rather than a range comparison - one gate instead of
  // a comparator, and the whole lower half stays free for real memory.
  // ------------------------------------------------------------------
  localparam int unsigned TCM_SIZE_BYTES = 8192;
  localparam int unsigned TCM_ADDR_BITS  = 13;        // 2^13 = 8192
  localparam logic [XLEN-1:0] TCM_BASE    = 32'h0000_0000;
  localparam logic [XLEN-1:0] RESET_VECTOR = 32'h0000_0000;

  // Test control. A store here ends the simulation: zero = PASS, anything
  // else = FAIL with that value as the error code.
  localparam logic [XLEN-1:0] ADDR_TESTCTL = 32'h8000_0000;
  localparam logic [XLEN-1:0] ADDR_CONSOLE = 32'h8000_0004;

  // ------------------------------------------------------------------
  // Pipeline registers. Structs rather than loose signals, following the
  // ctrl_t pattern already confirmed through yosys-slang by the M0 smoke
  // design.
  // ------------------------------------------------------------------
  typedef struct packed {
    logic            valid;
    logic [XLEN-1:0] pc;
    logic [31:0]     instr;
  } if_id_t;

  typedef struct packed {
    logic            valid;
    logic [XLEN-1:0] pc;
    ctrl_t           ctrl;
    logic [XLEN-1:0] imm;
    logic [XLEN-1:0] rs1_data;
    logic [XLEN-1:0] rs2_data;
  } id_ex_t;

  typedef struct packed {
    logic            valid;
    logic [XLEN-1:0] pc;
    ctrl_t           ctrl;
    logic [XLEN-1:0] alu_result;   // also the memory address for loads/stores
    logic [XLEN-1:0] rs2_data;     // store data
  } ex_mem_t;

  typedef struct packed {
    logic            valid;
    ctrl_t           ctrl;
    logic [XLEN-1:0] alu_result;
    logic [XLEN-1:0] mem_data;
    logic [XLEN-1:0] pc_plus4;
  } mem_wb_t;

endpackage
/* verilator lint_on UNUSEDPARAM */
