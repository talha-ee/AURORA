`timescale 1ns/1ps
`default_nettype none

module ee_int4_mesh_2x2 (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         clear_i,

    // A rows:
    // [31:0]  = row 0
    // [63:32] = row 1
    input  logic [63:0]  a_west_i,
    input  logic [1:0]   a_valid_i,

    // B columns:
    // [31:0]  = column 0
    // [63:32] = column 1
    input  logic [63:0]  b_north_i,
    input  logic [1:0]   b_valid_i,

    // PE order:
    // bit/word 0 = PE00
    //          1 = PE01
    //          2 = PE10
    //          3 = PE11
    output logic [3:0]   acc_update_o,
    output logic [3:0]   acc_valid_o,

    output logic [127:0] acc_sum_o,
    output logic [127:0] acc_carry_o
);

    // ============================================================
    // Boundary skew
    //
    // A row r delayed by r cycles.
    // B column c delayed by c cycles.
    // ============================================================

    logic [31:0] a1_skew_q;
    logic        a1_valid_q;

    logic [31:0] b1_skew_q;
    logic        b1_valid_q;


    always_ff @(posedge clk_i) begin
        a1_skew_q <= a_west_i[63:32];
        b1_skew_q <= b_north_i[63:32];
    end


    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni) begin
            a1_valid_q <= 1'b0;
            b1_valid_q <= 1'b0;
        end

        else if (clear_i) begin
            a1_valid_q <= 1'b0;
            b1_valid_q <= 1'b0;
        end

        else begin
            a1_valid_q <= a_valid_i[1];
            b1_valid_q <= b_valid_i[1];
        end

    end


    // ============================================================
    // Registered neighbor links
    // ============================================================

    logic [31:0] a00_e;
    logic        av00_e;

    logic [31:0] b00_s;
    logic        bv00_s;

    logic [31:0] b01_s;
    logic        bv01_s;

    logic [31:0] a10_e;
    logic        av10_e;


    // ============================================================
    // PE 0,0
    // ============================================================

    ee_int4_mesh_pe u_pe00 (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .clear_i       (clear_i),

        .a_i           (a_west_i[31:0]),
        .a_valid_i     (a_valid_i[0]),

        .b_i           (b_north_i[31:0]),
        .b_valid_i     (b_valid_i[0]),

        .a_o           (a00_e),
        .a_valid_o     (av00_e),

        .b_o           (b00_s),
        .b_valid_o     (bv00_s),

        .acc_update_o  (acc_update_o[0]),
        .acc_valid_o   (acc_valid_o[0]),

        .acc_sum_o     (acc_sum_o[31:0]),
        .acc_carry_o   (acc_carry_o[31:0])
    );


    // ============================================================
    // PE 0,1
    // ============================================================

    ee_int4_mesh_pe u_pe01 (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .clear_i       (clear_i),

        .a_i           (a00_e),
        .a_valid_i     (av00_e),

        .b_i           (b1_skew_q),
        .b_valid_i     (b1_valid_q),

        .a_o           (),
        .a_valid_o     (),

        .b_o           (b01_s),
        .b_valid_o     (bv01_s),

        .acc_update_o  (acc_update_o[1]),
        .acc_valid_o   (acc_valid_o[1]),

        .acc_sum_o     (acc_sum_o[63:32]),
        .acc_carry_o   (acc_carry_o[63:32])
    );


    // ============================================================
    // PE 1,0
    // ============================================================

    ee_int4_mesh_pe u_pe10 (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .clear_i       (clear_i),

        .a_i           (a1_skew_q),
        .a_valid_i     (a1_valid_q),

        .b_i           (b00_s),
        .b_valid_i     (bv00_s),

        .a_o           (a10_e),
        .a_valid_o     (av10_e),

        .b_o           (),
        .b_valid_o     (),

        .acc_update_o  (acc_update_o[2]),
        .acc_valid_o   (acc_valid_o[2]),

        .acc_sum_o     (acc_sum_o[95:64]),
        .acc_carry_o   (acc_carry_o[95:64])
    );


    // ============================================================
    // PE 1,1
    // ============================================================

    ee_int4_mesh_pe u_pe11 (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .clear_i       (clear_i),

        .a_i           (a10_e),
        .a_valid_i     (av10_e),

        .b_i           (b01_s),
        .b_valid_i     (bv01_s),

        .a_o           (),
        .a_valid_o     (),

        .b_o           (),
        .b_valid_o     (),

        .acc_update_o  (acc_update_o[3]),
        .acc_valid_o   (acc_valid_o[3]),

        .acc_sum_o     (acc_sum_o[127:96]),
        .acc_carry_o   (acc_carry_o[127:96])
    );

endmodule

`default_nettype wire
