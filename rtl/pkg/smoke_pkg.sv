// M0 smoke design: package. Exercises typedef enum and packed struct.
package smoke_pkg;

  localparam int unsigned CNT_W = 8;

  typedef enum logic [1:0] {
    ST_IDLE  = 2'b00,
    ST_COUNT = 2'b01,
    ST_HOLD  = 2'b10
  } smoke_state_e;

  typedef struct packed {
    logic             valid;
    logic [CNT_W-1:0] value;
  } smoke_result_t;

endpackage
