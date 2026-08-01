// M0 smoke design: interface + modport.
// This is the construct most at risk of rejection by yosys-slang.
interface smoke_if;
  import smoke_pkg::*;

  logic          start;
  logic          stop;
  smoke_result_t result;

  modport dut (input start, input stop, output result);

endinterface
