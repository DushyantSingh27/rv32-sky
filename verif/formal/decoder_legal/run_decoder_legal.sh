#!/usr/bin/env bash
# Decoder legality proof, its reachability covers, and four mutants.
#
#   prove   on the committed decoder           status must be PASS
#   cover   on the committed decoder           status must be PASS (all reached)
#   MA..MW  one legal instruction made to emit an out-of-range field, applied
#           to a SCRATCH COPY of decoder.sv - never the repo. Each prove must
#           be FAIL, failing on the assertion aimed at it and no other.
#
# Status meanings are the measured ones (verif/formal/controls, 2026-10-21):
# PASS 0 0 proved; FAIL 2 0 failed; ERROR 16 0 vacuous. ONLY "PASS" is a pass.
# OSS CAD Suite shell. Usage: run_decoder_legal.sh [workdir]
set -u -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
WORK="${1:-$HOME/scratch/formal_decoder_legal}"
RTL_FILES="rtl/pkg/rv32_pkg.sv rtl/core/decoder.sv"
die() { echo ">>> STOP: $*"; exit 1; }
ok()  { echo ">>> PASS  $*"; }

# The proof reads a SUBSET of the RTL. Each file must be one rtl/files.f
# lists, so this can never drift into proving a file the core does not use.
for f in $RTL_FILES; do
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$REPO/rtl/files.f" | grep -qxF "$f" \
    || die "$f is not in rtl/files.f"
done

stage() {   # $1 = job dir name; copies sources in fresh
  rm -rf "$WORK/$1"; mkdir -p "$WORK/$1"
  for f in $RTL_FILES; do cp "$REPO/$f" "$WORK/$1/"; done
  cp "$HERE"/decoder_legal.sv "$HERE"/decoder_legal_*.sby "$WORK/$1/"
}
run() {     # $1 = job dir, $2 = prove|cover -> ST (first word of status)
  ( cd "$WORK/$1" && sby "decoder_legal_$2.sby" ) > "$WORK/$1_$2.log" 2>&1
  cat "$WORK/$1_$2.log"
  ST="$(cat "$WORK/$1/decoder_legal_$2/status" 2>/dev/null || echo NONE)"
  echo "--- $1 $2: status '$ST'"
  ST="${ST%% *}"
}
line_of() { grep -n "// $1 " "$HERE/decoder_legal.sv" | cut -d: -f1; }

rm -rf "$WORK"; mkdir -p "$WORK"
echo "=== tools"; command -v sby yosys; yosys -V
git -C "$REPO" log --oneline -1

echo; echo "==================== COMMITTED DECODER"
stage base
run base prove; [ "$ST" = PASS ] && ok "legality proved for all 2^32 encodings" || die "prove: $ST"
run base cover; [ "$ST" = PASS ] && ok "all four legal extremes reachable"    || die "cover: $ST"

mutant() {  # $1 id, $2 target tag, $3 old, $4 new
  local id="$1" tag="$2"
  echo; echo "==================== MUTANT $id (target $tag)"
  stage "$id"
  python3 - "$WORK/$id/decoder.sv" "$3" "$4" <<'PY' || die "$id: mutation edit"
import sys
f, old, new = sys.argv[1:4]
s = open(f).read()
assert s.count(old) == 1, f"anchor occurs {s.count(old)} times"
open(f, "w").write(s.replace(old, new))
PY
  diff "$REPO/rtl/core/decoder.sv" "$WORK/$id/decoder.sv"
  run "$id" prove
  [ "$ST" = FAIL ] || die "$id SURVIVED: status $ST"
  local want; want="$(line_of "$tag")"
  [ -n "$want" ] || die "no $tag marker in decoder_legal.sv"
  grep -q "Assert failed in decoder_legal: decoder_legal.sv:$want\." "$WORK/${id}_prove.log" \
    || die "$id failed, but not on $tag (line $want)"
  local other
  for other in A_ALU A_BR A_SIZE A_WB; do
    [ "$other" = "$tag" ] && continue
    ! grep -q "Assert failed in decoder_legal: decoder_legal.sv:$(line_of "$other")\." "$WORK/${id}_prove.log" \
      || die "$id also failed $other: the mutant is not isolated"
  done
  ok "$id killed, on $tag (decoder_legal.sv:$want) only"
}
mutant MA A_ALU  "ctrl.alu_op        = ALU_PASS_B;" "ctrl.alu_op        = alu_op_e'(4'd11);"
mutant MB A_BR   "3'b111:  ctrl.branch_op = BR_GEU;" "3'b111:  ctrl.branch_op = branch_op_e'(3'd7);"
mutant MS A_SIZE "3'b101: begin ctrl.mem_size = MEM_H; ctrl.mem_signed = 1'b0; end  // LHU" \
                 "3'b101: begin ctrl.mem_size = 2'b11; ctrl.mem_signed = 1'b0; end  // LHU"
mutant MW A_WB   "ctrl.wb_sel    = WB_PC4;" "ctrl.wb_sel    = 2'b11;"

echo; echo "DECODER LEGALITY: proved, all extremes reachable, 4 of 4 mutants killed on their own assertion"
