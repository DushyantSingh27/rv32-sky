// Register file environment: reference model, scoreboard, coverage, env.
package regfile_env_pkg;

  import uvm_pkg::*;
  import rv32_pkg::*;
  import regfile_agent_pkg::*;
  `include "uvm_macros.svh"

  // ==================================================================
  // SCOREBOARD
  //
  // The reference model is a 32-entry array mirroring the DUT's storage.
  // Written from the RISC-V spec and this project's recorded design decisions,
  // not derived from regfile.sv:
  //
  //   x0 reads as zero and discards writes (RISC-V mandate)
  //   READ-FIRST on collision: a read colliding with a write to the same
  //     address returns the PRE-WRITE value (this project's choice - see
  //     docs/results/0007). This is the assumption M3's forwarding logic will
  //     be built on, so it must be verified explicitly rather than assumed.
  //   All registers reset to zero (this project's choice)
  //
  // Order matters in write(): predict the reads from the CURRENT model state,
  // THEN apply the write. Doing it the other way round would silently encode
  // write-first behaviour and the scoreboard would agree with the wrong design.
  // ==================================================================
  class regfile_scoreboard extends uvm_subscriber #(regfile_seq_item);
    `uvm_component_utils(regfile_scoreboard)

    logic [XLEN-1:0] model [0:31];

    int unsigned n_checked;
    int unsigned n_mismatch;
    int unsigned n_collisions;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      foreach (model[i]) model[i] = '0;
    endfunction

    function void write(regfile_seq_item t);
      logic [XLEN-1:0] exp_rs1, exp_rs2;

      // Predict reads from state BEFORE the write.
      exp_rs1 = (t.rs1_addr == 5'd0) ? '0 : model[t.rs1_addr];
      exp_rs2 = (t.rs2_addr == 5'd0) ? '0 : model[t.rs2_addr];

      n_checked++;
      if (t.rd_we && t.rd_addr != 5'd0 &&
          (t.rs1_addr == t.rd_addr || t.rs2_addr == t.rd_addr))
        n_collisions++;

      if (t.rs1_data !== exp_rs1) begin
        n_mismatch++;
        `uvm_error("RF_SCB",
          $sformatf("rs1 MISMATCH addr=x%0d expected 0x%08h got 0x%08h%s",
                    t.rs1_addr, exp_rs1, t.rs1_data,
                    (t.rd_we && t.rs1_addr == t.rd_addr) ?
                      $sformatf(" [COLLISION with write of 0x%08h]", t.rd_data) : ""))
      end

      if (t.rs2_data !== exp_rs2) begin
        n_mismatch++;
        `uvm_error("RF_SCB",
          $sformatf("rs2 MISMATCH addr=x%0d expected 0x%08h got 0x%08h%s",
                    t.rs2_addr, exp_rs2, t.rs2_data,
                    (t.rd_we && t.rs2_addr == t.rd_addr) ?
                      $sformatf(" [COLLISION with write of 0x%08h]", t.rd_data) : ""))
      end

      // Now apply the write. x0 discards.
      if (t.rd_we && t.rd_addr != 5'd0)
        model[t.rd_addr] = t.rd_data;
    endfunction

    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      `uvm_info("RF_SCB",
        $sformatf("checked %0d transactions, %0d mismatches, %0d read/write collisions",
                  n_checked, n_mismatch, n_collisions), UVM_LOW)
      if (n_checked == 0)
        `uvm_error("RF_SCB", "scoreboard saw zero transactions - testbench not connected")
      if (n_collisions == 0)
        `uvm_error("RF_SCB",
          "ZERO read/write collisions observed - read-first behaviour is UNVERIFIED")
    endfunction
  endclass

  // ==================================================================
  // COVERAGE COLLECTOR
  // ==================================================================
  class regfile_coverage extends uvm_subscriber #(regfile_seq_item);
    `uvm_component_utils(regfile_coverage)

    logic [4:0]      cg_rs1, cg_rs2, cg_rd;
    logic            cg_we;
    logic [XLEN-1:0] cg_wdata;
    bit              cg_c1, cg_c2, cg_same_read;

    covergroup cg_rf;
      option.per_instance = 1;

      // Every register on every port. x0 gets its own bin because it is
      // architecturally special, not just another address.
      cp_rs1: coverpoint cg_rs1 {
        bins x0      = {0};
        bins regs[]  = {[1:31]};
      }
      cp_rs2: coverpoint cg_rs2 {
        bins x0      = {0};
        bins regs[]  = {[1:31]};
      }
      cp_rd: coverpoint cg_rd {
        bins x0      = {0};
        bins regs[]  = {[1:31]};
      }

      cp_we: coverpoint cg_we { bins disabled = {0}; bins enabled = {1}; }

      // THE COLLISION CASES. Read-first is a design CHOICE - a testbench that
      // never collides passes against either behaviour, and M3's forwarding
      // logic would then rest on an unverified assumption.
      cp_rs1_collides: coverpoint cg_c1 { bins no = {0}; bins yes = {1}; }
      cp_rs2_collides: coverpoint cg_c2 { bins no = {0}; bins yes = {1}; }

      // Both read ports hitting the register being written, simultaneously.
      x_both_collide: cross cp_rs1_collides, cp_rs2_collides;

      // add x1, x2, x2 - both read ports on the same register.
      cp_same_read: coverpoint cg_same_read { bins no = {0}; bins yes = {1}; }

      // x0 as a write target with write enable asserted: the case that catches
      // a register file which stores to entry 0 and masks it on read.
      cp_write_x0: coverpoint (cg_rd == 5'd0 && cg_we) {
        bins no  = {0};
        bins yes = {1};
      }

      cp_wdata: coverpoint cg_wdata {
        bins zero     = {32'h0000_0000};
        bins ones     = {32'hFFFF_FFFF};
        bins alt_a    = {32'hAAAA_AAAA};
        bins alt_5    = {32'h5555_5555};
        bins msb_only = {32'h8000_0000};
        bins lsb_only = {32'h0000_0001};
        bins other    = default;
      }

      x_rd_we: cross cp_rd, cp_we;
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      cg_rf = new();
    endfunction

    function void write(regfile_seq_item t);
      cg_rs1       = t.rs1_addr;
      cg_rs2       = t.rs2_addr;
      cg_rd        = t.rd_addr;
      cg_we        = t.rd_we;
      cg_wdata     = t.rd_data;
      cg_c1        = t.rd_we && (t.rd_addr != 5'd0) && (t.rs1_addr == t.rd_addr);
      cg_c2        = t.rd_we && (t.rd_addr != 5'd0) && (t.rs2_addr == t.rd_addr);
      cg_same_read = (t.rs1_addr == t.rs2_addr);
      cg_rf.sample();
    endfunction

    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      `uvm_info("RF_COV",
        $sformatf("functional coverage = %0.2f%%", cg_rf.get_inst_coverage()), UVM_LOW)
    endfunction
  endclass

  // ==================================================================
  // ENVIRONMENT
  // ==================================================================
  class regfile_env_cfg extends uvm_object;
    `uvm_object_utils(regfile_env_cfg)
    regfile_agent_cfg agent_cfg;

    function new(string name = "regfile_env_cfg");
      super.new(name);
    endfunction
  endclass

  class regfile_env extends uvm_env;
    `uvm_component_utils(regfile_env)

    regfile_env_cfg    cfg;
    regfile_agent      agent;
    regfile_scoreboard scb;
    regfile_coverage   cov;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(regfile_env_cfg)::get(this, "", "cfg", cfg))
        `uvm_fatal("RF_ENV", "regfile_env_cfg not found in config db")
      uvm_config_db#(regfile_agent_cfg)::set(this, "agent", "cfg", cfg.agent_cfg);

      agent = regfile_agent::type_id::create("agent", this);
      scb   = regfile_scoreboard::type_id::create("scb", this);
      cov   = regfile_coverage::type_id::create("cov", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agent.ap.connect(scb.analysis_export);
      agent.ap.connect(cov.analysis_export);
    endfunction
  endclass

endpackage
