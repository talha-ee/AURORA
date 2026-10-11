`timescale 1ns/1ps
`default_nettype none

module ee_bf16_dot2_pipe (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        clear_i,

    input  logic        in_valid_i,
    output logic        in_ready_o,

    // BF16 scalar0 = [15:0]
    // BF16 scalar1 = [31:16]
    input  logic [31:0] lhs_i,
    input  logic [31:0] rhs_i,

    output logic        out_valid_o,
    input  logic        out_ready_i,

    output logic [31:0] result_o
);

    // ============================================================
    // TWO PARALLEL BF16 -> FP32 MULTIPLIERS
    // ============================================================

    logic        m0_in_ready;
    logic        m1_in_ready;

    logic        m0_valid;
    logic        m1_valid;

    logic        m0_ready;
    logic        m1_ready;

    logic [31:0] m0_product;
    logic [31:0] m1_product;

    logic m0_invalid;
    logic m0_overflow;
    logic m0_underflow;
    logic m0_inexact;

    logic m1_invalid;
    logic m1_overflow;
    logic m1_underflow;
    logic m1_inexact;


    // Both multipliers must accept the same transaction.
    assign in_ready_o =
        m0_in_ready &&
        m1_in_ready;


    wire input_fire =
        in_valid_i &&
        in_ready_o;


    nce_bf16_mul_to_fp32_pipeline u_mul0 (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .clear_i     (clear_i),

        .in_valid_i  (input_fire),
        .in_ready_o  (m0_in_ready),

        .a_i         (lhs_i[15:0]),
        .b_i         (rhs_i[15:0]),

        .out_valid_o (m0_valid),
        .out_ready_i (m0_ready),

        .product_o   (m0_product),

        .invalid_o   (m0_invalid),
        .overflow_o  (m0_overflow),
        .underflow_o (m0_underflow),
        .inexact_o   (m0_inexact)
    );


    nce_bf16_mul_to_fp32_pipeline u_mul1 (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .clear_i     (clear_i),

        .in_valid_i  (input_fire),
        .in_ready_o  (m1_in_ready),

        .a_i         (lhs_i[31:16]),
        .b_i         (rhs_i[31:16]),

        .out_valid_o (m1_valid),
        .out_ready_i (m1_ready),

        .product_o   (m1_product),

        .invalid_o   (m1_invalid),
        .overflow_o  (m1_overflow),
        .underflow_o (m1_underflow),
        .inexact_o   (m1_inexact)
    );


    // ============================================================
    // FP32 PRODUCT SUM
    //
    // Products advance only as a matched pair.
    // ============================================================

    logic sum_in_ready;


    wire pair_valid =
        m0_valid &&
        m1_valid;


    assign m0_ready =
        sum_in_ready &&
        m1_valid;


    assign m1_ready =
        sum_in_ready &&
        m0_valid;


    logic sum_invalid;
    logic sum_overflow;
    logic sum_underflow;
    logic sum_inexact;

    logic [0:0] sum_meta;


    nce_fp32_product_sum_500mhz #(
        .META_W (1)
    ) u_product_sum (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .clear_i     (clear_i),

        .in_valid_i  (pair_valid),
        .in_ready_o  (sum_in_ready),

        .a_i         (m0_product),
        .b_i         (m1_product),
        .meta_i      (1'b0),

        .out_valid_o (out_valid_o),
        .out_ready_i (out_ready_i),

        .result_o    (result_o),

        .invalid_o   (sum_invalid),
        .overflow_o  (sum_overflow),
        .underflow_o (sum_underflow),
        .inexact_o   (sum_inexact),

        .meta_o      (sum_meta)
    );

endmodule

`default_nettype wire
