# Authored SDC for standalone block hardening (M1).
#
# Replaces OpenROAD's generic fallback, which assumed 4.0 ns of external input
# delay - 20% of a 20 ns period - on every input port. That is appropriate for
# a chip-level I/O boundary and wrong for a block whose operands arrive from
# the register file or a forwarding mux on the same die.
#
# All values here are ESTIMATES for standalone characterisation, not signoff
# constraints. Recorded so results are comparable across blocks.

set clk_name  clk
set clk_port  [get_ports clk]
set clk_period $::env(CLOCK_PERIOD)

create_clock -name $clk_name -period $clk_period $clk_port

# Clock uncertainty: jitter plus CTS skew. 5% of period is a common
# pre-CTS estimate.
set_clock_uncertainty [expr $clk_period * 0.05] [get_clocks $clk_name]
set_clock_transition  0.15 [get_clocks $clk_name]

# Inputs arrive from an adjacent on-die block, not from a package pin.
# Budget 20% of the period for the upstream logic feeding us.
set input_ports [remove_from_collection [all_inputs] $clk_port]
set_input_delay  -clock $clk_name [expr $clk_period * 0.20] $input_ports

# Outputs feed adjacent on-die logic. Budget 20% for downstream setup.
set_output_delay -clock $clk_name [expr $clk_period * 0.20] [all_outputs]

# Driving cell and load: a mid-strength standard cell either side, which is
# what an adjacent block looks like.
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y $input_ports
set_load 0.05 [all_outputs]

# Reset is asynchronous and released synchronously; it is not a timed path.
if {[llength [get_ports -quiet rst_n]] > 0} {
  set_false_path -from [get_ports rst_n]
}
