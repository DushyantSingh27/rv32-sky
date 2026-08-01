// M0 smoke design: FSM + counter driven through a modport.
module smoke_counter
  import smoke_pkg::*;
(
  input  logic clk,
  input  logic rst_n,
  smoke_if.dut bus
);

  smoke_state_e     state_q, state_d;
  logic [CNT_W-1:0] cnt_q,   cnt_d;

  always_comb begin
    state_d = state_q;
    cnt_d   = cnt_q;
    unique case (state_q)
      ST_IDLE: if (bus.start) begin
                 state_d = ST_COUNT;
                 cnt_d   = '0;
               end
      ST_COUNT: if (bus.stop) state_d = ST_HOLD;
                else          cnt_d   = cnt_q + 1'b1;
      ST_HOLD: if (bus.start) state_d = ST_IDLE;
      default:                state_d = ST_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      cnt_q   <= '0;
    end else begin
      state_q <= state_d;
      cnt_q   <= cnt_d;
    end
  end

  always_comb begin
    bus.result.valid = (state_q == ST_HOLD);
    bus.result.value = cnt_q;
  end

`ifndef SYNTHESIS
  // Immediate assertion only. No SVA in rtl/ - see PROJECT_INSTRUCTIONS 4.1.
  always_ff @(posedge clk) begin
    if (rst_n) assert (!$isunknown(state_q))
      else $error("smoke_counter: state_q is X");
  end
`endif

endmodule
