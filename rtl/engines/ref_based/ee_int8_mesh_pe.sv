`timescale 1ns/1ps
`default_nettype none

module ee_int8_mesh_pe (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        clear_i,

    input  logic [31:0] a_i,
    input  logic        a_valid_i,

    input  logic [31:0] b_i,
    input  logic        b_valid_i,

    output logic [31:0] a_o,
    output logic        a_valid_o,

    output logic [31:0] b_o,
    output logic        b_valid_o,

    output logic        acc_update_o,
    output logic        acc_valid_o,
    output logic [31:0] acc_sum_o,
    output logic [31:0] acc_carry_o
);

    logic [31:0] a_q;
    logic [31:0] b_q;

    logic a_valid_q;
    logic b_valid_q;


    // ------------------------------------------------------------
    // Registered nearest-neighbor transport
    // ------------------------------------------------------------

    always_ff @(posedge clk_i) begin
        a_q <= a_i;
        b_q <= b_i;
    end


    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni) begin
            a_valid_q <= 1'b0;
            b_valid_q <= 1'b0;
        end

        else if (clear_i) begin
            a_valid_q <= 1'b0;
            b_valid_q <= 1'b0;
        end

        else begin
            a_valid_q <= a_valid_i;
            b_valid_q <= b_valid_i;
        end

    end


    assign a_o       = a_q;
    assign a_valid_o = a_valid_q;

    assign b_o       = b_q;
    assign b_valid_o = b_valid_q;


    // ------------------------------------------------------------
    // Local closed 500-MHz PE
    // ------------------------------------------------------------

    ee_int8_pe_csa u_compute (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .clear_i       (clear_i),

        .in_valid_i    (a_valid_q & b_valid_q),

        .lhs_i         (a_q),
        .rhs_i         (b_q),

        .acc_update_o  (acc_update_o),
        .acc_valid_o   (acc_valid_o),

        .acc_sum_o     (acc_sum_o),
        .acc_carry_o   (acc_carry_o)
    );

endmodule

`default_nettype wire
