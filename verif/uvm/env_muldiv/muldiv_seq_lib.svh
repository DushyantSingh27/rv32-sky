// muldiv sequence library. Layered: a base sequence holds shared plumbing,
// specific sequences constrain or react.

class md_base_seq extends uvm_sequence #(muldiv_seq_item);
  `uvm_object_utils(md_base_seq)

  rand int unsigned n_items;
  constraint c_n_items { n_items inside {[1:100000]}; }

  function new(string name = "md_base_seq");
    super.new(name);
    n_items = 200;
  endfunction

  task body();
    muldiv_seq_item it;
    `uvm_info(get_type_name(), $sformatf("starting, n_items=%0d", n_items), UVM_LOW)
    repeat (n_items) begin
      it = muldiv_seq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize())
        `uvm_fatal(get_type_name(), "randomize() failed")
      finish_item(it);
    end
  endtask
endclass

// Full random across all eight RV32M operations.
class md_random_seq extends md_base_seq;
  `uvm_object_utils(md_random_seq)
  function new(string name = "md_random_seq");
    super.new(name);
  endfunction
endclass

// Divide-focused. Weights the divisor toward zero so the spec-defined
// div-by-zero results get exercised without waiting on chance.
class md_div_seq extends md_base_seq;
  `uvm_object_utils(md_div_seq)

  function new(string name = "md_div_seq");
    super.new(name);
  endfunction

  task body();
    muldiv_seq_item it;
    `uvm_info(get_type_name(), $sformatf("starting, n_items=%0d", n_items), UVM_LOW)
    repeat (n_items) begin
      it = muldiv_seq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with {
            op inside {MD_DIV, MD_DIVU, MD_REM, MD_REMU};
            b_class dist { OPND_ZERO := 25, OPND_MINUS_ONE := 20,
                           OPND_ONE := 15, OPND_SMALL := 15,
                           OPND_RANDOM := 15, OPND_MIN_NEG := 5,
                           OPND_MAX_POS := 5 };
          })
        `uvm_fatal(get_type_name(), "randomize() failed")
      finish_item(it);
    end
  endtask
endclass

// Multiply-focused, weighted toward the sign boundaries where MULH and
// MULHSU differ from each other.
class md_mul_seq extends md_base_seq;
  `uvm_object_utils(md_mul_seq)

  function new(string name = "md_mul_seq");
    super.new(name);
  endfunction

  task body();
    muldiv_seq_item it;
    `uvm_info(get_type_name(), $sformatf("starting, n_items=%0d", n_items), UVM_LOW)
    repeat (n_items) begin
      it = muldiv_seq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with {
            op inside {MD_MUL, MD_MULH, MD_MULHSU, MD_MULHU};
            a_class dist { OPND_MIN_NEG := 20, OPND_MINUS_ONE := 20,
                           OPND_MAX_POS := 20, OPND_RANDOM := 30,
                           OPND_ZERO := 5, OPND_ONE := 5 };
            b_class dist { OPND_MIN_NEG := 20, OPND_MINUS_ONE := 20,
                           OPND_MAX_POS := 20, OPND_RANDOM := 30,
                           OPND_ZERO := 5, OPND_ONE := 5 };
          })
        `uvm_fatal(get_type_name(), "randomize() failed")
      finish_item(it);
    end
  endtask
endclass

