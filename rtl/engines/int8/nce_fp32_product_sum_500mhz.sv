`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// 500 MHz oriented IEEE-754 FP32 addition pipeline.
//
// Fixed-flow datapath:
//   alignment pipeline
//   7-bit add/sub x4
//   carry normalization
//   normalize 16
//   normalize 8
//   normalize 4
//   normalize 2
//   normalize 1
//   rounding decision
//   prefix increment + pack
//
// No wide combinational normalize/barrel-shift stage.
// ============================================================================

module nce_fp32_product_sum_500mhz #(
    parameter integer META_W = 4
)(
    input  logic                 clk_i,
    input  logic                 rst_ni,
    input  logic                 clear_i,

    input  logic                 in_valid_i,
    output logic                 in_ready_o,

    input  logic [31:0]          a_i,
    input  logic [31:0]          b_i,
    input  logic [META_W-1:0]    meta_i,

    output logic                 out_valid_o,
    input  logic                 out_ready_i,

    output logic [31:0]          result_o,

    output logic                 invalid_o,
    output logic                 overflow_o,
    output logic                 underflow_o,
    output logic                 inexact_o,

    output logic [META_W-1:0]    meta_o
);

    // Fixed-flow arithmetic.
    assign in_ready_o =
        rst_ni && !clear_i;


    // ========================================================================
    // ALIGNMENT PIPELINE
    // ========================================================================

    logic align_valid;

    logic align_sign;
    logic align_subtract;
    logic [7:0] align_exp;

    logic [26:0] align_large;
    logic [26:0] align_small;

    logic align_special;
    logic [31:0] align_special_result;
    logic align_special_invalid;

    logic [META_W-1:0] align_meta;


    nce_fp32_align_pipeline_500mhz #(
        .META_W (META_W)
    ) u_align_pipeline (

        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),
        .clear_i                (clear_i),

        .in_valid_i             (in_valid_i),

        .a_i                    (a_i),
        .b_i                    (b_i),

        .meta_i                 (meta_i),

        .out_valid_o            (align_valid),

        .large_sign_o           (align_sign),
        .subtract_o             (align_subtract),

        .common_exponent_o      (align_exp),

        .large_significand_o    (align_large),
        .small_significand_o    (align_small),

        .special_handled_o      (align_special),
        .special_result_o       (align_special_result),
        .special_invalid_o      (align_special_invalid),

        .meta_o                 (align_meta)
    );


    // ========================================================================
    // 28-bit significand ADD/SUB -- four 7-bit registered slices
    // ========================================================================

    wire [27:0] add_a =
        {1'b0, align_large};

    wire [27:0] add_b =
        {1'b0, align_small};


    // ------------------------------------------------------------------------
    // C0 : bits 6:0
    // ------------------------------------------------------------------------

    wire [6:0] c0_b_eff =
        add_b[6:0] ^
        {7{align_subtract}};

    // Parallel 2 + 2 + 3-bit carry-select adder.
    function automatic [7:0] ee_ps_cs7(
        input logic [6:0] a,
        input logic [6:0] b,
        input logic cin
    );
        logic [2:0] lo, mid0, mid1, mid;
        logic [3:0] hi0, hi1, hi;
        begin
            lo = {1'b0, a[1:0]} + {1'b0, b[1:0]} + {2'b0, cin};
            mid0 = {1'b0, a[3:2]} + {1'b0, b[3:2]};
            mid1 = {1'b0, a[3:2]} + {1'b0, b[3:2]} + 3'd1;
            hi0 = {1'b0, a[6:4]} + {1'b0, b[6:4]};
            hi1 = {1'b0, a[6:4]} + {1'b0, b[6:4]} + 4'd1;
            mid = lo[2] ? mid1 : mid0;
            hi = mid[2] ? hi1 : hi0;
            ee_ps_cs7 = {hi, mid[1:0], lo[1:0]};
        end
    endfunction

    wire [7:0] c0_sum =
        ee_ps_cs7(add_a[6:0], c0_b_eff, align_subtract);


    logic c0_valid_q;

    logic [6:0]  c0_low_q;
    logic        c0_carry_q;

    logic [20:0] c0_a_hi_q;
    logic [20:0] c0_b_hi_q;

    logic        c0_sub_q;
    logic        c0_sign_q;
    logic [7:0]  c0_exp_q;

    logic        c0_special_q;
    logic [31:0] c0_special_result_q;
    logic        c0_special_invalid_q;

    logic [META_W-1:0] c0_meta_q;


    // ------------------------------------------------------------------------
    // C1 : bits 13:7
    // ------------------------------------------------------------------------

    // Register short-adder candidates in the preceding slice stage.
    function automatic [19:0] ee_ps_candidates7(
        input logic [6:0] a,
        input logic [6:0] b
    );
        logic [2:0] lo0, lo1, mid0, mid1;
        logic [3:0] hi0, hi1;
        begin
            lo0  = {1'b0, a[1:0]} + {1'b0, b[1:0]};
            lo1  = {1'b0, a[1:0]} + {1'b0, b[1:0]} + 3'd1;
            mid0 = {1'b0, a[3:2]} + {1'b0, b[3:2]};
            mid1 = {1'b0, a[3:2]} + {1'b0, b[3:2]} + 3'd1;
            hi0  = {1'b0, a[6:4]} + {1'b0, b[6:4]};
            hi1  = {1'b0, a[6:4]} + {1'b0, b[6:4]} + 4'd1;
            ee_ps_candidates7 = {hi1, hi0, mid1, mid0, lo1, lo0};
        end
    endfunction

    function automatic [7:0] ee_ps_select7(
        input logic [19:0] candidates,
        input logic cin
    );
        logic [2:0] lo, mid;
        logic [3:0] hi;
        begin
            lo  = cin ? candidates[5:3] : candidates[2:0];
            mid = lo[2] ? candidates[11:9] : candidates[8:6];
            hi  = mid[2] ? candidates[19:16] : candidates[15:12];
            ee_ps_select7 = {hi, mid[1:0], lo[1:0]};
        end
    endfunction

    logic [19:0] c0cs_candidates_q, c1cs_candidates_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            c0cs_candidates_q <= ee_ps_candidates7(7'd0, 7'd0);
            c1cs_candidates_q <= ee_ps_candidates7(7'd0, 7'd0);
        end else begin
            c0cs_candidates_q <= ee_ps_candidates7(
                add_a[13:7], add_b[13:7] ^ {7{align_subtract}});
            c1cs_candidates_q <= ee_ps_candidates7(
                c0_a_hi_q[13:7], c0_b_hi_q[13:7] ^ {7{c0_sub_q}});
        end
    end

    wire [7:0] c1_sum = ee_ps_select7(c0cs_candidates_q, c0_carry_q);


    logic c1_valid_q;

    logic [13:0] c1_low_q;
    logic        c1_carry_q;

    logic [13:0] c1_a_hi_q;
    logic [13:0] c1_b_hi_q;

    logic        c1_sub_q;
    logic        c1_sign_q;
    logic [7:0]  c1_exp_q;

    logic        c1_special_q;
    logic [31:0] c1_special_result_q;
    logic        c1_special_invalid_q;

    logic [META_W-1:0] c1_meta_q;


    // ------------------------------------------------------------------------
    // C2 : bits 20:14
    // ------------------------------------------------------------------------

    wire [7:0] c2_sum = ee_ps_select7(c1cs_candidates_q, c1_carry_q);


    logic c2_valid_q;

    logic [20:0] c2_low_q;
    logic        c2_carry_q;

    logic [6:0]  c2_a_hi_q;
    logic [6:0]  c2_b_hi_q;

    logic        c2_sub_q;
    logic        c2_sign_q;
    logic [7:0]  c2_exp_q;

    logic        c2_special_q;
    logic [31:0] c2_special_result_q;
    logic        c2_special_invalid_q;

    logic [META_W-1:0] c2_meta_q;


    // ------------------------------------------------------------------------
    // C3 : bits 27:21
    // ------------------------------------------------------------------------

    // Precompute final-chunk candidates alongside C2.
    wire [6:0] c2cs_b_eff_c =
        c1_b_hi_q[13:7] ^ {7{c1_sub_q}};

    logic [3:0] c2cs_lo0_q, c2cs_lo1_q;
    logic [4:0] c2cs_hi0_q, c2cs_hi1_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            c2cs_lo0_q <= 4'd0;
            c2cs_lo1_q <= 4'd1;
            c2cs_hi0_q <= 5'd0;
            c2cs_hi1_q <= 5'd1;
        end else begin
            c2cs_lo0_q <=
                {1'b0, c1_a_hi_q[9:7]} +
                {1'b0, c2cs_b_eff_c[2:0]};
            c2cs_lo1_q <=
                {1'b0, c1_a_hi_q[9:7]} +
                {1'b0, c2cs_b_eff_c[2:0]} + 4'd1;
            c2cs_hi0_q <=
                {1'b0, c1_a_hi_q[13:10]} +
                {1'b0, c2cs_b_eff_c[6:3]};
            c2cs_hi1_q <=
                {1'b0, c1_a_hi_q[13:10]} +
                {1'b0, c2cs_b_eff_c[6:3]} + 5'd1;
        end
    end

    // C3 selects candidates using the actual incoming carry.
    wire [3:0] c3cs_lo_c =
        c2_carry_q ? c2cs_lo1_q : c2cs_lo0_q;
    wire [4:0] c3cs_hi_c =
        c3cs_lo_c[3] ? c2cs_hi1_q : c2cs_hi0_q;
    wire [7:0] c3_sum = {c3cs_hi_c, c3cs_lo_c[2:0]};


    wire [27:0] raw_sig_c = {
        c3_sum[6:0],
        c2_low_q
    };

    wire raw_zero_c =
        (raw_sig_c == 28'd0);


    logic c3_valid_q;

    logic        c3_sign_q;
    logic [7:0]  c3_exp_q;
    logic [27:0] c3_sig_q;
    logic        c3_zero_q;

    logic        c3_special_q;
    logic [31:0] c3_special_result_q;
    logic        c3_special_invalid_q;

    logic [META_W-1:0] c3_meta_q;


    // ========================================================================
    // NORMALIZATION PIPELINE
    //
    // The previous design performed:
    //
    //   priority encoder
    //      + shift calculation
    //      + 27-bit variable shift
    //      + exponent subtraction
    //
    // in one cycle.
    //
    // These fixed-distance stages remove that path completely.
    // ========================================================================


    // ------------------------------------------------------------------------
    // N0 : carry normalization / zero handling
    // ------------------------------------------------------------------------

    logic n0_valid_q;

    logic        n0_sign_q;
    logic [7:0]  n0_exp_q;
    logic [26:0] n0_sig_q;
    logic        n0_done_q;
    logic        n0_zero_q;

    logic        n0_special_q;
    logic [31:0] n0_special_result_q;
    logic        n0_special_invalid_q;

    logic [META_W-1:0] n0_meta_q;


    // ------------------------------------------------------------------------
    // N16
    // ------------------------------------------------------------------------

    wire n16_shift =
        !n0_done_q &&
        (n0_exp_q > 8'd16) &&
        !(|n0_sig_q[26:11]);

    logic n16_valid_q;

    logic        n16_sign_q;
    logic [7:0]  n16_exp_q;
    logic [26:0] n16_sig_q;
    logic        n16_done_q;
    logic        n16_zero_q;

    logic        n16_special_q;
    logic [31:0] n16_special_result_q;
    logic        n16_special_invalid_q;

    logic [META_W-1:0] n16_meta_q;


    // ------------------------------------------------------------------------
    // N8
    // ------------------------------------------------------------------------

    wire n8_shift =
        !n16_done_q &&
        (n16_exp_q > 8'd8) &&
        !(|n16_sig_q[26:19]);

    logic n8_valid_q;

    logic        n8_sign_q;
    logic [7:0]  n8_exp_q;
    logic [26:0] n8_sig_q;
    logic        n8_done_q;
    logic        n8_zero_q;

    logic        n8_special_q;
    logic [31:0] n8_special_result_q;
    logic        n8_special_invalid_q;

    logic [META_W-1:0] n8_meta_q;


    // ------------------------------------------------------------------------
    // N4
    // ------------------------------------------------------------------------

    wire n4_shift =
        !n8_done_q &&
        (n8_exp_q > 8'd4) &&
        !(|n8_sig_q[26:23]);

    logic n4_valid_q;

    logic        n4_sign_q;
    logic [7:0]  n4_exp_q;
    logic [26:0] n4_sig_q;
    logic        n4_done_q;
    logic        n4_zero_q;

    logic        n4_special_q;
    logic [31:0] n4_special_result_q;
    logic        n4_special_invalid_q;

    logic [META_W-1:0] n4_meta_q;


    // ------------------------------------------------------------------------
    // N2
    // ------------------------------------------------------------------------

    wire n2_shift =
        !n4_done_q &&
        (n4_exp_q > 8'd2) &&
        !(|n4_sig_q[26:25]);


    // N2P: register decision, exponent candidates and complete payload.
    logic n2p_valid_q;
    logic  n2p_shift_q;
    logic  n2p_sign_q;
    logic [7:0] n2p_exp_q;
    logic [7:0] n2p_exp_minus2_q;
    logic [26:0] n2p_sig_q;
    logic  n2p_done_q;
    logic  n2p_zero_q;
    logic  n2p_special_q;
    logic [31:0] n2p_special_result_q;
    logic  n2p_special_invalid_q;
    logic [META_W-1:0] n2p_meta_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            n2p_valid_q <= 1'b0;
            n2p_shift_q <= 1'b0;
            n2p_sign_q <= 1'b0;
            n2p_exp_q <= 8'd0;
            n2p_exp_minus2_q <= 8'd0;
            n2p_sig_q <= 27'd0;
            n2p_done_q <= 1'b0;
            n2p_zero_q <= 1'b1;
            n2p_special_q <= 1'b0;
            n2p_special_result_q <= 32'd0;
            n2p_special_invalid_q <= 1'b0;
            n2p_meta_q <= '0;
        end else begin
            n2p_valid_q <= !clear_i && n4_valid_q;
            n2p_shift_q <= n2_shift;
            n2p_sign_q <= n4_sign_q;
            n2p_exp_q <= n4_exp_q;
            n2p_exp_minus2_q <= n4_exp_q - 8'd2;
            n2p_sig_q <= n4_sig_q;
            n2p_done_q <= n4_done_q;
            n2p_zero_q <= n4_zero_q;
            n2p_special_q <= n4_special_q;
            n2p_special_result_q <= n4_special_result_q;
            n2p_special_invalid_q <= n4_special_invalid_q;
            n2p_meta_q <= n4_meta_q;
        end
    end

    logic n2_valid_q;

    logic        n2_sign_q;
    logic [7:0]  n2_exp_q;
    logic [26:0] n2_sig_q;
    logic        n2_done_q;
    logic        n2_zero_q;

    logic        n2_special_q;
    logic [31:0] n2_special_result_q;
    logic        n2_special_invalid_q;

    logic [META_W-1:0] n2_meta_q;


    // ------------------------------------------------------------------------
    // N1
    // ------------------------------------------------------------------------

    // N1_DECISION: compute final shift at the existing N2 boundary.
    logic n1_shift_q;
    wire n1_shift = n1_shift_q;

    logic n1_valid_q;

    logic        n1_sign_q;
    logic [7:0]  n1_exp_q;
    logic [26:0] n1_sig_q;
    logic        n1_zero_q;
    logic        n1_subnormal_q;

    logic        n1_special_q;
    logic [31:0] n1_special_result_q;
    logic        n1_special_invalid_q;

    logic [META_W-1:0] n1_meta_q;


    // ========================================================================
    // ROUND DECISION REGISTER
    // ========================================================================

    logic r0_valid_q;

    logic        r0_sign_q;
    logic [7:0]  r0_exp_q;

    logic [23:0] r0_retained_q;

    logic        r0_round_inc_q;
    logic        r0_discarded_q;

    logic        r0_zero_q;
    logic        r0_subnormal_q;

    logic        r0_special_q;
    logic [31:0] r0_special_result_q;
    logic        r0_special_invalid_q;

    logic [META_W-1:0] r0_meta_q;


    // ========================================================================
    // R1: parallel 6-bit increments and registered group flags.
    logic r1_valid_q;
    logic  r1_sign_q;
    logic [7:0] r1_exp_q;
    logic [23:0] r1_retained_q;
    logic  r1_round_inc_q;
    logic  r1_discarded_q;
    logic  r1_zero_q;
    logic  r1_subnormal_q;
    logic  r1_special_q;
    logic [31:0] r1_special_result_q;
    logic  r1_special_invalid_q;
    logic [META_W-1:0] r1_meta_q;
    logic [23:0] r1_inc_sig_q;
    logic [3:0] r1_group_all_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r1_valid_q <= 1'b0;
            r1_sign_q <= 1'b0;
            r1_exp_q <= 8'd0;
            r1_retained_q <= 24'd0;
            r1_round_inc_q <= 1'b0;
            r1_discarded_q <= 1'b0;
            r1_zero_q <= 1'b1;
            r1_subnormal_q <= 1'b0;
            r1_special_q <= 1'b0;
            r1_special_result_q <= 32'd0;
            r1_special_invalid_q <= 1'b0;
            r1_meta_q <= '0;
            r1_inc_sig_q <= 24'd0;
            r1_group_all_q <= 4'd0;
        end else begin
            r1_valid_q <= !clear_i && r0_valid_q;
            r1_sign_q <= r0_sign_q;
            r1_exp_q <= r0_exp_q;
            r1_retained_q <= r0_retained_q;
            r1_round_inc_q <= r0_round_inc_q;
            r1_discarded_q <= r0_discarded_q;
            r1_zero_q <= r0_zero_q;
            r1_subnormal_q <= r0_subnormal_q;
            r1_special_q <= r0_special_q;
            r1_special_result_q <= r0_special_result_q;
            r1_special_invalid_q <= r0_special_invalid_q;
            r1_meta_q <= r0_meta_q;
            r1_inc_sig_q[0 +: 6] <= r0_retained_q[0 +: 6] + 6'd1;
            r1_group_all_q[0] <= &r0_retained_q[0 +: 6];
            r1_inc_sig_q[6 +: 6] <= r0_retained_q[6 +: 6] + 6'd1;
            r1_group_all_q[1] <= &r0_retained_q[6 +: 6];
            r1_inc_sig_q[12 +: 6] <= r0_retained_q[12 +: 6] + 6'd1;
            r1_group_all_q[2] <= &r0_retained_q[12 +: 6];
            r1_inc_sig_q[18 +: 6] <= r0_retained_q[18 +: 6] + 6'd1;
            r1_group_all_q[3] <= &r0_retained_q[18 +: 6];
        end
    end

    wire [3:0] r1_chunk_carry_c;
    wire [23:0] rounded_sig;
    assign r1_chunk_carry_c[0] = r1_round_inc_q;
    assign r1_chunk_carry_c[1] = r1_round_inc_q & (&r1_group_all_q[0:0]);
    assign r1_chunk_carry_c[2] = r1_round_inc_q & (&r1_group_all_q[1:0]);
    assign r1_chunk_carry_c[3] = r1_round_inc_q & (&r1_group_all_q[2:0]);
    assign rounded_sig[0 +: 6] = r1_chunk_carry_c[0]
        ? r1_inc_sig_q[0 +: 6] : r1_retained_q[0 +: 6];
    assign rounded_sig[6 +: 6] = r1_chunk_carry_c[1]
        ? r1_inc_sig_q[6 +: 6] : r1_retained_q[6 +: 6];
    assign rounded_sig[12 +: 6] = r1_chunk_carry_c[2]
        ? r1_inc_sig_q[12 +: 6] : r1_retained_q[12 +: 6];
    assign rounded_sig[18 +: 6] = r1_chunk_carry_c[3]
        ? r1_inc_sig_q[18 +: 6] : r1_retained_q[18 +: 6];
    wire rounded_overflow = r1_round_inc_q & (&r1_group_all_q);

    // ========================================================================
    // FINAL PACK COMBINATIONAL
    // ========================================================================

    logic [31:0] packed_result_c;

    logic packed_invalid_c;
    logic packed_overflow_c;
    logic packed_underflow_c;
    logic packed_inexact_c;


    always_comb begin

        packed_result_c =
            32'h0000_0000;

        packed_invalid_c =
            1'b0;

        packed_overflow_c =
            1'b0;

        packed_underflow_c =
            1'b0;

        packed_inexact_c =
            1'b0;


        if (r1_special_q) begin

            packed_result_c =
                r1_special_result_q;

            packed_invalid_c =
                r1_special_invalid_q;

        end

        else if (r1_zero_q) begin

            packed_result_c =
                32'h0000_0000;

        end

        else if (r1_exp_q >= 8'hff) begin

            packed_result_c = {
                r1_sign_q,
                8'hff,
                23'd0
            };

            packed_overflow_c =
                1'b1;

            packed_inexact_c =
                1'b1;

        end

        else if (r1_subnormal_q) begin

            packed_inexact_c =
                r1_discarded_q;

            if (rounded_sig[23]) begin

                packed_result_c = {
                    r1_sign_q,
                    8'h01,
                    rounded_sig[22:0]
                };

            end

            else begin

                packed_result_c = {
                    r1_sign_q,
                    8'h00,
                    rounded_sig[22:0]
                };

                packed_underflow_c =
                    r1_discarded_q;

            end

        end

        else if (rounded_overflow) begin

            if (r1_exp_q >= 8'hfe) begin

                packed_result_c = {
                    r1_sign_q,
                    8'hff,
                    23'd0
                };

                packed_overflow_c =
                    1'b1;

                packed_inexact_c =
                    1'b1;

            end

            else begin

                packed_result_c = {
                    r1_sign_q,
                    r1_exp_q + 8'd1,
                    23'd0
                };

                packed_inexact_c =
                    r1_discarded_q;

            end

        end

        else begin

            packed_result_c = {
                r1_sign_q,
                r1_exp_q,
                rounded_sig[22:0]
            };

            packed_inexact_c =
                r1_discarded_q;

        end

    end


    // ========================================================================
    // REGISTER PIPELINE
    // ========================================================================

    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni) begin

            c0_valid_q <= 1'b0;
            c1_valid_q <= 1'b0;
            c2_valid_q <= 1'b0;
            c3_valid_q <= 1'b0;

            n0_valid_q  <= 1'b0;
            n16_valid_q <= 1'b0;
            n8_valid_q  <= 1'b0;
            n4_valid_q  <= 1'b0;
            n2_valid_q  <= 1'b0;
            n1_valid_q  <= 1'b0;

            r0_valid_q <= 1'b0;

            out_valid_o <= 1'b0;


            c0_low_q   <= '0;
            c0_carry_q <= 1'b0;
            c0_a_hi_q  <= '0;
            c0_b_hi_q  <= '0;
            c0_sub_q   <= 1'b0;
            c0_sign_q  <= 1'b0;
            c0_exp_q   <= '0;
            c0_special_q <= 1'b0;
            c0_special_result_q <= '0;
            c0_special_invalid_q <= 1'b0;
            c0_meta_q <= '0;


            c1_low_q   <= '0;
            c1_carry_q <= 1'b0;
            c1_a_hi_q  <= '0;
            c1_b_hi_q  <= '0;
            c1_sub_q   <= 1'b0;
            c1_sign_q  <= 1'b0;
            c1_exp_q   <= '0;
            c1_special_q <= 1'b0;
            c1_special_result_q <= '0;
            c1_special_invalid_q <= 1'b0;
            c1_meta_q <= '0;


            c2_low_q   <= '0;
            c2_carry_q <= 1'b0;
            c2_a_hi_q  <= '0;
            c2_b_hi_q  <= '0;
            c2_sub_q   <= 1'b0;
            c2_sign_q  <= 1'b0;
            c2_exp_q   <= '0;
            c2_special_q <= 1'b0;
            c2_special_result_q <= '0;
            c2_special_invalid_q <= 1'b0;
            c2_meta_q <= '0;


            c3_sign_q <= 1'b0;
            c3_exp_q  <= '0;
            c3_sig_q  <= '0;
            c3_zero_q <= 1'b1;
            c3_special_q <= 1'b0;
            c3_special_result_q <= '0;
            c3_special_invalid_q <= 1'b0;
            c3_meta_q <= '0;


            n0_sign_q <= 1'b0;
            n0_exp_q  <= '0;
            n0_sig_q  <= '0;
            n0_done_q <= 1'b0;
            n0_zero_q <= 1'b1;
            n0_special_q <= 1'b0;
            n0_special_result_q <= '0;
            n0_special_invalid_q <= 1'b0;
            n0_meta_q <= '0;


            n16_sign_q <= 1'b0;
            n16_exp_q  <= '0;
            n16_sig_q  <= '0;
            n16_done_q <= 1'b0;
            n16_zero_q <= 1'b1;
            n16_special_q <= 1'b0;
            n16_special_result_q <= '0;
            n16_special_invalid_q <= 1'b0;
            n16_meta_q <= '0;


            n8_sign_q <= 1'b0;
            n8_exp_q  <= '0;
            n8_sig_q  <= '0;
            n8_done_q <= 1'b0;
            n8_zero_q <= 1'b1;
            n8_special_q <= 1'b0;
            n8_special_result_q <= '0;
            n8_special_invalid_q <= 1'b0;
            n8_meta_q <= '0;


            n4_sign_q <= 1'b0;
            n4_exp_q  <= '0;
            n4_sig_q  <= '0;
            n4_done_q <= 1'b0;
            n4_zero_q <= 1'b1;
            n4_special_q <= 1'b0;
            n4_special_result_q <= '0;
            n4_special_invalid_q <= 1'b0;
            n4_meta_q <= '0;


            n2_sign_q <= 1'b0;
            n2_exp_q  <= '0;
            n2_sig_q  <= '0;
            n2_done_q <= 1'b0;
            n1_shift_q <= 1'b0;
            n2_zero_q <= 1'b1;
            n2_special_q <= 1'b0;
            n2_special_result_q <= '0;
            n2_special_invalid_q <= 1'b0;
            n2_meta_q <= '0;


            n1_sign_q <= 1'b0;
            n1_exp_q  <= '0;
            n1_sig_q  <= '0;
            n1_zero_q <= 1'b1;
            n1_subnormal_q <= 1'b0;
            n1_special_q <= 1'b0;
            n1_special_result_q <= '0;
            n1_special_invalid_q <= 1'b0;
            n1_meta_q <= '0;


            r0_sign_q <= 1'b0;
            r0_exp_q <= '0;
            r0_retained_q <= '0;
            r0_round_inc_q <= 1'b0;
            r0_discarded_q <= 1'b0;
            r0_zero_q <= 1'b1;
            r0_subnormal_q <= 1'b0;
            r0_special_q <= 1'b0;
            r0_special_result_q <= '0;
            r0_special_invalid_q <= 1'b0;
            r0_meta_q <= '0;


            result_o <= '0;
            invalid_o <= 1'b0;
            overflow_o <= 1'b0;
            underflow_o <= 1'b0;
            inexact_o <= 1'b0;
            meta_o <= '0;

        end

        else begin

            // ------------------------------------------------------------
            // Valid pipeline.
            // clear kills validity only.
            // ------------------------------------------------------------

            if (clear_i) begin

                c0_valid_q <= 1'b0;
                c1_valid_q <= 1'b0;
                c2_valid_q <= 1'b0;
                c3_valid_q <= 1'b0;

                n0_valid_q  <= 1'b0;
                n16_valid_q <= 1'b0;
                n8_valid_q  <= 1'b0;
                n4_valid_q  <= 1'b0;
                n2_valid_q  <= 1'b0;
                n1_valid_q  <= 1'b0;

                r0_valid_q <= 1'b0;

                out_valid_o <= 1'b0;

            end

            else begin

                c0_valid_q <= align_valid;
                c1_valid_q <= c0_valid_q;
                c2_valid_q <= c1_valid_q;
                c3_valid_q <= c2_valid_q;

                n0_valid_q  <= c3_valid_q;
                n16_valid_q <= n0_valid_q;
                n8_valid_q  <= n16_valid_q;
                n4_valid_q  <= n8_valid_q;
                n2_valid_q <= n2p_valid_q;
                n1_valid_q  <= n2_valid_q;

                r0_valid_q <= n1_valid_q;

                out_valid_o <= r1_valid_q;

            end


            // ============================================================
            // C0
            // ============================================================

            c0_low_q   <= c0_sum[6:0];
            c0_carry_q <= c0_sum[7];

            c0_a_hi_q <= add_a[27:7];
            c0_b_hi_q <= add_b[27:7];

            c0_sub_q  <= align_subtract;
            c0_sign_q <= align_sign;
            c0_exp_q  <= align_exp;

            c0_special_q <= align_special;
            c0_special_result_q <= align_special_result;
            c0_special_invalid_q <= align_special_invalid;

            c0_meta_q <= align_meta;


            // ============================================================
            // C1
            // ============================================================

            c1_low_q <= {
                c1_sum[6:0],
                c0_low_q
            };

            c1_carry_q <= c1_sum[7];

            c1_a_hi_q <= c0_a_hi_q[20:7];
            c1_b_hi_q <= c0_b_hi_q[20:7];

            c1_sub_q  <= c0_sub_q;
            c1_sign_q <= c0_sign_q;
            c1_exp_q  <= c0_exp_q;

            c1_special_q <= c0_special_q;
            c1_special_result_q <= c0_special_result_q;
            c1_special_invalid_q <= c0_special_invalid_q;

            c1_meta_q <= c0_meta_q;


            // ============================================================
            // C2
            // ============================================================

            c2_low_q <= {
                c2_sum[6:0],
                c1_low_q
            };

            c2_carry_q <= c2_sum[7];

            c2_a_hi_q <= c1_a_hi_q[13:7];
            c2_b_hi_q <= c1_b_hi_q[13:7];

            c2_sub_q  <= c1_sub_q;
            c2_sign_q <= c1_sign_q;
            c2_exp_q  <= c1_exp_q;

            c2_special_q <= c1_special_q;
            c2_special_result_q <= c1_special_result_q;
            c2_special_invalid_q <= c1_special_invalid_q;

            c2_meta_q <= c1_meta_q;


            // ============================================================
            // C3
            // ============================================================

            c3_sig_q <=
                raw_sig_c;

            c3_zero_q <=
                raw_zero_c;

            c3_sign_q <=
                raw_zero_c
                ? 1'b0
                : c2_sign_q;

            c3_exp_q <=
                c2_exp_q;

            c3_special_q <=
                c2_special_q;

            c3_special_result_q <=
                c2_special_result_q;

            c3_special_invalid_q <=
                c2_special_invalid_q;

            c3_meta_q <=
                c2_meta_q;


            // ============================================================
            // N0 : handle addition carry.
            // ============================================================

            n0_sign_q <=
                c3_zero_q
                ? 1'b0
                : c3_sign_q;

            n0_zero_q <=
                c3_zero_q;

            if (c3_zero_q) begin

                n0_sig_q <=
                    27'd0;

                n0_exp_q <=
                    8'd0;

                n0_done_q <=
                    1'b1;

            end

            else if (c3_sig_q[27]) begin

                n0_sig_q <= {
                    c3_sig_q[27:2],
                    c3_sig_q[1] |
                    c3_sig_q[0]
                };

                n0_exp_q <=
                    (c3_exp_q == 8'hff)
                    ? 8'hff
                    : c3_exp_q + 8'd1;

                n0_done_q <=
                    1'b1;

            end

            else begin

                n0_sig_q <=
                    c3_sig_q[26:0];

                n0_exp_q <=
                    c3_exp_q;

                n0_done_q <=
                    1'b0;

            end

            n0_special_q <=
                c3_special_q;

            n0_special_result_q <=
                c3_special_result_q;

            n0_special_invalid_q <=
                c3_special_invalid_q;

            n0_meta_q <=
                c3_meta_q;


            // ============================================================
            // N16
            // ============================================================

            n16_sign_q <= n0_sign_q;
            n16_zero_q <= n0_zero_q;
            n16_done_q <= n0_done_q;

            if (n16_shift) begin

                n16_sig_q <= {
                    n0_sig_q[10:0],
                    16'd0
                };

                n16_exp_q <=
                    n0_exp_q - 8'd16;

            end

            else begin

                n16_sig_q <=
                    n0_sig_q;

                n16_exp_q <=
                    n0_exp_q;

            end

            n16_special_q <= n0_special_q;
            n16_special_result_q <= n0_special_result_q;
            n16_special_invalid_q <= n0_special_invalid_q;
            n16_meta_q <= n0_meta_q;


            // ============================================================
            // N8
            // ============================================================

            n8_sign_q <= n16_sign_q;
            n8_zero_q <= n16_zero_q;
            n8_done_q <= n16_done_q;

            if (n8_shift) begin

                n8_sig_q <= {
                    n16_sig_q[18:0],
                    8'd0
                };

                n8_exp_q <=
                    n16_exp_q - 8'd8;

            end

            else begin

                n8_sig_q <=
                    n16_sig_q;

                n8_exp_q <=
                    n16_exp_q;

            end

            n8_special_q <= n16_special_q;
            n8_special_result_q <= n16_special_result_q;
            n8_special_invalid_q <= n16_special_invalid_q;
            n8_meta_q <= n16_meta_q;


            // ============================================================
            // N4
            // ============================================================

            n4_sign_q <= n8_sign_q;
            n4_zero_q <= n8_zero_q;
            n4_done_q <= n8_done_q;

            if (n4_shift) begin

                n4_sig_q <= {
                    n8_sig_q[22:0],
                    4'd0
                };

                n4_exp_q <=
                    n8_exp_q - 8'd4;

            end

            else begin

                n4_sig_q <=
                    n8_sig_q;

                n4_exp_q <=
                    n8_exp_q;

            end

            n4_special_q <= n8_special_q;
            n4_special_result_q <= n8_special_result_q;
            n4_special_invalid_q <= n8_special_invalid_q;
            n4_meta_q <= n8_meta_q;


            // ============================================================
            // N2
            // ============================================================

            // N2: apply the registered shift decision.
            n2_sign_q <= n2p_sign_q;
            n2_zero_q <= n2p_zero_q;
            n2_done_q <= n2p_done_q;
            n1_shift_q <=
                !n2p_done_q &&
                (n2p_shift_q ? (n2p_exp_minus2_q > 8'd1)
                             : (n2p_exp_q > 8'd1)) &&
                !(n2p_shift_q ? n2p_sig_q[24] : n2p_sig_q[26]);
            n2_sig_q <= n2p_shift_q
                ? {n2p_sig_q[24:0], 2'b00} : n2p_sig_q;
            n2_exp_q <= n2p_shift_q ? n2p_exp_minus2_q : n2p_exp_q;
            n2_special_q <= n2p_special_q;
            n2_special_result_q <= n2p_special_result_q;
            n2_special_invalid_q <= n2p_special_invalid_q;
            n2_meta_q <= n2p_meta_q;


            // ============================================================
            // N1
            // ============================================================

            n1_sign_q <=
                n2_sign_q;

            n1_zero_q <=
                n2_zero_q;

            if (n1_shift) begin

                n1_sig_q <= {
                    n2_sig_q[25:0],
                    1'b0
                };

                n1_exp_q <=
                    n2_exp_q - 8'd1;

                n1_subnormal_q <=
                    ((n2_exp_q - 8'd1) == 8'd1) &&
                    !n2_sig_q[25];

            end

            else begin

                n1_sig_q <=
                    n2_sig_q;

                n1_exp_q <=
                    n2_exp_q;

                n1_subnormal_q <=
                    (n2_exp_q == 8'd1) &&
                    !n2_sig_q[26];

            end

            n1_special_q <= n2_special_q;
            n1_special_result_q <= n2_special_result_q;
            n1_special_invalid_q <= n2_special_invalid_q;
            n1_meta_q <= n2_meta_q;


            // ============================================================
            // R0 : rounding decision.
            // ============================================================

            r0_sign_q <=
                n1_sign_q;

            r0_exp_q <=
                n1_exp_q;

            r0_retained_q <=
                n1_sig_q[26:3];

            r0_discarded_q <=
                n1_sig_q[2] |
                n1_sig_q[1] |
                n1_sig_q[0];

            r0_round_inc_q <=
                n1_sig_q[2] &&
                (
                    n1_sig_q[1] ||
                    n1_sig_q[0] ||
                    n1_sig_q[3]
                );

            r0_zero_q <=
                n1_zero_q;

            r0_subnormal_q <=
                n1_subnormal_q;

            r0_special_q <=
                n1_special_q;

            r0_special_result_q <=
                n1_special_result_q;

            r0_special_invalid_q <=
                n1_special_invalid_q;

            r0_meta_q <=
                n1_meta_q;


            // ============================================================
            // FINAL PACK REGISTER
            // ============================================================

            result_o <=
                packed_result_c;

            invalid_o <=
                packed_invalid_c;

            overflow_o <=
                packed_overflow_c;

            underflow_o <=
                packed_underflow_c;

            inexact_o <=
                packed_inexact_c;

            meta_o <= r1_meta_q;

        end

    end


`ifndef SYNTHESIS

    always_ff @(posedge clk_i) begin

        if (
            rst_ni &&
            out_valid_o &&
            !out_ready_i
        ) begin

            $fatal(
                1,
                "nce_fp32_product_sum_500mhz output stalled"
            );

        end

    end

`endif


endmodule

`default_nettype wire
