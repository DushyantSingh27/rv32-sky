// Load/store unit.
//
// Turns a byte address plus a size into byte enables and shifted data, and
// extends load results. Three things it must get right:
//
//   1. Byte enables depend on the low address bits. A byte store to 0x...3
//      writes byte lane 3, not lane 0.
//   2. Store data must be SHIFTED into the right lane. sb of 0xAB to address
//      0x...2 puts 0xAB in bits [23:16], not [7:0].
//   3. Load results must be shifted DOWN then extended - signed for LB/LH,
//      zero for LBU/LHU. This is the RV32I detail most often wrong.
//
// Misaligned accesses raise no exception in M3.2; trap generation is M4. The
// misaligned flag is produced here and left unconsumed, the same approach the
// decoder takes with `illegal`.
// Takes addr[1:0] only, NOT the full address. Bits [31:2] are the word
// address and belong to the memory; only the byte offset within a word affects
// lane selection and extension. Narrowing the port means this module can never
// grow address-decode logic that duplicates what the memory already does.
// Same reasoning as imm_gen taking instr[31:7].
module lsu
  import rv32_pkg::*;
(
  input  logic [1:0]      addr,        // byte offset within the word
  input  logic [1:0]      size,        // MEM_B / MEM_H / MEM_W
  input  logic            is_signed,
  input  logic [XLEN-1:0] store_data,

  output logic [3:0]      byte_en,
  output logic [XLEN-1:0] store_data_aligned,

  input  logic [XLEN-1:0] load_data_raw,
  output logic [XLEN-1:0] load_data,

  output logic            misaligned
);

  logic [1:0] offset;
  always_comb offset = addr;

  // Shared with the EX-stage trap encoder via rv32_pkg. See the function's
  // comment for why this is not a local case statement.
  always_comb misaligned = is_misaligned(offset, size);

  always_comb begin
    unique case (size)
      MEM_B:   byte_en = 4'b0001 << offset;
      MEM_H:   byte_en = offset[1] ? 4'b1100 : 4'b0011;
      MEM_W:   byte_en = 4'b1111;
      default: byte_en = 4'b0000;
    endcase
  end

  always_comb begin
    unique case (size)
      MEM_B:   store_data_aligned = {4{store_data[7:0]}};
      MEM_H:   store_data_aligned = {2{store_data[15:0]}};
      MEM_W:   store_data_aligned = store_data;
      default: store_data_aligned = store_data;
    endcase
  end

  logic [7:0]  byte_sel;
  logic [15:0] half_sel;
  always_comb begin
    unique case (offset)
      2'b00:   byte_sel = load_data_raw[7:0];
      2'b01:   byte_sel = load_data_raw[15:8];
      2'b10:   byte_sel = load_data_raw[23:16];
      2'b11:   byte_sel = load_data_raw[31:24];
      default: byte_sel = load_data_raw[7:0];
    endcase
    half_sel = offset[1] ? load_data_raw[31:16] : load_data_raw[15:0];
  end

  always_comb begin
    unique case (size)
      MEM_B:   load_data = is_signed ? {{24{byte_sel[7]}},  byte_sel}
                                     : {24'b0,             byte_sel};
      MEM_H:   load_data = is_signed ? {{16{half_sel[15]}}, half_sel}
                                     : {16'b0,             half_sel};
      MEM_W:   load_data = load_data_raw;
      default: load_data = load_data_raw;
    endcase
  end

endmodule
