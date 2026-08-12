// Register file sequence library.

class rf_base_seq extends uvm_sequence #(regfile_seq_item);
  `uvm_object_utils(rf_base_seq)

  rand int unsigned n_items;
  constraint c_n_items { n_items inside {[1:100000]}; }

  function new(string name = "rf_base_seq");
    super.new(name);
    n_items = 200;
  endfunction

  task body();
    regfile_seq_item it;
    `uvm_info(get_type_name(), $sformatf("starting, n_items=%0d", n_items), UVM_LOW)
    repeat (n_items) begin
      it = regfile_seq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize())
        `uvm_fatal(get_type_name(), "randomize() failed")
      finish_item(it);
    end
  endtask
endclass

class rf_random_seq extends rf_base_seq;
  `uvm_object_utils(rf_random_seq)
  function new(string name = "rf_random_seq");
    super.new(name);
  endfunction
endclass

// Collision-focused: every transaction has at least one read port targeting
// the register being written. Pure randomization collides on roughly 1 in 16
// transactions per port, which is too sparse to close the collision crosses.
class rf_collision_seq extends rf_base_seq;
  `uvm_object_utils(rf_collision_seq)

  function new(string name = "rf_collision_seq");
    super.new(name);
  endfunction

  task body();
    regfile_seq_item it;
    `uvm_info(get_type_name(), $sformatf("starting, n_items=%0d", n_items), UVM_LOW)
    repeat (n_items) begin
      it = regfile_seq_item::type_id::create("it");
      start_item(it);
      if (!it.randomize() with {
            rd_we   == 1'b1;
            rd_addr != 5'd0;
            rs1_addr == rd_addr || rs2_addr == rd_addr;
          })
        `uvm_fatal(get_type_name(), "randomize() failed")
      finish_item(it);
    end
  endtask
endclass

// Sweeps every register address on all three ports so the per-register bins
// close without relying on chance.
class rf_sweep_seq extends rf_base_seq;
  `uvm_object_utils(rf_sweep_seq)

  function new(string name = "rf_sweep_seq");
    super.new(name);
  endfunction

  task send(logic [4:0] a1, logic [4:0] a2, logic [4:0] wa,
            logic [XLEN-1:0] wd, logic we);
    regfile_seq_item it = regfile_seq_item::type_id::create("it");
    start_item(it);
    it.rs1_addr = a1;
    it.rs2_addr = a2;
    it.rd_addr  = wa;
    it.rd_data  = wd;
    it.rd_we    = we;
    it.pattern  = PAT_RANDOM;
    it.walk_bit = 0;
    finish_item(it);
  endtask

  task body();
    `uvm_info(get_type_name(), "address sweep", UVM_LOW)
    // Write a unique recognisable value to every register.
    for (int i = 0; i < 32; i++)
      send(5'(i), 5'(31 - i), 5'(i), 32'hA5A5_0000 | i, 1'b1);
    // Read every register back on both ports without writing.
    for (int i = 0; i < 32; i++)
      send(5'(i), 5'(i), 5'd0, 32'd0, 1'b0);
  endtask
endclass

// Directed corner cases. These pin down behaviour that random stimulus would
// reach only slowly, and that a passing run could otherwise leave unverified.
class rf_corner_seq extends rf_base_seq;
  `uvm_object_utils(rf_corner_seq)

  function new(string name = "rf_corner_seq");
    super.new(name);
  endfunction

  task send(logic [4:0] a1, logic [4:0] a2, logic [4:0] wa,
            logic [XLEN-1:0] wd, logic we);
    regfile_seq_item it = regfile_seq_item::type_id::create("it");
    start_item(it);
    it.rs1_addr = a1;
    it.rs2_addr = a2;
    it.rd_addr  = wa;
    it.rd_data  = wd;
    it.rd_we    = we;
    it.pattern  = PAT_RANDOM;
    it.walk_bit = 0;
    finish_item(it);
  endtask

  task body();
    `uvm_info(get_type_name(), "directed corner cases", UVM_LOW)

    // ---- x0 WRITE-THEN-READ ----
    // The specific bug this targets: a register file that STORES to entry 0 and
    // masks it on read. Such a design passes any test that only reads x0
    // without having written it. Write a recognisable value to x0, then read
    // x0 on both ports in a later cycle - it must still be zero.
    send(5'd0, 5'd0, 5'd0, 32'hDEAD_BEEF, 1'b1);
    send(5'd0, 5'd0, 5'd0, 32'hFFFF_FFFF, 1'b1);
    send(5'd0, 5'd0, 5'd1, 32'd0,         1'b0);   // read x0 both ports
    send(5'd0, 5'd0, 5'd1, 32'd0,         1'b0);   // again, next cycle

    // ---- READ-DURING-WRITE, all four collision patterns ----
    send(5'd5, 5'd6, 5'd5, 32'h1111_1111, 1'b1);   // seed x5
    send(5'd5, 5'd6, 5'd5, 32'h2222_2222, 1'b1);   // rs1 == rd, expect 0x1111_1111
    send(5'd7, 5'd8, 5'd8, 32'h3333_3333, 1'b1);   // seed x8 via rs2 collision
    send(5'd7, 5'd8, 5'd8, 32'h4444_4444, 1'b1);   // rs2 == rd
    send(5'd9, 5'd9, 5'd9, 32'h5555_5555, 1'b1);   // rs1 == rs2 == rd, all three
    send(5'd9, 5'd9, 5'd9, 32'h6666_6666, 1'b1);   // again, must read the previous

    // ---- SAME REGISTER ON BOTH READ PORTS (add x1, x2, x2) ----
    send(5'd10, 5'd10, 5'd10, 32'h7777_7777, 1'b1);
    send(5'd10, 5'd10, 5'd0,  32'd0,         1'b0);

    // ---- WRITE ENABLE LOW MUST NOT WRITE ----
    send(5'd11, 5'd11, 5'd11, 32'h8888_8888, 1'b1);   // seed
    send(5'd11, 5'd11, 5'd11, 32'h9999_9999, 1'b0);   // we=0, must be ignored
    send(5'd11, 5'd11, 5'd0,  32'd0,         1'b0);   // still 0x8888_8888

    // ---- DATA PATTERNS ----
    send(5'd12, 5'd13, 5'd12, 32'h0000_0000, 1'b1);
    send(5'd12, 5'd13, 5'd13, 32'hFFFF_FFFF, 1'b1);
    send(5'd12, 5'd13, 5'd14, 32'h8000_0000, 1'b1);
    send(5'd14, 5'd15, 5'd15, 32'h0000_0001, 1'b1);
    send(5'd14, 5'd15, 5'd16, 32'hAAAA_AAAA, 1'b1);
    send(5'd16, 5'd17, 5'd17, 32'h5555_5555, 1'b1);

    // ---- x31 AND x1, the address extremes ----
    send(5'd31, 5'd1, 5'd31, 32'hCAFE_BABE, 1'b1);
    send(5'd31, 5'd1, 5'd1,  32'hBEEF_CAFE, 1'b1);
    send(5'd31, 5'd1, 5'd0,  32'd0,         1'b0);
  endtask
endclass
