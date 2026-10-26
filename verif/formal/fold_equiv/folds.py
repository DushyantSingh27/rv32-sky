#!/usr/bin/env python3
"""The twelve default-arm folds of docs/results/0028, defined ONCE.

Each fold removes one legal case arm and lets `default` carry its behaviour,
so every `default:` line in rtl/core is reachable (PROJECT_INSTRUCTIONS 4.2
still holds: every case keeps a default).

  class A  the case lists every value of its selector; default unreachable
  class B  default unreachable because of the enclosing arm
  class C  the default already did what one legal arm did
  class D  the default differed from every legal arm; the fold changes
           behaviour ONLY for encodings the decoder never emits
           (verif/formal/decoder_legal)

A, B and C are behaviour-preserving for ALL inputs; D for the decoded range.

Usage
  folds.py apply <repo>                 apply all folds to the repo, atomically
  folds.py build <src> <dst> <classes>  write each folded file, folds of the
                                        given classes only (e.g. ABC)
  folds.py mutate <file> <mutant>       apply one wrong-fold mutant in place
Every edit asserts its anchor occurs exactly once before anything is written.
"""
import os, sys

EDITS = [
  # ---- decoder.sv -------------------------------------------------------
  ("D90", "A", "rtl/core/decoder.sv",
"""          3'b111: ctrl.alu_op = ALU_AND;
          default: ctrl.illegal = 1'b1;
        endcase
        // funct7 must be 0000000, or 0100000 for SUB and SRA only.
""",
"""          // 3'b111 (AND) is the default arm: every funct3 value has an arm,
          // so a separate default was unreachable. docs/results/0028
          default: ctrl.alu_op = ALU_AND;
        endcase
        // funct7 must be 0000000, or 0100000 for SUB and SRA only.
"""),
  ("D119", "A", "rtl/core/decoder.sv",
"""          3'b101: begin                    // SRLI / SRAI
            ctrl.alu_op = arith_shift ? ALU_SRA : ALU_SRL;
            if (!shamt_valid) ctrl.illegal = 1'b1;
          end
          default: ctrl.illegal = 1'b1;
        endcase
""",
"""          // 3'b101 (SRLI / SRAI) is the default arm: every funct3 value has
          // an arm, so a separate default was unreachable. docs/results/0028
          default: begin
            ctrl.alu_op = arith_shift ? ALU_SRA : ALU_SRL;
            if (!shamt_valid) ctrl.illegal = 1'b1;
          end
        endcase
"""),
  ("D295", "B", "rtl/core/decoder.sv",
"""              2'b11:   ctrl.csr_op = CSR_RC;
              default: ctrl.csr_op = CSR_NONE;   // unreachable
""",
"""              // 2'b11 (CSRRC) is the default arm. funct3[1:0] == 2'b00 cannot
              // reach this case: funct3 000 and 100 take the arms above.
              // docs/results/0028
              default: ctrl.csr_op = CSR_RC;
"""),
  # ---- lsu.sv -----------------------------------------------------------
  ("L59", "C", "rtl/core/lsu.sv",
"""      MEM_W:   store_data_aligned = store_data;
      default: store_data_aligned = store_data;
""",
"""      default: store_data_aligned = store_data;      // MEM_W
"""),
  ("L71", "A", "rtl/core/lsu.sv",
"""      2'b11:   byte_sel = load_data_raw[31:24];
      default: byte_sel = load_data_raw[7:0];
""",
"""      default: byte_sel = load_data_raw[31:24];      // 2'b11: every offset has an arm
"""),
  ("L83", "C", "rtl/core/lsu.sv",
"""      MEM_W:   load_data = load_data_raw;
      default: load_data = load_data_raw;
""",
"""      default: load_data = load_data_raw;            // MEM_W
"""),
  ("L50", "D", "rtl/core/lsu.sv",
"""      MEM_W:   byte_en = 4'b1111;
      default: byte_en = 4'b0000;
""",
"""      // MEM_W is the default arm. size 2'b11 is never decoded
      // (verif/formal/decoder_legal); all three size cases in this module
      // treat it as a word. docs/results/0028
      default: byte_en = 4'b1111;
"""),
  # ---- alu.sv -----------------------------------------------------------
  ("A58", "C", "rtl/core/alu.sv",
"""      BR_NONE: branch_taken = 1'b0;
      BR_EQ:   branch_taken = eq;
""",
"""      BR_EQ:   branch_taken = eq;
"""),
  ("A58b", "C", "rtl/core/alu.sv",
"""      BR_GEU:  branch_taken = !lt_unsigned;
      default: branch_taken = 1'b0;
""",
"""      BR_GEU:  branch_taken = !lt_unsigned;
      // BR_NONE is the default arm: it already did what the default did.
      // docs/results/0028
      default: branch_taken = 1'b0;
"""),
  ("A45", "D", "rtl/core/alu.sv",
"""      ALU_PASS_B: result = b;
      default:    result = '0;
""",
"""      // ALU_PASS_B is the default arm. alu_op 11-15 is never decoded
      // (verif/formal/decoder_legal). docs/results/0028
      default:    result = b;
"""),
  # ---- regfile.sv -------------------------------------------------------
  ("R103", "A", "rtl/core/regfile.sv",
"""        2'd3:    stage1[g] = q3;
        default: stage1[g] = '0;
""",
"""        default: stage1[g] = q3;   // 2'd3: every value of addr[1:0] has an arm
"""),
  ("R115", "A", "rtl/core/regfile.sv",
"""      3'd7:    sel = stage1[7];
      default: sel = '0;
""",
"""      default: sel = stage1[7];  // 3'd7: every value of addr[4:2] has an arm
"""),
  # ---- rv32_core.sv -----------------------------------------------------
  ("W890", "C", "rtl/core/rv32_core.sv",
"""      WB_ALU:  wb_rd_data = mem_wb_q.alu_result;
      WB_MEM:  wb_rd_data = mem_wb_q.mem_data;
      WB_PC4:  wb_rd_data = mem_wb_q.pc_plus4;
      default: wb_rd_data = mem_wb_q.alu_result;
""",
"""      WB_MEM:  wb_rd_data = mem_wb_q.mem_data;
      WB_PC4:  wb_rd_data = mem_wb_q.pc_plus4;
      // WB_ALU is the default arm: it already did what the default did.
      // docs/results/0028
      default: wb_rd_data = mem_wb_q.alu_result;
"""),
]

