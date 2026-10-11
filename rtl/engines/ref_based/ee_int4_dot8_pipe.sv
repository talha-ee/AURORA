`timescale 1ns/1ps
`default_nettype none

// Eight signed INT4 products from two packed 32-bit inputs.
// Nibble 0 occupies bits [3:0].
// Free-running payload registers; clear flushes validity.
// Fixed-flow output, matching the BF16 compute interface.
module ee_int4_dot8_pipe (
    input  wire               clk_i,
    input  wire               rst_ni,
    input  wire               clear_i,
    input  wire               in_valid_i,
    output wire               in_ready_o,
    input  wire [31:0]        lhs_i,
    input  wire [31:0]        rhs_i,
    output wire               out_valid_o,
    input  wire               out_ready_i,
    output reg signed [31:0]  result_o
);
    reg signed [3:0] a_q [0:7];
    reg signed [3:0] b_q [0:7];
    wire signed [7:0] product_c [0:7];
    reg signed [7:0] product_q [0:7];
    reg signed [8:0] pair_q [0:3];
    reg signed [9:0] quad_q [0:1];
    reg [8:0] valid_q;

    assign in_ready_o = rst_ni && !clear_i;
    assign out_valid_o = valid_q[8];

    genvar lane;
    generate
        for (lane = 0; lane < 8; lane = lane + 1) begin : GEN_MUL
            ee_int4_multiplier_las_rows_pipe u_mul (
                .clk_i(clk_i),
                .a(a_q[lane]),
                .b(b_q[lane]),
                .p(product_c[lane])
            );
        end
    endgenerate

    wire [11:0] pair_c [0:3];
    wire [11:0] quad_c [0:1];
    wire [11:0] dot_c;

    genvar pg, qg;
    generate
        for (pg = 0; pg < 4; pg = pg + 1) begin : GEN_PAIR_CS3
            ee_int4_add12_cs3_stage u_add (
                .clk_i(clk_i), .rst_ni(rst_ni),
                .a_i({{4{product_q[2*pg][7]}}, product_q[2*pg]}),
                .b_i({{4{product_q[2*pg+1][7]}}, product_q[2*pg+1]}),
                .sum_o(pair_c[pg])
            );
        end
        for (qg = 0; qg < 2; qg = qg + 1) begin : GEN_QUAD_CS3
            ee_int4_add12_cs3_stage u_add (
                .clk_i(clk_i), .rst_ni(rst_ni),
                .a_i({{3{pair_q[2*qg][8]}}, pair_q[2*qg]}),
                .b_i({{3{pair_q[2*qg+1][8]}}, pair_q[2*qg+1]}),
                .sum_o(quad_c[qg])
            );
        end
    endgenerate

    ee_int4_add12_cs3_stage u_final_add (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .a_i({{2{quad_q[0][9]}}, quad_q[0]}),
        .b_i({{2{quad_q[1][9]}}, quad_q[1]}),
        .sum_o(dot_c)
    );

    integer i;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            valid_q <= 9'd0;
            result_o <= 32'sd0;
            for (i = 0; i < 8; i = i + 1) begin
                a_q[i] <= 4'sd0;
                b_q[i] <= 4'sd0;
                product_q[i] <= 8'sd0;
            end
            for (i = 0; i < 4; i = i + 1)
                pair_q[i] <= 9'sd0;
            for (i = 0; i < 2; i = i + 1)
                quad_q[i] <= 10'sd0;
        end else begin
            if (clear_i)
                valid_q <= 9'd0;
            else
                valid_q <= {
                    valid_q[7:0],
                    in_valid_i && in_ready_o
                };

            for (i = 0; i < 8; i = i + 1) begin
                a_q[i] <= lhs_i[4*i +: 4];
                b_q[i] <= rhs_i[4*i +: 4];
                product_q[i] <= product_c[i];
            end

            for (i = 0; i < 4; i = i + 1)
                pair_q[i] <= pair_c[i][8:0];

            for (i = 0; i < 2; i = i + 1)
                quad_q[i] <= quad_c[i][9:0];

            result_o <= {{20{dot_c[11]}}, dot_c};
        end
    end

    // synthesis translate_off
    always @(posedge clk_i)
        if (rst_ni && !clear_i && out_valid_o &&
            out_ready_i !== 1'b1)
            $fatal(1, "INT4 DOT8 requires continuous output consumption");
    // synthesis translate_on
endmodule


// Register short carry-select candidates.
// The following existing tree register captures the selected sum.
// Payload runs every cycle; validity is handled by the parent pipeline.
module ee_int4_add12_cs3_stage (
    input  wire        clk_i,
    input  wire        rst_ni,
    input  wire [11:0] a_i,
    input  wire [11:0] b_i,
    output wire [11:0] sum_o
);
    reg [3:0] low_q;
    reg [3:0] high0_q [0:2];
    reg [3:0] high1_q [0:2];

    integer k;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            low_q <= 4'd0;
            for (k = 0; k < 3; k = k + 1) begin
                high0_q[k] <= 4'd0;
                high1_q[k] <= 4'd1;
            end
        end else begin
            low_q <= {1'b0, a_i[2:0]} + {1'b0, b_i[2:0]};
            for (k = 0; k < 3; k = k + 1) begin
                high0_q[k] <=
                    {1'b0, a_i[3*(k+1) +: 3]} +
                    {1'b0, b_i[3*(k+1) +: 3]};
                high1_q[k] <=
                    {1'b0, a_i[3*(k+1) +: 3]} +
                    {1'b0, b_i[3*(k+1) +: 3]} + 4'd1;
            end
        end
    end

    wire carry3 = low_q[3];

    wire carry6 =
        high0_q[0][3] |
        (high1_q[0][3] & low_q[3]);

    wire carry9 =
        high0_q[1][3] |
        (high1_q[1][3] & high0_q[0][3]) |
        (high1_q[1][3] & high1_q[0][3] & low_q[3]);

    assign sum_o = {
        (carry9 ? high1_q[2][2:0] : high0_q[2][2:0]),
        (carry6 ? high1_q[1][2:0] : high0_q[1][2:0]),
        (carry3 ? high1_q[0][2:0] : high0_q[0][2:0]),
        low_q[2:0]
    };
endmodule

module ee_int4_multiplier_las_rows_pipe (
    input wire clk_i,
    input  wire signed [3:0] a,
    input  wire signed [3:0] b,
    output wire        [7:0] p
);
    // ----------------------------------------------------------------
    // Operand bits
    // ----------------------------------------------------------------
    wire a0=a[0], a1=a[1], a2=a[2], a3=a[3];
    wire b0=b[0], b1=b[1], b2=b[2], b3=b[3];

    // ----------------------------------------------------------------
    // Baugh-Wooley partial products
    // ----------------------------------------------------------------
    // col 0
    wire pp00  =  a0 & b0;
    // col 1
    wire pp10  =  a1 & b0;
    wire pp01  =  a0 & b1;
    // col 2
    wire pp20  =  a2 & b0;
    wire pp11  =  a1 & b1;
    wire pp02  =  a0 & b2;
    // col 3 — cross-sign terms complemented
    wire pp30n = ~(a3 & b0);
    wire pp21  =  a2 & b1;
    wire pp12  =  a1 & b2;
    wire pp03n = ~(a0 & b3);
    // col 4 — BW correction constant = 1
    wire pp31n = ~(a3 & b1);
    wire pp22  =  a2 & b2;
    wire pp13n = ~(a1 & b3);
    // col 5
    wire pp32n = ~(a3 & b2);
    wire pp23n = ~(a2 & b3);
    // col 6
    wire pp33  =  a3 & b3;

    // ----------------------------------------------------------------
    // INLINE LAS compressor tree
    // All expressions written flat — synthesizer sees full function.
    // Naming: _X1/_X2 = stacking signals, _p = propagate (XOR via LAS)
    // ----------------------------------------------------------------

    // --- FA_c2: compress col-2 dots (pp20, pp11, pp02) ---
    wire c2_X1  = pp20 | pp11;
    wire c2_X2  = pp20 & pp11;
    wire c2_p   = c2_X1 & ~c2_X2;      // pp20 XOR pp11
    wire s_c2   = c2_p  ^ pp02;
    wire k_c2   = c2_X2 | (c2_p & pp02);

    // --- C42_c3: compress col-3 dots (pp30n, pp21, pp12, pp03n), cin=k_c2 ---
    // Step 1: compress pp30n, pp21, pp12 -> s1_c3, co_c3
    //         co_c3 = f(pp30n, pp21, pp12) ONLY — look-ahead, no cin
    wire c3_X1   = pp30n | pp21;
    wire c3_X2   = pp30n & pp21;
    wire c3_p    = c3_X1 & ~c3_X2;     // pp30n XOR pp21
    wire s1_c3   = c3_p  ^ pp12;
    wire co_c3   = c3_X2 | (c3_p & pp12);   // cout: independent of k_c2
    // Step 2: compress s1_c3, pp03n, k_c2 -> s_c3, cr_c3
    wire c3b_X1  = s1_c3 | pp03n;
    wire c3b_X2  = s1_c3 & pp03n;
    wire c3b_p   = c3b_X1 & ~c3b_X2;
    wire s_c3    = c3b_p  ^ k_c2;
    wire cr_c3   = c3b_X2 | (c3b_p & k_c2);

    // --- FA_c4a: compress native col-4 dots (pp31n, pp22, pp13n) ---
    wire c4a_X1  = pp31n | pp22;
    wire c4a_X2  = pp31n & pp22;
    wire c4a_p   = c4a_X1 & ~c4a_X2;
    wire s_c4a   = c4a_p  ^ pp13n;
    wire k_c4a   = c4a_X2 | (c4a_p & pp13n);

    // --- FA_c4b: BW correction(1) + two carries from C42_c3 into col-4 ---
    // corr4 = 1'b1, so:
    //   X1 = 1|cr_c3 = 1  always
    //   X2 = 1&cr_c3 = cr_c3
    //   p  = X1&~X2  = ~cr_c3
    //   sum = ~cr_c3 ^ co_c3 = cr_c3 XNOR co_c3... simplified:
    // Write explicitly for synthesizer clarity:
    wire c4b_X1  = 1'b1 | cr_c3;       // always 1
    wire c4b_X2  = 1'b1 & cr_c3;       // = cr_c3
    wire c4b_p   = c4b_X1 & ~c4b_X2;   // = ~cr_c3
    wire s_c4b   = c4b_p  ^ co_c3;
    wire k_c4b   = c4b_X2 | (c4b_p & co_c3);

    // --- FA_c5: two native col-5 dots + carry from FA_c4a ---
    wire c5_X1   = pp32n | pp23n;
    wire c5_X2   = pp32n & pp23n;
    wire c5_p    = c5_X1 & ~c5_X2;
    wire s_c5    = c5_p  ^ k_c4a;
    wire k_c5    = c5_X2 | (c5_p & k_c4a);

    // ----------------------------------------------------------------
    // Carry-save rows (every column <= 2 dots)
    // col:   7      6      5       4       3      2      1      0
    // ----------------------------------------------------------------
    wire [7:0] X = {1'b1,  pp33,  s_c5,  s_c4a, s_c3,  s_c2,  pp10,  pp00};
    wire [7:0] Y = {1'b0,  k_c5,  k_c4b, s_c4b, 1'b0,  1'b0,  pp01,  1'b0};

    // ----------------------------------------------------------------
    // 8-bit CLA — parallel structure, two 4-bit blocks
    // ----------------------------------------------------------------

    // Register the existing LAS rows before the unchanged final CLA.
    // Payload runs continuously; the parent flushes validity on reset/clear.
    reg [7:0] X_rows_q;
    reg [7:0] Y_rows_q;
    always @(posedge clk_i) begin
        X_rows_q <= X;
        Y_rows_q <= Y;
    end

    wire [7:0] G = X_rows_q & Y_rows_q;       // bit generate
    wire [7:0] P = X_rows_q ^ Y_rows_q;       // bit propagate

    // Lower 4-bit look-ahead block (c0 = 0, no cin)
    wire c1 = G[0];
    wire c2 = G[1] | (P[1] & G[0]);
    wire c3 = G[2] | (P[2] & G[1]) | (P[2] & P[1] & G[0]);
    wire c4 = G[3] | (P[3] & G[2]) | (P[3] & P[2] & G[1])
                   | (P[3] & P[2] & P[1] & G[0]);

    // Upper 4-bit look-ahead block
    wire c5 = G[4] | (P[4] & c4);
    wire c6 = G[5] | (P[5] & G[4]) | (P[5] & P[4] & c4);
    wire c7 = G[6] | (P[6] & G[5]) | (P[6] & P[5] & G[4])
                   | (P[6] & P[5] & P[4] & c4);

    assign p[0] = P[0];                 // c0 = 0, so p[0] = P[0]^0 = P[0]
    assign p[1] = P[1] ^ c1;
    assign p[2] = P[2] ^ c2;
    assign p[3] = P[3] ^ c3;
    assign p[4] = P[4] ^ c4;
    assign p[5] = P[5] ^ c5;
    assign p[6] = P[6] ^ c6;
    assign p[7] = P[7] ^ c7;

endmodule

`default_nettype wire
