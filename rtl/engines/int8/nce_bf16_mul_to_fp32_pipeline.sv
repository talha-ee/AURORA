`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// HIGH-FREQUENCY BF16 x BF16 -> FP32 MULTIPLIER
//
// Pipeline:
//
// M0 : classify/decode operands
// M1 : 8x8 significand multiply + binary exponent add
// M2 : leading-one detect + final exponent classification
// M3 : normal alignment OR subnormal quotient/remainder generation
// M4 : RNE round + FP32 pack
//
// Pipeline is rigid: all stages advance together when the output stage can
// advance. This deliberately avoids a long backwards ready chain through
// every arithmetic stage.
//
// Semantics match the original NCE BF16 multiplier:
//   - canonical qNaN 0x7FC00000
//   - signalling NaN sets invalid
//   - infinity x zero sets invalid
//   - signed zero preserved
//   - finite normal product is exact in FP32
//   - subnormal rounding is round-to-nearest, ties-to-even
//   - tiny AND inexact produces underflow
// ============================================================================

module nce_bf16_mul_to_fp32_pipeline (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        clear_i,

    input  logic        in_valid_i,
    output logic        in_ready_o,

    input  logic [15:0] a_i,
    input  logic [15:0] b_i,

    output logic        out_valid_o,
    input  logic        out_ready_i,

    output logic [31:0] product_o,

    output logic        invalid_o,
    output logic        overflow_o,
    output logic        underflow_o,
    output logic        inexact_o
);

    localparam logic [1:0] CLASS_SPECIAL   = 2'd0;
    localparam logic [1:0] CLASS_OVERFLOW  = 2'd1;
    localparam logic [1:0] CLASS_NORMAL    = 2'd2;
    localparam logic [1:0] CLASS_SUBNORMAL = 2'd3;


    // ========================================================================
    // GLOBAL PIPELINE ADVANCE
    //
    // No ready ripple through arithmetic stages.
    // ========================================================================

    // ------------------------------------------------------------------------
    // INPUT BOUNDARY
    //
    // Raw GEMM/PE operands must terminate here.  No arithmetic is allowed
    // between the systolic operand network and these registers.
    // ------------------------------------------------------------------------

    logic        input_valid_q;
    logic [15:0] operand_a_q;
    logic [15:0] operand_b_q;

    logic s0_valid_q;
    logic s1_valid_q;
    logic s2_valid_q;
    logic s3_valid_q;
    logic s4_valid_q;

    wire pipeline_advance =
        !s4_valid_q ||
        out_ready_i;

    assign in_ready_o =
        rst_ni &&
        !clear_i &&
        pipeline_advance;


    // ========================================================================
    // M0 COMBINATIONAL : CLASSIFY + DECODE
    // ========================================================================

    logic [7:0] c0_exp_a;
    logic [7:0] c0_exp_b;

    logic [6:0] c0_frac_a;
    logic [6:0] c0_frac_b;

    logic c0_a_zero;
    logic c0_b_zero;

    logic c0_a_inf;
    logic c0_b_inf;

    logic c0_a_nan;
    logic c0_b_nan;

    logic c0_a_snan;
    logic c0_b_snan;

    logic c0_sign;

    logic        c0_special;
    logic [31:0] c0_special_result;
    logic        c0_special_invalid;

    logic [7:0] c0_sig_a;
    logic [7:0] c0_sig_b;

    logic signed [9:0] c0_exp2_a;
    logic signed [9:0] c0_exp2_b;


    always_comb begin

        c0_exp_a  = operand_a_q[14:7];
        c0_exp_b  = operand_b_q[14:7];

        c0_frac_a = operand_a_q[6:0];
        c0_frac_b = operand_b_q[6:0];

        c0_sign =
            operand_a_q[15] ^
            operand_b_q[15];


        c0_a_zero =
            (c0_exp_a == 8'h00) &&
            (c0_frac_a == 7'h00);

        c0_b_zero =
            (c0_exp_b == 8'h00) &&
            (c0_frac_b == 7'h00);


        c0_a_inf =
            (c0_exp_a == 8'hFF) &&
            (c0_frac_a == 7'h00);

        c0_b_inf =
            (c0_exp_b == 8'hFF) &&
            (c0_frac_b == 7'h00);


        c0_a_nan =
            (c0_exp_a == 8'hFF) &&
            (c0_frac_a != 7'h00);

        c0_b_nan =
            (c0_exp_b == 8'hFF) &&
            (c0_frac_b != 7'h00);


        c0_a_snan =
            c0_a_nan &&
            !c0_frac_a[6];

        c0_b_snan =
            c0_b_nan &&
            !c0_frac_b[6];


        c0_special         = 1'b0;
        c0_special_result  = 32'h0000_0000;
        c0_special_invalid = 1'b0;

        c0_sig_a  = 8'd0;
        c0_sig_b  = 8'd0;

        c0_exp2_a = 10'sd0;
        c0_exp2_b = 10'sd0;


        // ------------------------------------------------------------
        // NaN
        // ------------------------------------------------------------

        if (
            c0_a_nan ||
            c0_b_nan
        ) begin

            c0_special =
                1'b1;

            c0_special_result =
                32'h7FC0_0000;

            c0_special_invalid =
                c0_a_snan ||
                c0_b_snan;

        end


        // ------------------------------------------------------------
        // Infinity x zero
        // ------------------------------------------------------------

        else if (
            (c0_a_inf && c0_b_zero) ||
            (c0_b_inf && c0_a_zero)
        ) begin

            c0_special =
                1'b1;

            c0_special_result =
                32'h7FC0_0000;

            c0_special_invalid =
                1'b1;

        end


        // ------------------------------------------------------------
        // Infinity
        // ------------------------------------------------------------

        else if (
            c0_a_inf ||
            c0_b_inf
        ) begin

            c0_special =
                1'b1;

            c0_special_result = {
                c0_sign,
                8'hFF,
                23'd0
            };

        end


        // ------------------------------------------------------------
        // Signed zero
        // ------------------------------------------------------------

        else if (
            c0_a_zero ||
            c0_b_zero
        ) begin

            c0_special =
                1'b1;

            c0_special_result = {
                c0_sign,
                31'd0
            };

        end


        // ------------------------------------------------------------
        // Finite nonzero
        // ------------------------------------------------------------

        else begin

            if (c0_exp_a == 8'h00) begin

                c0_sig_a =
                    {
                        1'b0,
                        c0_frac_a
                    };

                c0_exp2_a =
                    -10'sd133;

            end
            else begin

                c0_sig_a =
                    {
                        1'b1,
                        c0_frac_a
                    };

                c0_exp2_a =
                    $signed({
                        1'b0,
                        c0_exp_a
                    }) -
                    10'sd134;

            end


            if (c0_exp_b == 8'h00) begin

                c0_sig_b =
                    {
                        1'b0,
                        c0_frac_b
                    };

                c0_exp2_b =
                    -10'sd133;

            end
            else begin

                c0_sig_b =
                    {
                        1'b1,
                        c0_frac_b
                    };

                c0_exp2_b =
                    $signed({
                        1'b0,
                        c0_exp_b
                    }) -
                    10'sd134;

            end

        end

    end


    // ========================================================================
    // M0 REGISTER
    // ========================================================================

    logic        s0_special_q;
    logic [31:0] s0_special_result_q;
    logic        s0_special_invalid_q;

    logic        s0_sign_q;

    logic [7:0]  s0_sig_a_q;
    logic [7:0]  s0_sig_b_q;

    logic signed [9:0] s0_exp2_a_q;
    logic signed [9:0] s0_exp2_b_q;


    // ========================================================================
    // M1 COMBINATIONAL : MULTIPLY + EXPONENT ADD
    // ========================================================================

    logic [15:0] c1_sig_product;
    logic signed [10:0] c1_exp2_sum;


    // MULCSA: registered carry-save reductions and final carry-select adder.
    function automatic [31:0] ee_bm_csa3(
        input logic [15:0] a, b, c
    );
        logic [15:0] sum_bits, carry_bits;
        begin
            sum_bits = a ^ b ^ c;
            carry_bits = ((a & b) | (a & c) | (b & c)) << 1;
            ee_bm_csa3 = {carry_bits, sum_bits};
        end
    endfunction

    function automatic [31:0] ee_bm_csa4(
        input logic [15:0] a, b, c, d
    );
        logic [31:0] first_pair;
        begin
            first_pair = ee_bm_csa3(a, b, c);
            ee_bm_csa4 = ee_bm_csa3(
                first_pair[15:0], first_pair[31:16], d);
        end
    endfunction

    wire [15:0] mp_partial [0:7];
    genvar bm;
    generate
        for (bm = 0; bm < 8; bm = bm + 1) begin : GEN_MULCSA_PP
            assign mp_partial[bm] =
                ({8'd0, s0_sig_a_q} << bm) & {16{s0_sig_b_q[bm]}};
        end
    endgenerate

    logic mp0_valid_q, mp1_valid_q;
    logic [31:0] mp0_lo_pair_q, mp0_hi_pair_q, mp1_pair_q;
    logic mp0_special_q, mp1_special_q;
    logic [31:0] mp0_special_result_q, mp1_special_result_q;
    logic mp0_special_invalid_q, mp1_special_invalid_q;
    logic mp0_sign_q, mp1_sign_q;
    logic signed [10:0] mp1_exp2_q;


    // EXPCS3: local candidates in MP0, carry selection in existing MP1.
    wire [10:0] ex11_a = {s0_exp2_a_q[9], s0_exp2_a_q};
    wire [10:0] ex11_b = {s0_exp2_b_q[9], s0_exp2_b_q};

    logic [3:0] ex3_lo_q;
    logic [3:0] ex3_m10_q, ex3_m11_q;
    logic [3:0] ex3_m20_q, ex3_m21_q;
    logic [1:0] ex3_hi0_q, ex3_hi1_q;

    wire ex3_c3 = ex3_lo_q[3];

    wire ex3_c6 =
        ex3_m10_q[3] |
        (ex3_m11_q[3] & ex3_lo_q[3]);

    wire ex3_c9 =
        ex3_m20_q[3] |
        (ex3_m21_q[3] & ex3_m10_q[3]) |
        (ex3_m21_q[3] & ex3_m11_q[3] & ex3_lo_q[3]);

    wire [10:0] ex3_sum = {
        (ex3_c9 ? ex3_hi1_q : ex3_hi0_q),
        (ex3_c6 ? ex3_m21_q[2:0] : ex3_m20_q[2:0]),
        (ex3_c3 ? ex3_m11_q[2:0] : ex3_m10_q[2:0]),
        ex3_lo_q[2:0]
    };



    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            mp0_valid_q <= 1'b0;
            mp1_valid_q <= 1'b0;
            mp0_lo_pair_q <= 32'd0;
            mp0_hi_pair_q <= 32'd0;
            mp1_pair_q <= 32'd0;
            mp0_special_q <= 1'b0;
            mp1_special_q <= 1'b0;
            mp0_special_result_q <= 32'd0;
            mp1_special_result_q <= 32'd0;
            mp0_special_invalid_q <= 1'b0;
            mp1_special_invalid_q <= 1'b0;
            mp0_sign_q <= 1'b0;
            mp1_sign_q <= 1'b0;
            ex3_lo_q <= 4'd0;
            ex3_m10_q <= 4'd0;
            ex3_m11_q <= 4'd1;
            ex3_m20_q <= 4'd0;
            ex3_m21_q <= 4'd1;
            ex3_hi0_q <= 2'd0;
            ex3_hi1_q <= 2'd1;
            mp1_exp2_q <= 11'sd0;
        end else if (clear_i) begin
            mp0_valid_q <= 1'b0;
            mp1_valid_q <= 1'b0;
        end else if (pipeline_advance) begin
            mp0_valid_q <= s0_valid_q;
            mp1_valid_q <= mp0_valid_q;

            mp0_lo_pair_q <= ee_bm_csa4(
                mp_partial[0], mp_partial[1],
                mp_partial[2], mp_partial[3]);
            mp0_hi_pair_q <= ee_bm_csa4(
                mp_partial[4], mp_partial[5],
                mp_partial[6], mp_partial[7]);
            mp1_pair_q <= ee_bm_csa4(
                mp0_lo_pair_q[15:0], mp0_lo_pair_q[31:16],
                mp0_hi_pair_q[15:0], mp0_hi_pair_q[31:16]);

            mp0_special_q <= s0_special_q;
            mp1_special_q <= mp0_special_q;
            mp0_special_result_q <= s0_special_result_q;
            mp1_special_result_q <= mp0_special_result_q;
            mp0_special_invalid_q <= s0_special_invalid_q;
            mp1_special_invalid_q <= mp0_special_invalid_q;
            mp0_sign_q <= s0_sign_q;
            mp1_sign_q <= mp0_sign_q;
            ex3_lo_q <=
                {1'b0, ex11_a[2:0]} + {1'b0, ex11_b[2:0]};
            ex3_m10_q <=
                {1'b0, ex11_a[5:3]} + {1'b0, ex11_b[5:3]};
            ex3_m11_q <=
                {1'b0, ex11_a[5:3]} + {1'b0, ex11_b[5:3]} + 4'd1;
            ex3_m20_q <=
                {1'b0, ex11_a[8:6]} + {1'b0, ex11_b[8:6]};
            ex3_m21_q <=
                {1'b0, ex11_a[8:6]} + {1'b0, ex11_b[8:6]} + 4'd1;
            ex3_hi0_q <=
                ex11_a[10:9] + ex11_b[10:9];
            ex3_hi1_q <=
                ex11_a[10:9] + ex11_b[10:9] + 2'd1;
            mp1_exp2_q <= ex3_sum;
        end
    end


    // CPA4REG: register four-bit sum candidates before carry selection.
    logic cpa_valid_q;
    logic [4:0] cpa_sum0_q [0:3], cpa_sum1_q [0:3];
    logic cpa_special_q, cpa_special_invalid_q, cpa_sign_q;
    logic [31:0] cpa_special_result_q;
    logic signed [10:0] cpa_exp2_q;
    integer cpai;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            cpa_valid_q <= 1'b0;
            {cpa_special_q, cpa_special_invalid_q, cpa_special_result_q,
             cpa_sign_q, cpa_exp2_q} <= '0;
            for (cpai = 0; cpai < 4; cpai = cpai + 1) begin
                cpa_sum0_q[cpai] <= 5'd0;
                cpa_sum1_q[cpai] <= 5'd1;
            end
        end else if (clear_i) begin
            cpa_valid_q <= 1'b0;
        end else if (pipeline_advance) begin
            cpa_valid_q <= mp1_valid_q;
            {cpa_special_q, cpa_special_invalid_q, cpa_special_result_q,
             cpa_sign_q, cpa_exp2_q} <=
            {mp1_special_q, mp1_special_invalid_q, mp1_special_result_q,
             mp1_sign_q, mp1_exp2_q};
            for (cpai = 0; cpai < 4; cpai = cpai + 1) begin
                cpa_sum0_q[cpai] <=
                    {1'b0, mp1_pair_q[cpai*4 +: 4]} +
                    {1'b0, mp1_pair_q[16+cpai*4 +: 4]};
                cpa_sum1_q[cpai] <=
                    {1'b0, mp1_pair_q[cpai*4 +: 4]} +
                    {1'b0, mp1_pair_q[16+cpai*4 +: 4]} + 5'd1;
            end
        end
    end

    wire [4:0] mp_add0 [0:3];
    wire [4:0] mp_add1 [0:3];
    wire [3:0] mp_add_carry;

    assign mp_add_carry[0] = 1'b0;
    assign mp_add_carry[1] = mp_add0[0][4];
    assign mp_add_carry[2] = mp_add0[1][4] |
        (mp_add1[1][4] & mp_add0[0][4]);
    assign mp_add_carry[3] = mp_add0[2][4] |
        (mp_add1[2][4] & mp_add0[1][4]) |
        (mp_add1[2][4] & mp_add1[1][4] & mp_add0[0][4]);

    generate
        for (bm = 0; bm < 4; bm = bm + 1) begin : GEN_MULCSA_CPA
            assign mp_add0[bm] = cpa_sum0_q[bm];
            assign mp_add1[bm] = cpa_sum1_q[bm];
            assign c1_sig_product[bm*4 +: 4] = mp_add_carry[bm]
                ? mp_add1[bm][3:0] : mp_add0[bm][3:0];
        end
    endgenerate

    assign c1_exp2_sum = cpa_exp2_q;



    // ========================================================================
    // M1 REGISTER
    // ========================================================================

    logic        s1_special_q;
    logic [31:0] s1_special_result_q;
    logic        s1_special_invalid_q;

    logic        s1_sign_q;

    logic [15:0] s1_sig_product_q;
    logic signed [10:0] s1_exp2_q;


    // ========================================================================
    // M2 COMBINATIONAL : LEADING-ONE + CLASSIFICATION
    // ========================================================================


    function automatic [1:0] ee_bm_msb4(input logic [3:0] v);
        begin
            ee_bm_msb4 = {v[3] | v[2], v[3] | (~v[2] & v[1])};
        end
    endfunction

    function automatic logic [3:0] find_msb16(input logic [15:0] value);
        logic v3, v2, v1, upper;
        logic [1:0] upper_index, lower_index, index_bits;
        begin
            v3 = |value[15:12];
            v2 = |value[11:8];
            v1 = |value[7:4];
            upper = v3 | v2;
            upper_index = v3 ? ee_bm_msb4(value[15:12])
                             : ee_bm_msb4(value[11:8]);
            lower_index = v1 ? ee_bm_msb4(value[7:4])
                             : ee_bm_msb4(value[3:0]);
            index_bits = upper ? upper_index : lower_index;
            find_msb16 = {upper, (v3 | (~upper & v1)), index_bits};
        end
    endfunction



    logic [3:0] c2_msb;

    logic signed [10:0]
        c2_unbiased_exponent;

    logic [1:0]
        c2_class;



    // M2SPLIT: leading-one detection, exponent assembly, then classification.
    logic mlz_valid_q, mex_valid_q;
    logic mlz_special_q, mex_special_q;
    logic mlz_special_invalid_q, mex_special_invalid_q;
    logic [31:0] mlz_special_result_q, mex_special_result_q;
    logic mlz_sign_q, mex_sign_q;
    logic [15:0] mlz_sig_product_q, mex_sig_product_q;
    logic signed [10:0] mlz_exp2_q, mex_exp2_q, mex_unbiased_q;
    logic [3:0] mlz_msb_q, mex_msb_q;
    logic [6:0] mlz_hi_inc_q;

    wire [4:0] mlz_low_sum =
        {1'b0, mlz_exp2_q[3:0]} + {1'b0, mlz_msb_q};
    wire signed [10:0] mlz_unbiased = {
        (mlz_low_sum[4] ? mlz_hi_inc_q : mlz_exp2_q[10:4]),
        mlz_low_sum[3:0]
    };

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            mlz_valid_q <= 1'b0;
            mex_valid_q <= 1'b0;
            {mlz_special_q, mlz_special_invalid_q, mlz_special_result_q,
             mlz_sign_q, mlz_sig_product_q, mlz_exp2_q, mlz_msb_q} <= '0;
            {mex_special_q, mex_special_invalid_q, mex_special_result_q,
             mex_sign_q, mex_sig_product_q, mex_exp2_q, mex_msb_q,
             mex_unbiased_q} <= '0;
            mlz_hi_inc_q <= 7'd1;
        end else if (clear_i) begin
            mlz_valid_q <= 1'b0;
            mex_valid_q <= 1'b0;
        end else if (pipeline_advance) begin
            mlz_valid_q <= s1_valid_q;
            mex_valid_q <= mlz_valid_q;

            {mlz_special_q, mlz_special_invalid_q, mlz_special_result_q,
             mlz_sign_q, mlz_sig_product_q, mlz_exp2_q} <=
            {s1_special_q, s1_special_invalid_q, s1_special_result_q,
             s1_sign_q, s1_sig_product_q, s1_exp2_q};
            mlz_msb_q <= find_msb16(s1_sig_product_q);
            mlz_hi_inc_q <= s1_exp2_q[10:4] + 7'd1;

            {mex_special_q, mex_special_invalid_q, mex_special_result_q,
             mex_sign_q, mex_sig_product_q, mex_exp2_q, mex_msb_q} <=
            {mlz_special_q, mlz_special_invalid_q, mlz_special_result_q,
             mlz_sign_q, mlz_sig_product_q, mlz_exp2_q, mlz_msb_q};
            mex_unbiased_q <= mlz_unbiased;
        end
    end

    always_comb begin

        c2_msb = mex_msb_q;

        c2_unbiased_exponent = mex_unbiased_q;


        if (mex_special_q) begin

            c2_class =
                CLASS_SPECIAL;

        end
        else if (
            c2_unbiased_exponent >
            11'sd127
        ) begin

            c2_class =
                CLASS_OVERFLOW;

        end
        else if (
            c2_unbiased_exponent >=
            -11'sd126
        ) begin

            c2_class =
                CLASS_NORMAL;

        end
        else begin

            c2_class =
                CLASS_SUBNORMAL;

        end

    end


    // ========================================================================
    // M2 REGISTER
    // ========================================================================

    logic [1:0]
        s2_class_q;

    logic        s2_special_invalid_q;
    logic [31:0] s2_special_result_q;

    logic        s2_sign_q;

    logic [15:0] s2_sig_product_q;

    logic signed [10:0]
        s2_exp2_q;

    logic signed [10:0]
        s2_unbiased_exponent_q;

    logic [3:0]
        s2_msb_q;


    // ========================================================================
    // M3 COMBINATIONAL : NORMAL ALIGNMENT / SUBNORMAL SHIFT
    // ========================================================================

    logic [31:0]
        c3_normal_result;

    logic [31:0]
        c3_quotient;

    logic
        c3_round_up;

    logic
        c3_subnormal_inexact;


    logic [31:0]
        c3_tmp;

    logic [31:0]
        c3_remainder;

    logic [31:0]
        c3_half;

    logic [31:0]
        c3_mask;

    logic signed [11:0]
        c3_shift_amount;

    logic [6:0]
        c3_right_shift;

    logic signed [11:0]
        c3_biased_exponent;



    // M3JAM: shift controls use the existing S2 register boundary.
    logic m3_left_q, m3_far_q, m3_eq16_q;
    logic [4:0] m3_ls_q;
    logic [3:0] m3_rs_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            m3_left_q <= 1'b0;
            m3_far_q <= 1'b0;
            m3_eq16_q <= 1'b0;
            m3_ls_q <= 5'd0;
            m3_rs_q <= 4'd0;
        end else if (!clear_i && pipeline_advance) begin
            m3_left_q <= ($signed(mex_exp2_q) >= -11'sd149);
            m3_far_q <= ($signed(mex_exp2_q) < -11'sd165);
            m3_eq16_q <= ($signed(mex_exp2_q) == -11'sd165);
            m3_ls_q <= mex_exp2_q[4:0] + 5'd21;
            m3_rs_q <= -mex_exp2_q[3:0] - 4'd5;
        end
    end

    wire [17:0] m3_j0 = {s2_sig_product_q, 2'b00};
    wire [17:0] m3_j8 = m3_rs_q[3]
        ? {8'd0, m3_j0[17:9], (|m3_j0[8:0])} : m3_j0;
    wire [17:0] m3_j4 = m3_rs_q[2]
        ? {4'd0, m3_j8[17:5], (|m3_j8[4:0])} : m3_j8;
    wire [17:0] m3_j2 = m3_rs_q[1]
        ? {2'd0, m3_j4[17:3], (|m3_j4[2:0])} : m3_j4;
    wire [17:0] m3_j1 = m3_rs_q[0]
        ? {1'b0, m3_j2[17:2], (|m3_j2[1:0])} : m3_j2;


    always_comb begin
        c3_normal_result = 32'd0;
        c3_quotient = 32'd0;
        c3_round_up = 1'b0;
        c3_subnormal_inexact = 1'b0;
        c3_tmp = {16'd0, s2_sig_product_q};
        c3_remainder = 32'd0;
        c3_half = 32'd0;
        c3_mask = 32'd0;
        c3_shift_amount = 12'sd0;
        c3_right_shift = 7'd0;
        c3_biased_exponent = $signed(s2_unbiased_exponent_q) + 12'sd127;

        if (
            s2_class_q ==
            CLASS_NORMAL
        ) begin

            c3_tmp =
                {
                    16'd0,
                    s2_sig_product_q
                }
                <<
                (
                    5'd23 -
                    {
                        1'b0,
                        s2_msb_q
                    }
                );


            c3_normal_result[31] =
                s2_sign_q;

            c3_normal_result[30:23] =
                c3_biased_exponent[7:0];

            c3_normal_result[22:0] =
                c3_tmp[22:0];

        end

        else if (s2_class_q == CLASS_SUBNORMAL) begin
            if (m3_left_q) begin
                c3_quotient = {16'd0, s2_sig_product_q} << m3_ls_q;
            end else if (m3_far_q) begin
                c3_subnormal_inexact = |s2_sig_product_q;
            end else if (m3_eq16_q) begin
                c3_round_up = s2_sig_product_q[15] & (|s2_sig_product_q[14:0]);
                c3_subnormal_inexact = |s2_sig_product_q;
            end else begin
                c3_quotient = {16'd0, m3_j1[17:2]};
                c3_round_up = m3_j1[1] & (m3_j1[0] | m3_j1[2]);
                c3_subnormal_inexact = m3_j1[1] | m3_j1[0];
            end
        end
    end



    // ========================================================================
    // M3 REGISTER
    // ========================================================================

    logic [1:0]
        s3_class_q;

    logic
        s3_special_invalid_q;

    logic [31:0]
        s3_special_result_q;

    logic
        s3_sign_q;

    logic [31:0]
        s3_normal_result_q;

    logic [31:0]
        s3_quotient_q;

    logic
        s3_round_up_q;

    logic
        s3_subnormal_inexact_q;


    // ========================================================================
    // M4 COMBINATIONAL : ROUND + PACK
    // ========================================================================

    logic [31:0]
        c4_product;

    logic
        c4_invalid;

    logic
        c4_overflow;

    logic
        c4_underflow;

    logic
        c4_inexact;

    logic [31:0]
        c4_rounded_quotient;



    // BR4: registered nibble increments and payload before final packing.
    logic br4_valid_q;
    logic [1:0] br4_class_q;
    logic [31:0] br4_special_result_q, br4_normal_result_q, br4_quotient_q;
    logic br4_special_invalid_q, br4_sign_q;
    logic br4_round_up_q, br4_subnormal_inexact_q;
    logic [31:0] br4_inc_q;
    // ROUND_PACK: register carries and promotion at the existing BR4 boundary.
    logic [7:0] br4_carry_q;
    logic br4_promote_q;
    wire [31:0] br4_rounded;
    integer br4i;
    genvar br4g;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            br4_valid_q <= 1'b0;
            br4_inc_q <= 32'h1111_1111;
            br4_carry_q <= 8'd0;
            br4_promote_q <= 1'b0;
            {br4_class_q, br4_special_result_q, br4_special_invalid_q,
             br4_sign_q, br4_normal_result_q, br4_quotient_q,
             br4_round_up_q, br4_subnormal_inexact_q} <= '0;
        end else if (clear_i) begin
            br4_valid_q <= 1'b0;
        end else if (pipeline_advance) begin
            br4_valid_q <= s3_valid_q;

            br4_promote_q <=
                ((|s3_quotient_q[31:23]) &
                 ~(s3_round_up_q & (&s3_quotient_q))) |
                (s3_round_up_q & (s3_quotient_q == 32'h007f_ffff));
            {br4_class_q, br4_special_result_q, br4_special_invalid_q,
             br4_sign_q, br4_normal_result_q, br4_quotient_q,
             br4_round_up_q, br4_subnormal_inexact_q} <=
            {s3_class_q, s3_special_result_q, s3_special_invalid_q,
             s3_sign_q, s3_normal_result_q, s3_quotient_q,
             s3_round_up_q, s3_subnormal_inexact_q};
            for (br4i = 0; br4i < 8; br4i = br4i + 1) begin
                br4_inc_q[br4i*4 +: 4] <=
                    s3_quotient_q[br4i*4 +: 4] + 4'd1;
                if (br4i == 0)
                    br4_carry_q[br4i] <= s3_round_up_q;
                else
                    br4_carry_q[br4i] <= s3_round_up_q &
                        ((s3_quotient_q & ((32'h1 << (br4i*4))-32'd1)) ==
                         ((32'h1 << (br4i*4))-32'd1));
            end
        end
    end

    generate
        for (br4g = 0; br4g < 8; br4g = br4g + 1) begin : GEN_BR4_ROUND
            wire carry_in;
            assign carry_in = br4_carry_q[br4g];
            assign br4_rounded[br4g*4 +: 4] = carry_in
                ? br4_inc_q[br4g*4 +: 4] : br4_quotient_q[br4g*4 +: 4];
        end
    endgenerate

    always_comb begin

        c4_product   = 32'h0000_0000;

        c4_invalid   = 1'b0;
        c4_overflow  = 1'b0;
        c4_underflow = 1'b0;
        c4_inexact   = 1'b0;


        c4_rounded_quotient = br4_rounded;


        case (br4_class_q)

            CLASS_SPECIAL: begin

                c4_product =
                    br4_special_result_q;

                c4_invalid =
                    br4_special_invalid_q;

            end


            CLASS_OVERFLOW: begin

                c4_product = {
                    br4_sign_q,
                    8'hFF,
                    23'd0
                };

                c4_overflow =
                    1'b1;

                c4_inexact =
                    1'b1;

            end


            CLASS_NORMAL: begin

                c4_product =
                    br4_normal_result_q;

            end


            CLASS_SUBNORMAL: begin

                c4_inexact =
                    br4_subnormal_inexact_q;


                // Rounding can promote the largest subnormal into
                // the smallest normal FP32 value.

                if (
                    br4_promote_q
                ) begin

                    c4_product = {
                        br4_sign_q,
                        8'h01,
                        23'd0
                    };

                    c4_underflow =
                        1'b0;

                end
                else begin

                    c4_product = {
                        br4_sign_q,
                        8'h00,
                        c4_rounded_quotient[22:0]
                    };

                    c4_underflow =
                        br4_subnormal_inexact_q;

                end

            end


            default: begin

                c4_product =
                    32'h7FC0_0000;

                c4_invalid =
                    1'b1;

            end

        endcase

    end


    // ========================================================================
    // PIPELINE REGISTERS
    // ========================================================================

    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni) begin

            input_valid_q <= 1'b0;
            operand_a_q    <= 16'd0;
            operand_b_q    <= 16'd0;

            input_valid_q <= 1'b0;

            s0_valid_q <= 1'b0;
            s1_valid_q <= 1'b0;
            s2_valid_q <= 1'b0;
            s3_valid_q <= 1'b0;
            s4_valid_q <= 1'b0;

            s0_special_q         <= 1'b0;
            s0_special_result_q  <= 32'd0;
            s0_special_invalid_q <= 1'b0;
            s0_sign_q            <= 1'b0;
            s0_sig_a_q           <= 8'd0;
            s0_sig_b_q           <= 8'd0;
            s0_exp2_a_q          <= 10'sd0;
            s0_exp2_b_q          <= 10'sd0;

            s1_special_q         <= 1'b0;
            s1_special_result_q  <= 32'd0;
            s1_special_invalid_q <= 1'b0;
            s1_sign_q            <= 1'b0;
            s1_sig_product_q     <= 16'd0;
            s1_exp2_q            <= 11'sd0;

            s2_class_q             <= CLASS_SPECIAL;
            s2_special_invalid_q   <= 1'b0;
            s2_special_result_q    <= 32'd0;
            s2_sign_q              <= 1'b0;
            s2_sig_product_q       <= 16'd0;
            s2_exp2_q              <= 11'sd0;
            s2_unbiased_exponent_q <= 11'sd0;
            s2_msb_q               <= 4'd0;

            s3_class_q              <= CLASS_SPECIAL;
            s3_special_invalid_q    <= 1'b0;
            s3_special_result_q     <= 32'd0;
            s3_sign_q               <= 1'b0;
            s3_normal_result_q      <= 32'd0;
            s3_quotient_q           <= 32'd0;
            s3_round_up_q           <= 1'b0;
            s3_subnormal_inexact_q  <= 1'b0;

            product_o   <= 32'd0;
            invalid_o   <= 1'b0;
            overflow_o  <= 1'b0;
            underflow_o <= 1'b0;
            inexact_o   <= 1'b0;

        end

        else if (clear_i) begin
            input_valid_q <= 1'b0;

            s0_valid_q <= 1'b0;
            s1_valid_q <= 1'b0;
            s2_valid_q <= 1'b0;
            s3_valid_q <= 1'b0;
            s4_valid_q <= 1'b0;

        end

        else if (pipeline_advance) begin

            // --------------------------------------------------------
            // M4
            // --------------------------------------------------------

            s4_valid_q <=
                br4_valid_q;

            if (br4_valid_q) begin

                product_o <=
                    c4_product;

                invalid_o <=
                    c4_invalid;

                overflow_o <=
                    c4_overflow;

                underflow_o <=
                    c4_underflow;

                inexact_o <=
                    c4_inexact;

            end


            // --------------------------------------------------------
            // M3
            // --------------------------------------------------------

            s3_valid_q <=
                s2_valid_q;

            if (s2_valid_q) begin

                s3_class_q <=
                    s2_class_q;

                s3_special_invalid_q <=
                    s2_special_invalid_q;

                s3_special_result_q <=
                    s2_special_result_q;

                s3_sign_q <=
                    s2_sign_q;

                s3_normal_result_q <=
                    c3_normal_result;

                s3_quotient_q <=
                    c3_quotient;

                s3_round_up_q <=
                    c3_round_up;

                s3_subnormal_inexact_q <=
                    c3_subnormal_inexact;

            end


            // --------------------------------------------------------
            // M2
            // --------------------------------------------------------

            s2_valid_q <=
                mex_valid_q;

            if (mex_valid_q) begin

                s2_class_q <=
                    c2_class;

                s2_special_invalid_q <=
                    mex_special_invalid_q;

                s2_special_result_q <=
                    mex_special_result_q;

                s2_sign_q <=
                    mex_sign_q;

                s2_sig_product_q <=
                    mex_sig_product_q;

                s2_exp2_q <=
                    mex_exp2_q;

                s2_unbiased_exponent_q <=
                    c2_unbiased_exponent;

                s2_msb_q <=
                    c2_msb;

            end


            // --------------------------------------------------------
            // M1
            // --------------------------------------------------------

            s1_valid_q <=
                cpa_valid_q;

            if (cpa_valid_q) begin

                s1_special_q <=
                    cpa_special_q;

                s1_special_result_q <=
                    cpa_special_result_q;

                s1_special_invalid_q <=
                    cpa_special_invalid_q;

                s1_sign_q <=
                    cpa_sign_q;

                s1_sig_product_q <=
                    c1_sig_product;

                s1_exp2_q <=
                    c1_exp2_sum;

            end


            // --------------------------------------------------------
            // M0 : decode/classify REGISTERED operands
            // --------------------------------------------------------

            s0_valid_q <=
                input_valid_q;

            if (input_valid_q) begin

                s0_special_q <=
                    c0_special;

                s0_special_result_q <=
                    c0_special_result;

                s0_special_invalid_q <=
                    c0_special_invalid;

                s0_sign_q <=
                    c0_sign;

                s0_sig_a_q <=
                    c0_sig_a;

                s0_sig_b_q <=
                    c0_sig_b;

                s0_exp2_a_q <=
                    c0_exp2_a;

                s0_exp2_b_q <=
                    c0_exp2_b;

            end


            // --------------------------------------------------------
            // INPUT : hard timing boundary from PE/GEMM
            // --------------------------------------------------------

            input_valid_q <=
                in_valid_i &&
                in_ready_o;

            if (
                in_valid_i &&
                in_ready_o
            ) begin

                operand_a_q <=
                    a_i;

                operand_b_q <=
                    b_i;

            end

        end

    end


    assign out_valid_o =
        s4_valid_q;

endmodule

`default_nettype wire