# Wrong folds. Each must make its check FAIL. Anchors are in the FOLDED text.
MUTANTS = {
  "X_DEC":  ("rtl/core/decoder.sv", "          default: ctrl.alu_op = ALU_AND;\n",
                                    "          default: ctrl.alu_op = ALU_OR;\n"),
  "X_LSU":  ("rtl/core/lsu.sv", "default: byte_sel = load_data_raw[31:24];",
                                "default: byte_sel = load_data_raw[23:16];"),
  "X_ALU":  ("rtl/core/alu.sv", "      default: branch_taken = 1'b0;\n",
                                "      default: branch_taken = 1'b1;\n"),
  "X_RF":   ("rtl/core/regfile.sv", "default: stage1[g] = q3;", "default: stage1[g] = q2;"),
  "X_CORE": ("rtl/core/rv32_core.sv", "      default: wb_rd_data = mem_wb_q.alu_result;\n",
                                      "      default: wb_rd_data = mem_wb_q.mem_data;\n"),
  "X_ALUD": ("rtl/core/alu.sv", "      default:    result = b;\n", "      default:    result = a;\n"),
  "X_LSUD": ("rtl/core/lsu.sv", "      default: byte_en = 4'b1111;\n", "      default: byte_en = 4'b0011;\n"),
}

FILES = sorted({e[2] for e in EDITS})

def fold(text, path, classes):
    for eid, cls, f, old, new in EDITS:
        if f != path or cls not in classes:
            continue
        n = text.count(old)
        if n != 1:
            raise SystemExit(f"{eid}: anchor occurs {n} times in {path}")
        if new in text and new not in old:
            raise SystemExit(f"{eid}: replacement already present in {path}")
        text = text.replace(old, new)
    return text

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "apply":
        repo = sys.argv[2]
        out = {}
        for f in FILES:                       # check everything before writing
            out[f] = fold(open(os.path.join(repo, f)).read(), f, "ABCD")
        for f, t in out.items():
            open(os.path.join(repo, f), "w").write(t)
        print(f"applied {len(EDITS)} edits to {len(out)} files")
    elif cmd == "build":
        src, dst, classes = sys.argv[2:5]
        for f in FILES:
            t = fold(open(os.path.join(src, f)).read(), f, classes)
            os.makedirs(os.path.dirname(os.path.join(dst, f)), exist_ok=True)
            open(os.path.join(dst, f), "w").write(t)
    elif cmd == "mutate":
        path, mid = sys.argv[2:4]
        _, old, new = MUTANTS[mid]
        t = open(path).read()
        if t.count(old) != 1:
            raise SystemExit(f"{mid}: anchor occurs {t.count(old)} times in {path}")
        open(path, "w").write(t.replace(old, new))
    else:
        raise SystemExit(__doc__)

if __name__ == "__main__":
    main()
