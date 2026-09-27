// riscv-formal wrapper for RV32-SKY (M3.6).
//
// The module name and the clock/reset port names are FIXED by riscv-formal:
// genchecks.py instantiates `rvfi_wrapper` with ports named `clock` and
// `reset`. Renaming either breaks the generated checks, not this file.
//
// RESET POLARITY IS INVERTED HERE, deliberately. riscv-formal drives `reset`
// ACTIVE HIGH for the opening cycles of every trace; rv32_core takes `rst_n`,
// active low (PROJECT_INSTRUCTIONS 4.2). Connecting them directly would hold
// the core in reset for the entire bounded trace, and every check would then
// pass - vacuously, with nothing proved. This one character is the difference
// between a proof and a green tick.
//
// THE MEMORY INTERFACE IS UNCONSTRAINED, which is the point of the whole
// exercise. imem_rdata and dmem_rdata are `rvformal_rand_reg: the solver picks
// any 32-bit value, every cycle, with no memory model behind them. That is
// what makes a bounded proof a statement about the CORE rather than about one
// memory image - and it is the categorical difference from Sail lockstep and
// ACT4, both of which verify what their programs happen to execute.
//
// No memory model also means no TCM in the cone. rv32_core takes imem/dmem as
// PORTS - the TCM is instantiated in core_tb_top, parameterised by TCM_BYTES -
// so the solver never has to reason through 1 MB of array state. That was the
// open architectural question before the port list was read; it resolved in the
// convenient direction.
//
// There is no `stall` input to drive: stalls in this core are internal, from
// u_hazard, unlike nerv where the testbench drives stall from outside.

module rvfi_wrapper (
	input         clock,
	input         reset,
	`RVFI_OUTPUTS
);
	// ---- free inputs: the solver drives these ----
	(* keep *) `rvformal_rand_reg [31:0] imem_rdata;
	(* keep *) `rvformal_rand_reg [31:0] dmem_rdata;

	// ---- observed outputs ----
	//
	// (* keep *) on every one of them, including the four CSR observation
	// outputs that no check reads. Without it Yosys optimises away logic whose
	// only consumer is an unread port, and a counterexample trace then shows X
	// where the interesting signal should be. Keeping them costs nothing in a
	// bounded proof and makes cexdata readable when a check does fail.
	(* keep *) wire [31:0] imem_addr;

	(* keep *) wire [31:0] dmem_addr;
	(* keep *) wire        dmem_we;
	(* keep *) wire [ 3:0] dmem_be;
	(* keep *) wire [31:0] dmem_wdata;

	// Peripheral window at 0x8000_0000. Writes here are architecturally stores
	// like any other - rvfi_mem_* reports them, and this port pair exists only
	// because the TCM does not cover that address range.
	(* keep *) wire        periph_we;
	(* keep *) wire [31:0] periph_addr;
	(* keep *) wire [31:0] periph_wdata;

	// Detected-but-unconsumed conditions, routed to the boundary by the core's
	// own convention rather than suppressed.
	(* keep *) wire        mem_misaligned_o;
	(* keep *) wire        csr_illegal_o;
	(* keep *) wire [31:0] mtvec_o;
	(* keep *) wire [31:0] mepc_o;
	(* keep *) wire        irq_pending_o;

	rv32_core uut (
		.clk              (clock           ),
		.rst_n            (!reset          ),

		.imem_addr        (imem_addr       ),
		.imem_rdata       (imem_rdata      ),

		.dmem_addr        (dmem_addr       ),
		.dmem_we          (dmem_we         ),
		.dmem_be          (dmem_be         ),
		.dmem_wdata       (dmem_wdata      ),
		.dmem_rdata       (dmem_rdata      ),

		.periph_we        (periph_we       ),
		.periph_addr      (periph_addr     ),
		.periph_wdata     (periph_wdata    ),

		.mem_misaligned_o (mem_misaligned_o),
		.csr_illegal_o    (csr_illegal_o   ),
		.mtvec_o          (mtvec_o         ),
		.mepc_o           (mepc_o          ),
		.irq_pending_o    (irq_pending_o   ),

		// The trace ports under `ifndef SYNTHESIS are NOT connected here.
		// checks.cfg defines SYNTHESIS so they do not exist in this build -
		// they are simulation observation points, and carrying them into the
		// formal cone would add flops the solver must reason about for no
		// return. If a build error names trace_valid, SYNTHESIS is missing
		// from checks.cfg [defines].
		`RVFI_CONN32
	);
endmodule
