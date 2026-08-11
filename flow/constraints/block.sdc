# Authored SDC for standalone block hardening (M1).
#
# Replaces OpenROAD's generic fallback, which assumed 4.0 ns external input
# delay on every port - appropriate for a chip I/O boundary, wrong for a block
# fed by the register file or a forwarding mux on the same die.
#
# All values are ESTIMATES for standalone characterisation, not signoff
# constraints. Recorded so results are comparable across blocks.
#
# NOTE: this is OpenSTA, not Synopsys DC. Collection commands such as
# remove_from_collection do not exist here - filter with plain Tcl instead.

set clk_name   clk
set clk_port   [get_ports clk]
set clk_period $::env(CLOCK_PERIOD)

create_clock -name $clk_name -period $clk_period $clk_port

# 0.25 ns absolute, NOT a percentage of the period. CTS skew plus jitter is a
# fixed physical quantity on sky130; scaling it with the clock period is wrong.
# A previous revision used 5% (1.0 ns) and manufactured 28 extra
# register-to-register violations by itself.
set_clock_uncertainty 0.25 [get_clocks $clk_name]
set_clock_transition  0.15 [get_clocks $clk_name]

# Data inputs, excluding clock and reset by name.
set data_inputs {}
foreach port [get_ports *] {
  set pname [get_property $port name]
  if {$pname eq "clk" || $pname eq "rst_n"} { continue }
  if {[get_property $port direction] eq "input"} {
    lappend data_inputs $port
  }
}

# 10% of period. Operands arrive from an adjacent on-die block one short hop
# away. A previous revision used 20%, which is identical to OpenROAD's
# fallback - so it changed nothing on port paths.
if {[llength $data_inputs] > 0} {
  set_input_delay -clock $clk_name [expr $clk_period * 0.10] $data_inputs
  set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y $data_inputs
}

set_output_delay -clock $clk_name [expr $clk_period * 0.10] [all_outputs]

# 0.02 pF - roughly one standard-cell input plus short routing. 0.05 was heavy
# enough to produce max-cap violations that were a constraint artifact.
set_load 0.02 [all_outputs]

# Reset is asynchronous, released synchronously. Not a timed path.
if {[llength [get_ports -quiet rst_n]] > 0} {
  set_false_path -from [get_ports rst_n]
}
