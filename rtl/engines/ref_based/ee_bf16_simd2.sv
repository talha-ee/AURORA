`timescale 1ns/1ps
`default_nettype none

// Two independent DOT2 units; four BF16 products per cycle.
// Lane j occupies bits [32*j +: 32] of each data bus.
// Each DOT2 contains two BF16 scalars, low scalar first.
// Fixed-flow outputs: the downstream consumer must accept every valid result.
// Architectural accumulation remains outside this compute cluster.
module ee_bf16_simd2 (
    input  wire        clk_i,
    input  wire        rst_ni,
    input  wire        clear_i,

    input  wire [1:0]  in_valid_i,
    output wire [1:0]  in_ready_o,
    input  wire [63:0] lhs_i,
    input  wire [63:0] rhs_i,

    output wire [1:0]  out_valid_o,
    output wire [63:0] result_o
);
    genvar lane;
    generate
        for (lane = 0; lane < 2; lane = lane + 1) begin : GEN_DOT2
            ee_bf16_dot2_pipe u_dot2 (
                .clk_i       (clk_i),
                .rst_ni      (rst_ni),
                .clear_i     (clear_i),
                .in_valid_i  (in_valid_i[lane]),
                .in_ready_o  (in_ready_o[lane]),
                .lhs_i       (lhs_i[32*lane +: 32]),
                .rhs_i       (rhs_i[32*lane +: 32]),
                .out_valid_o (out_valid_o[lane]),
                .out_ready_i (1'b1),
                .result_o    (result_o[32*lane +: 32])
            );
        end
    endgenerate
endmodule

`default_nettype wire
