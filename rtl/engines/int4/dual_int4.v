//============================================================================
//  dual_int4_multiplier.v
//============================================================================
//  Dual-lane signed INT4 x INT4 -> signed INT8 multiplier.
//  SKY130 HD target. No ZVS. Flat RTL — no compressor sub-modules.
//
//  WHY FLAT (no sub-module hierarchy):
//  ------------------------------------
//  When compressors are written as separate modules, the synthesizer sees
//  a black-box boundary at each instance and optimizes each one in
//  isolation. It cannot share logic across boundaries or collapse
//  complementary terms that appear in adjacent compressors.
//  Writing everything as one flat set of wire assignments gives the
//  synthesizer (Yosys + ABC) full visibility of the entire Boolean
//  function and produces a much smaller, faster netlist.
//
//  BAUGH-WOOLEY SIGNED 4x4 MULTIPLICATION
//  ----------------------------------------
//  For two's-complement INT4 operands A = a3a2a1a0, B = b3b2b1b0
//  (range -8..+7), Baugh-Wooley avoids full sign extension by:
//    - Complementing every partial product that involves exactly ONE
//      sign bit (a3 or b3, but not both)
//    - Keeping a3b3 as-is
//    - Adding two correction constants: 1 at column 4 and 1 at column 7
//  This gives an 8-bit result = A*B (mod 256) which is exactly the
//  two's-complement signed product for this range.
//
//  DOT DIAGRAM (col = bit weight 2^col):
//  col:  7      6      5       4        3       2      1      0
//       1*    a3b3  !a3b2   !a3b1    !a3b0   a2b0   a1b0   a0b0
//                   !a2b3    a2b2     a2b1   a1b1   a0b1
//                            !a1b3    a1b2   a0b2
//                             1*      !a0b3
//  (*) Baugh-Wooley correction constants
//  Column heights: c0=1 c1=2 c2=3 c3=4 c4=4 c5=2 c6=1 c7=1
//
//  LAS (LOOK-AHEAD STACKING) — INLINE IMPLEMENTATION
//  ---------------------------------------------------
//  Each full-adder (3:2) compression step is written using the LAS
//  stacking signals directly as wire expressions:
//    Given inputs i0, i1, i2:
//      X1  = i0 | i1          (propagate / stacking signal 1)
//      X2  = i0 & i1          (generate  / stacking signal 2)
//      pab = X1 & ~X2         (i0 XOR i1, derived from X1/X2 — no XOR gate)
//      sum = pab ^ i2
//      cry = X2 | (pab & i2)  (generate OR propagate-absorb)
//  carry is produced IN PARALLEL with sum (no serial dependency).
//  By inlining, the synthesizer sees the full Boolean expression and
//  can merge terms across adjacent compressor steps — impossible with
//  separate module instances.
//
//  4:2 COMPRESSION (INLINE LAS)
//  ------------------------------
//  Inputs: i0, i1, i2, i3, cin
//  Step 1: compress i0, i1, i2 using 3:2 LAS -> s1, cout
//    cout = f(i0,i1,i2) ONLY — structurally independent of cin
//  Step 2: compress s1, i3, cin using 3:2 LAS -> sum, carry
//  cout independence of cin = look-ahead property (no ripple between columns)
//
//  COMPRESSOR TREE MAPPING
//  ------------------------
//  FA_c2  (3:2): (a2b0, a1b1, a0b2)           -> s_c2,  k_c2
//  C42_c3 (4:2): (!a3b0, a2b1, a1b2, !a0b3)   -> s_c3,  cr_c3, co_c3
//                 cin=k_c2; co_c3 independent of k_c2
//  FA_c4a (3:2): (!a3b1, a2b2, !a1b3)          -> s_c4a, k_c4a
//  FA_c4b (3:2): (1_corr, cr_c3, co_c3)        -> s_c4b, k_c4b
//  FA_c5  (3:2): (!a3b2, !a2b3, k_c4a)         -> s_c5,  k_c5
//
//  Final two rows (every column <= 2 dots):
//  X = {1,    a3b3, s_c5,  s_c4a, s_c3, s_c2, a1b0, a0b0}
//  Y = {0,    k_c5, k_c4b, s_c4b, 0,    0,    a0b1, 0   }
//  product = X + Y (8-bit CLA)
//
//  8-BIT CLA — PARALLEL STRUCTURE VIA GENERATE
//  ---------------------------------------------
//  Written with Verilog generate so the synthesizer sees all carry
//  expressions as parallel combinational logic — not a ripple chain.
//  Two 4-bit look-ahead blocks; block-level carry computed from
//  per-bit G/P terms directly.
//============================================================================

`timescale 1ns/1ps

//============================================================================
//  int4_multiplier_las — single lane, fully flat
//============================================================================
module int4_multiplier_las (
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
    wire [7:0] G = X & Y;       // bit generate
    wire [7:0] P = X ^ Y;       // bit propagate

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


//============================================================================
//  dual_int4_multiplier — TOP LEVEL
//  Two fully parallel lanes. No gating, no ZVS.
//============================================================================
module dual_int4_multiplier (
    input  wire signed [3:0] act0,
    input  wire signed [3:0] w0,
    input  wire signed [3:0] act1,
    input  wire signed [3:0] w1,
    output wire        [7:0] p0,
    output wire        [7:0] p1
);
    int4_multiplier_las u_lane0 (.a(act0), .b(w0), .p(p0));
    int4_multiplier_las u_lane1 (.a(act1), .b(w1), .p(p1));
endmodule


//============================================================================
//  tb_dual_int4_multiplier — exhaustive self-checking testbench
//  Checks all 256 (a,b) pairs on both lanes simultaneously.
//============================================================================
`timescale 1ns/1ps