// Heavy back-pressure. Every transaction stalls the result handshake.
// The default random rate of ~20% is too sparse to shake out a deadlock;
// this makes the MD_HOLD state the common case rather than the rare one.
class md_backpressure_seq extends md_base_seq;
  `uvm_object_utils(md_backpressure_seq)

  function new(string name = "md_backpressure_seq");
    super.new(name);
  endfunction

  task body();
    muldiv_seq_item it;
    `uvm_info(get_type_name(), $sformatf("starting, n_items=%0d", n_items), UVM_LOW)
    repeat (n_items) begin
      it = muldiv_seq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with { bp_cycles inside {[1:10]}; })
        `uvm_fatal(get_type_name(), "randomize() failed")
      finish_item(it);
    end
  endtask
endclass

// RESPONSE SEQUENCE - the skill target for env 2 (PROJECT_CONTEXT 5.2).
//
// Rather than firing transactions blindly, this sequence reads the completed
// item returned by the driver and chooses the next stimulus from it. Here:
// feed the previous result back as the next dividend, building an operand
// chain. That reaches value combinations pure randomization would not, and it
// is the mechanism every reactive bus sequence uses.
class md_chain_seq extends md_base_seq;
  `uvm_object_utils(md_chain_seq)

  function new(string name = "md_chain_seq");
    super.new(name);
    use_response_handler(0);
  endfunction

  task body();
    muldiv_seq_item it, rsp;
    logic [XLEN-1:0] carry = 32'h0000_0007;

    `uvm_info(get_type_name(), $sformatf("starting, n_items=%0d", n_items), UVM_LOW)

    repeat (n_items) begin
      it = muldiv_seq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with { a_class == OPND_RANDOM; })
        `uvm_fatal(get_type_name(), "randomize() failed")
      it.a = carry;                     // previous result becomes this dividend
      finish_item(it);

      get_response(rsp);
      // Guard against X as well as zero. An unknown carry would propagate
      // through every subsequent iteration and produce X operands into the
      // DUT - which is a testbench defect, not a DUT bug.
      if ($isunknown(rsp.result) || rsp.result == 32'd0)
        carry = 32'h0000_0007;
      else
        carry = rsp.result;
    end
  endtask
endclass

// Directed corner cases, straight from the RV32M specification tables.
class md_corner_seq extends md_base_seq;
  `uvm_object_utils(md_corner_seq)

  function new(string name = "md_corner_seq");
    super.new(name);
  endfunction

  task send(muldiv_op_e op, logic [XLEN-1:0] a, logic [XLEN-1:0] b);
    muldiv_seq_item it = muldiv_seq_item::type_id::create("it");
    start_item(it);
    it.op        = op;
    it.a         = a;
    it.b         = b;
    it.a_class   = OPND_RANDOM;
    it.b_class   = OPND_RANDOM;
    it.bp_cycles = 0;
    finish_item(it);
  endtask

  task body();
    `uvm_info(get_type_name(), "directed corner cases from the RV32M spec", UVM_LOW)

    // Divide by zero. RISC-V returns defined values; it does NOT trap.
    send(MD_DIV,  32'h0000_002A, 32'h0000_0000);   // -> 0xFFFFFFFF
    send(MD_DIVU, 32'h0000_002A, 32'h0000_0000);   // -> 0xFFFFFFFF
    send(MD_REM,  32'h0000_002A, 32'h0000_0000);   // -> dividend 0x2A
    send(MD_REMU, 32'h0000_002A, 32'h0000_0000);   // -> dividend 0x2A
    send(MD_DIV,  32'h8000_0000, 32'h0000_0000);
    send(MD_REM,  32'h8000_0000, 32'h0000_0000);

    // Signed division overflow: -2^31 / -1 does not fit in 32 bits.
    send(MD_DIV,  32'h8000_0000, 32'hFFFF_FFFF);   // -> 0x80000000
    send(MD_REM,  32'h8000_0000, 32'hFFFF_FFFF);   // -> 0
    send(MD_DIVU, 32'h8000_0000, 32'hFFFF_FFFF);   // unsigned: no overflow
    send(MD_REMU, 32'h8000_0000, 32'hFFFF_FFFF);

    // Remainder sign follows the DIVIDEND, not the quotient.
    send(MD_REM,  32'hFFFF_FFF9, 32'h0000_0002);   // -7 %  2 = -1
    send(MD_REM,  32'h0000_0007, 32'hFFFF_FFFE);   //  7 % -2 = +1
    send(MD_REM,  32'hFFFF_FFF9, 32'hFFFF_FFFE);   // -7 % -2 = -1
    send(MD_DIV,  32'hFFFF_FFF9, 32'h0000_0002);   // -7 /  2 = -3 (truncate)
    send(MD_DIV,  32'h0000_0007, 32'hFFFF_FFFE);   //  7 / -2 = -3

    // MULH family at the sign boundary - where the four variants diverge.
    send(MD_MUL,    32'hFFFF_FFFF, 32'hFFFF_FFFF);
    send(MD_MULH,   32'hFFFF_FFFF, 32'hFFFF_FFFF);   // -1 * -1, high = 0
    send(MD_MULHU,  32'hFFFF_FFFF, 32'hFFFF_FFFF);   // huge unsigned product
    send(MD_MULHSU, 32'hFFFF_FFFF, 32'hFFFF_FFFF);   // -1 signed x max unsigned
    send(MD_MULH,   32'h8000_0000, 32'h8000_0000);
    send(MD_MULHU,  32'h8000_0000, 32'h8000_0000);
    send(MD_MULHSU, 32'h8000_0000, 32'h8000_0000);
    send(MD_MULH,   32'h7FFF_FFFF, 32'h7FFF_FFFF);
    send(MD_MULHSU, 32'h8000_0000, 32'h0000_0001);
    send(MD_MULHSU, 32'h0000_0001, 32'h8000_0000);

    // Identities.
    send(MD_MUL,  32'h0000_0000, 32'hDEAD_BEEF);
    send(MD_MUL,  32'h0000_0001, 32'hDEAD_BEEF);
    send(MD_DIV,  32'hDEAD_BEEF, 32'h0000_0001);
    send(MD_DIVU, 32'hFFFF_FFFF, 32'hFFFF_FFFF);
  endtask
endclass
