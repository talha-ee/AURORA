`timescale 1ns/1ps
`default_nettype none

module ee_int8_mesh_4x4 (
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         clear_i,

    // Four A rows, one packed INT8 DOT4 token per row
    input  logic [127:0] a_west_i,
    input  logic [3:0]   a_valid_i,

    // Four B columns
    input  logic [127:0] b_north_i,
    input  logic [3:0]   b_valid_i,

    // Row-major PE order:
    // 00 01 02 03 10 ... 33
    output logic [15:0]  acc_update_o,
    output logic [15:0]  acc_valid_o,

    output logic [511:0] acc_sum_o,
    output logic [511:0] acc_carry_o
);

    // ============================================================
    // Boundary skew
    //
    // row r    delayed r cycles
    // column c delayed c cycles
    // ============================================================

    logic [31:0] a1_d1;

    logic [31:0] a2_d1;
    logic [31:0] a2_d2;

    logic [31:0] a3_d1;
    logic [31:0] a3_d2;
    logic [31:0] a3_d3;

    logic [31:0] b1_d1;

    logic [31:0] b2_d1;
    logic [31:0] b2_d2;

    logic [31:0] b3_d1;
    logic [31:0] b3_d2;
    logic [31:0] b3_d3;


    logic a1v_d1;

    logic a2v_d1;
    logic a2v_d2;

    logic a3v_d1;
    logic a3v_d2;
    logic a3v_d3;

    logic b1v_d1;

    logic b2v_d1;
    logic b2v_d2;

    logic b3v_d1;
    logic b3v_d2;
    logic b3v_d3;


    // Payload skew registers free-run.
    always_ff @(posedge clk_i) begin

        a1_d1 <= a_west_i[63:32];

        a2_d1 <= a_west_i[95:64];
        a2_d2 <= a2_d1;

        a3_d1 <= a_west_i[127:96];
        a3_d2 <= a3_d1;
        a3_d3 <= a3_d2;


        b1_d1 <= b_north_i[63:32];

        b2_d1 <= b_north_i[95:64];
        b2_d2 <= b2_d1;

        b3_d1 <= b_north_i[127:96];
        b3_d2 <= b3_d1;
        b3_d3 <= b3_d2;

    end


    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni) begin

            a1v_d1 <= 1'b0;

            a2v_d1 <= 1'b0;
            a2v_d2 <= 1'b0;

            a3v_d1 <= 1'b0;
            a3v_d2 <= 1'b0;
            a3v_d3 <= 1'b0;

            b1v_d1 <= 1'b0;

            b2v_d1 <= 1'b0;
            b2v_d2 <= 1'b0;

            b3v_d1 <= 1'b0;
            b3v_d2 <= 1'b0;
            b3v_d3 <= 1'b0;

        end

        else if (clear_i) begin

            a1v_d1 <= 1'b0;

            a2v_d1 <= 1'b0;
            a2v_d2 <= 1'b0;

            a3v_d1 <= 1'b0;
            a3v_d2 <= 1'b0;
            a3v_d3 <= 1'b0;

            b1v_d1 <= 1'b0;

            b2v_d1 <= 1'b0;
            b2v_d2 <= 1'b0;

            b3v_d1 <= 1'b0;
            b3v_d2 <= 1'b0;
            b3v_d3 <= 1'b0;

        end

        else begin

            a1v_d1 <= a_valid_i[1];

            a2v_d1 <= a_valid_i[2];
            a2v_d2 <= a2v_d1;

            a3v_d1 <= a_valid_i[3];
            a3v_d2 <= a3v_d1;
            a3v_d3 <= a3v_d2;


            b1v_d1 <= b_valid_i[1];

            b2v_d1 <= b_valid_i[2];
            b2v_d2 <= b2v_d1;

            b3v_d1 <= b_valid_i[3];
            b3v_d2 <= b3v_d1;
            b3v_d3 <= b3v_d2;

        end

    end


    // ============================================================
    // Boundary tokens
    // ============================================================

    wire [31:0] a_boundary [0:3];
    wire        av_boundary[0:3];

    wire [31:0] b_boundary [0:3];
    wire        bv_boundary[0:3];


    assign a_boundary[0]  = a_west_i[31:0];
    assign av_boundary[0] = a_valid_i[0];

    assign a_boundary[1]  = a1_d1;
    assign av_boundary[1] = a1v_d1;

    assign a_boundary[2]  = a2_d2;
    assign av_boundary[2] = a2v_d2;

    assign a_boundary[3]  = a3_d3;
    assign av_boundary[3] = a3v_d3;


    assign b_boundary[0]  = b_north_i[31:0];
    assign bv_boundary[0] = b_valid_i[0];

    assign b_boundary[1]  = b1_d1;
    assign bv_boundary[1] = b1v_d1;

    assign b_boundary[2]  = b2_d2;
    assign bv_boundary[2] = b2v_d2;

    assign b_boundary[3]  = b3_d3;
    assign bv_boundary[3] = b3v_d3;


    // ============================================================
    // Registered nearest-neighbor mesh links
    // ============================================================

    wire [31:0] a_link [0:3][0:4];
    wire        av_link[0:3][0:4];

    wire [31:0] b_link [0:4][0:3];
    wire        bv_link[0:4][0:3];


    genvar r;
    genvar c;


    generate

        for (r = 0; r < 4; r = r + 1) begin : GEN_A_BOUNDARY

            assign a_link[r][0]  = a_boundary[r];
            assign av_link[r][0] = av_boundary[r];

        end


        for (c = 0; c < 4; c = c + 1) begin : GEN_B_BOUNDARY

            assign b_link[0][c]  = b_boundary[c];
            assign bv_link[0][c] = bv_boundary[c];

        end


        for (r = 0; r < 4; r = r + 1) begin : GEN_ROW

            for (c = 0; c < 4; c = c + 1) begin : GEN_COL

                localparam integer IDX =
                    r*4 + c;

                ee_int8_mesh_pe u_pe (
                    .clk_i        (clk_i),
                    .rst_ni       (rst_ni),
                    .clear_i      (clear_i),

                    .a_i          (a_link[r][c]),
                    .a_valid_i    (av_link[r][c]),

                    .b_i          (b_link[r][c]),
                    .b_valid_i    (bv_link[r][c]),

                    .a_o          (a_link[r][c+1]),
                    .a_valid_o    (av_link[r][c+1]),

                    .b_o          (b_link[r+1][c]),
                    .b_valid_o    (bv_link[r+1][c]),

                    .acc_update_o (acc_update_o[IDX]),
                    .acc_valid_o  (acc_valid_o[IDX]),

                    .acc_sum_o (
                        acc_sum_o[
                            IDX*32 +: 32
                        ]
                    ),

                    .acc_carry_o (
                        acc_carry_o[
                            IDX*32 +: 32
                        ]
                    )
                );

            end

        end

    endgenerate


endmodule

`default_nettype wire
