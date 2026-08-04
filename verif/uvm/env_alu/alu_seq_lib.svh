// ALU sequence library. Layered: a base sequence holds shared plumbing,
// specific sequences constrain it. No monolithic test-in-a-sequence.

class alu_base_seq extends uvm_sequence #(alu_seq_item);
  `uvm_object_utils(alu_base_seq)

  rand int unsigned n_items;
  constraint c_n_items { n_items inside {[1:100000]}; }

  function new(string name = "alu_base_seq");
    super.new(name);
    n_items = 200;
  endfunction

  // Hook for subclasses to constrain individual items.
  virtual function void tweak(alu_seq_item it);
  endfunction

  task body();
    alu_seq_item it;
    `uvm_info(get_type_name(), $sformatf("starting, n_items=%0d", n_items), UVM_LOW)
    repeat (n_items) begin
      it = alu_seq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize())
        `uvm_fatal(get_type_name(), "randomize() failed")
      tweak(it);
      finish_item(it);
    end
  endtask
endclass

// Full random across all operations - the workhorse.
class alu_random_seq extends alu_base_seq;
  `uvm_object_utils(alu_random_seq)
  function new(string name = "alu_random_seq");
    super.new(name);
  endfunction
endclass

// Shift-focused: forces the ALU into shift operations so cp_shamt and
// cp_b_ge_32 close quickly instead of waiting on chance.
class alu_shift_seq extends alu_base_seq;
  `uvm_object_utils(alu_shift_seq)

  function new(string name = "alu_shift_seq");
    super.new(name);
  endfunction

  task body();
    alu_seq_item it;
    `uvm_info(get_type_name(), $sformatf("starting, n_items=%0d", n_items), UVM_LOW)
    repeat (n_items) begin
      it = alu_seq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with {
            op inside {ALU_SLL, ALU_SRL, ALU_SRA};
            branch_op == BR_NONE;
            b_class inside {OPND_SMALL, OPND_RANDOM, OPND_ZERO, OPND_MINUS_ONE};
          })
        `uvm_fatal(get_type_name(), "randomize() failed")
      finish_item(it);
    end
  endtask
endclass

// Branch-focused: every transaction carries a real branch comparison.
class alu_branch_seq extends alu_base_seq;
  `uvm_object_utils(alu_branch_seq)

  function new(string name = "alu_branch_seq");
    super.new(name);
  endfunction

  task body();
    alu_seq_item it;
    `uvm_info(get_type_name(), $sformatf("starting, n_items=%0d", n_items), UVM_LOW)
    repeat (n_items) begin
      it = alu_seq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with {
            branch_op != BR_NONE;
            op inside {ALU_ADD, ALU_SUB, ALU_SLT, ALU_SLTU};
          })
        `uvm_fatal(get_type_name(), "randomize() failed")
      finish_item(it);
    end
  endtask
endclass

// Directed corner cases. Constrained-random will eventually reach most of
// these, but a directed pass makes failures reproducible and fast to debug.
class alu_corner_seq extends alu_base_seq;
  `uvm_object_utils(alu_corner_seq)

  function new(string name = "alu_corner_seq");
    super.new(name);
  endfunction

  task send(alu_op_e op, branch_op_e br, logic [XLEN-1:0] a, logic [XLEN-1:0] b);
    alu_seq_item it = alu_seq_item::type_id::create("it");
    start_item(it);
    it.op        = op;
    it.branch_op = br;
    it.a         = a;
    it.b         = b;
    it.a_class   = OPND_RANDOM;
    it.b_class   = OPND_RANDOM;
    finish_item(it);
  endtask

  task body();
    `uvm_info(get_type_name(), "directed corner cases", UVM_LOW)

    // Shift-amount truncation: RV32 uses b[4:0]. All three must equal a<<1.
    send(ALU_SLL, BR_NONE, 32'h0000_0001, 32'd1);
    send(ALU_SLL, BR_NONE, 32'h0000_0001, 32'd33);
    send(ALU_SLL, BR_NONE, 32'h0000_0001, 32'hFFFF_FFE1);

    // SRA must sign-extend where SRL must not.
    send(ALU_SRA, BR_NONE, 32'h8000_0000, 32'd31);
    send(ALU_SRL, BR_NONE, 32'h8000_0000, 32'd31);
    send(ALU_SRA, BR_NONE, 32'hFFFF_FFFF, 32'd1);

    // Signed vs unsigned: the classic confusion.
    send(ALU_SLT,  BR_NONE, 32'h8000_0000, 32'h0000_0001);
    send(ALU_SLTU, BR_NONE, 32'h8000_0000, 32'h0000_0001);
    send(ALU_SLT,  BR_NONE, 32'hFFFF_FFFF, 32'h0000_0000);
    send(ALU_SLTU, BR_NONE, 32'hFFFF_FFFF, 32'h0000_0000);

    // Overflow boundaries.
    send(ALU_ADD, BR_NONE, 32'h7FFF_FFFF, 32'h0000_0001);
    send(ALU_SUB, BR_NONE, 32'h8000_0000, 32'h0000_0001);
    send(ALU_SUB, BR_NONE, 32'h0000_0000, 32'h8000_0000);

    // Branch comparisons at the sign boundary.
    send(ALU_ADD, BR_LT,  32'h8000_0000, 32'h0000_0001);
    send(ALU_ADD, BR_LTU, 32'h8000_0000, 32'h0000_0001);
    send(ALU_ADD, BR_GE,  32'h8000_0000, 32'h0000_0001);
    send(ALU_ADD, BR_GEU, 32'h8000_0000, 32'h0000_0001);
    send(ALU_ADD, BR_EQ,  32'hDEAD_BEEF, 32'hDEAD_BEEF);
    send(ALU_ADD, BR_NE,  32'hDEAD_BEEF, 32'hDEAD_BEEF);
  endtask
endclass
