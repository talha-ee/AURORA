`timescale 1ns/1ps
`default_nettype none

module nce_fp32_align_pipeline_500mhz #(
    parameter integer META_W = 4
)(
    input  logic                 clk_i,
    input  logic                 rst_ni,
    input  logic                 clear_i,

    input  logic                 in_valid_i,
    input  logic [31:0]          a_i,
    input  logic [31:0]          b_i,
    input  logic [META_W-1:0]    meta_i,

    output logic                 out_valid_o,

    output logic                 large_sign_o,
    output logic                 subtract_o,
    output logic [7:0]           common_exponent_o,
    output logic [26:0]          large_significand_o,
    output logic [26:0]          small_significand_o,

    output logic                 special_handled_o,
    output logic [31:0]          special_result_o,
    output logic                 special_invalid_o,

    output logic [META_W-1:0]    meta_o
);

    // ================================================================
    // Input decode / special handling
    // ================================================================

    logic special_c;
    logic [31:0] special_result_c;
    logic special_invalid_c;

    logic a_sign_c;
    logic [7:0] a_exp_c;
    logic [23:0] a_sig_c;

    logic b_sign_c;
    logic [7:0] b_exp_c;
    logic [23:0] b_sig_c;

    nce_fp32_add_special u_special (
        .a_i(a_i),
        .b_i(b_i),
        .handled_o(special_c),
        .result_o(special_result_c),
        .invalid_o(special_invalid_c)
    );

    nce_fp32_decode u_decode_a (
        .fp_i(a_i),
        .sign_o(a_sign_c),
        .exponent_o(a_exp_c),
        .fraction_o(),
        .significand_o(a_sig_c),
        .is_zero_o(),
        .is_subnormal_o(),
        .is_normal_o(),
        .is_infinity_o(),
        .is_nan_o(),
        .is_quiet_nan_o(),
        .is_signaling_nan_o()
    );

    nce_fp32_decode u_decode_b (
        .fp_i(b_i),
        .sign_o(b_sign_c),
        .exponent_o(b_exp_c),
        .fraction_o(),
        .significand_o(b_sig_c),
        .is_zero_o(),
        .is_subnormal_o(),
        .is_normal_o(),
        .is_infinity_o(),
        .is_nan_o(),
        .is_quiet_nan_o(),
        .is_signaling_nan_o()
    );


    // ================================================================
    // F0
    // ================================================================

    logic f0_a_sign_q;
    logic [7:0] f0_a_exp_q;
    logic [23:0] f0_a_sig_q;

    logic f0_b_sign_q;
    logic [7:0] f0_b_exp_q;
    logic [23:0] f0_b_sig_q;

    logic f0_special_q;
    logic [31:0] f0_special_result_q;
    logic f0_special_invalid_q;
    logic [META_W-1:0] f0_meta_q;


    // ================================================================
    // F0 -> F0.5 : comparison only
    //
    // This stage performs only exponent/significand comparison.
    // Selection, exponent subtraction and >=27 detection are moved
    // behind a new register boundary.
    // ================================================================

    wire [7:0] a_eff =
        (f0_a_exp_q == 8'd0) ? 8'd1 : f0_a_exp_q;

    wire [7:0] b_eff =
        (f0_b_exp_q == 8'd0) ? 8'd1 : f0_b_exp_q;

    wire exp_gt = a_eff > b_eff;
    wire exp_eq = a_eff == b_eff;


    // Hierarchical 24-bit significand comparison.
    // Balanced 3-bit comparisons: 8 -> 4 -> 2 -> 1.
    wire [7:0] sigcmp_eq0, sigcmp_gt0;
    wire [3:0] sigcmp_eq1, sigcmp_gt1;
    wire [1:0] sigcmp_eq2, sigcmp_gt2;
    wire sigcmp_eq3, sigcmp_gt3;

    genvar sc;
    generate
        for (sc = 0; sc < 8; sc = sc + 1) begin : GEN_SIGCMP3_LEAF
            assign sigcmp_eq0[sc] =
                f0_a_sig_q[sc*3 +: 3] == f0_b_sig_q[sc*3 +: 3];
            assign sigcmp_gt0[sc] =
                f0_a_sig_q[sc*3 +: 3] > f0_b_sig_q[sc*3 +: 3];
        end

        for (sc = 0; sc < 4; sc = sc + 1) begin : GEN_SIGCMP3_PAIR
            assign sigcmp_eq1[sc] =
                sigcmp_eq0[2*sc+1] & sigcmp_eq0[2*sc];
            assign sigcmp_gt1[sc] =
                sigcmp_gt0[2*sc+1] |
                (sigcmp_eq0[2*sc+1] & sigcmp_gt0[2*sc]);
        end

        for (sc = 0; sc < 2; sc = sc + 1) begin : GEN_SIGCMP3_HALF
            assign sigcmp_eq2[sc] =
                sigcmp_eq1[2*sc+1] & sigcmp_eq1[2*sc];
            assign sigcmp_gt2[sc] =
                sigcmp_gt1[2*sc+1] |
                (sigcmp_eq1[2*sc+1] & sigcmp_gt1[2*sc]);
        end
    endgenerate

    assign sigcmp_eq3 = sigcmp_eq2[1] & sigcmp_eq2[0];
    assign sigcmp_gt3 =
        sigcmp_gt2[1] | (sigcmp_eq2[1] & sigcmp_gt2[0]);

    wire sig_a_ge_b = sigcmp_gt3 | sigcmp_eq3;


    // ================================================================
    // F0.5 registers
    // ================================================================

    logic f05_order_q;
    logic f05_a_nonzero_q, f05_b_nonzero_q;

    logic [7:0] f05_a_eff_q;
    logic [7:0] f05_b_eff_q;

    logic       f05_a_sign_q;
    logic       f05_b_sign_q;

    logic [23:0] f05_a_sig_q;
    logic [23:0] f05_b_sig_q;

    logic        f05_special_q;
    logic [31:0] f05_special_result_q;
    logic        f05_special_invalid_q;
    logic [META_W-1:0] f05_meta_q;


    // ================================================================
    // F0.5 -> F1 : ordering + exponent difference
    // ================================================================

    wire a_is_large = f05_order_q;


    // F0 -> F0.5: independent 4-bit subtraction candidates.
    logic [4:0] f05_ed_ab_lo_q, f05_ed_ba_lo_q;
    logic [3:0] f05_ed_ab_hi0_q, f05_ed_ab_hi1_q;
    logic [3:0] f05_ed_ba_hi0_q, f05_ed_ba_hi1_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            f05_ed_ab_lo_q  <= 5'd0;
            f05_ed_ba_lo_q  <= 5'd0;
            f05_ed_ab_hi0_q <= 4'd0;
            f05_ed_ab_hi1_q <= 4'hf;
            f05_ed_ba_hi0_q <= 4'd0;
            f05_ed_ba_hi1_q <= 4'hf;
        end else begin
            f05_ed_ab_lo_q <=
                {1'b0, a_eff[3:0]} - {1'b0, b_eff[3:0]};
            f05_ed_ba_lo_q <=
                {1'b0, b_eff[3:0]} - {1'b0, a_eff[3:0]};

            f05_ed_ab_hi0_q <= a_eff[7:4] - b_eff[7:4];
            f05_ed_ab_hi1_q <= a_eff[7:4] + (~b_eff[7:4]);

            f05_ed_ba_hi0_q <= b_eff[7:4] - a_eff[7:4];
            f05_ed_ba_hi1_q <= b_eff[7:4] + (~a_eff[7:4]);
        end
    end

    // F0.5 -> F1: select the upper nibble using registered borrow.
    wire [3:0] ed_ab_hi_c =
        f05_ed_ab_lo_q[4] ? f05_ed_ab_hi1_q : f05_ed_ab_hi0_q;
    wire [3:0] ed_ba_hi_c =
        f05_ed_ba_lo_q[4] ? f05_ed_ba_hi1_q : f05_ed_ba_hi0_q;

    wire [7:0] ed_ab_c = {ed_ab_hi_c, f05_ed_ab_lo_q[3:0]};
    wire [7:0] ed_ba_c = {ed_ba_hi_c, f05_ed_ba_lo_q[3:0]};

    wire [7:0] exponent_difference_c =
        a_is_large ? ed_ab_c : ed_ba_c;


    wire [23:0] large_sig_raw_c =
        a_is_large
        ? f05_a_sig_q
        : f05_b_sig_q;


    wire [23:0] small_sig_raw_c =
        a_is_large
        ? f05_b_sig_q
        : f05_a_sig_q;


    wire large_sign_c =
        a_is_large
        ? f05_a_sign_q
        : f05_b_sign_q;


    wire small_sign_c =
        a_is_large
        ? f05_b_sign_q
        : f05_a_sign_q;


    wire subtract_c =
        large_sign_c ^
        small_sign_c;


    wire [7:0] common_exp_c =
        a_is_large
        ? f05_a_eff_q
        : f05_b_eff_q;


    // ================================================================
    // F1 : order + exponent difference
    // ================================================================

    logic f1_large_sign_q;
    logic f1_subtract_q;
    logic [7:0] f1_exp_q;

    logic [26:0] f1_large_q;
    logic [26:0] f1_small_q;

    logic [4:0] f1_shift_q;
    logic [7:0] f1_diff_q;
    logic f1_small_nonzero_q;

    logic f1_special_q;
    logic [31:0] f1_special_result_q;
    logic f1_special_invalid_q;
    logic [META_W-1:0] f1_meta_q;


    // ================================================================
    // Fixed-distance JAM stages
    // ================================================================

    function automatic [26:0] jam16(input [26:0] v);
        begin
            jam16 = {16'd0, v[26:16]};
            jam16[0] = jam16[0] | (|v[15:0]);
        end
    endfunction

    function automatic [26:0] jam8(input [26:0] v);
        begin
            jam8 = {8'd0, v[26:8]};
            jam8[0] = jam8[0] | (|v[7:0]);
        end
    endfunction

    function automatic [26:0] jam4(input [26:0] v);
        begin
            jam4 = {4'd0, v[26:4]};
            jam4[0] = jam4[0] | (|v[3:0]);
        end
    endfunction

    function automatic [26:0] jam2(input [26:0] v);
        begin
            jam2 = {2'd0, v[26:2]};
            jam2[0] = jam2[0] | (|v[1:0]);
        end
    endfunction

    function automatic [26:0] jam1(input [26:0] v);
        begin
            jam1 = {1'b0, v[26:1]};
            jam1[0] = jam1[0] | v[0];
        end
    endfunction


    // Shift-pipeline payloads.
    logic [26:0] f2_large_q, f2_small_q;
    logic [26:0] f3_large_q, f3_small_q;
    logic [26:0] f4_large_q, f4_small_q;
    logic [26:0] f5_large_q, f5_small_q;
    logic [26:0] f6_large_q, f6_small_q;

    logic [4:0] f2_shift_q, f3_shift_q, f4_shift_q, f5_shift_q;

    logic f2_ge27_q, f3_ge27_q, f4_ge27_q, f5_ge27_q;
    logic f2_nonzero_q, f3_nonzero_q, f4_nonzero_q, f5_nonzero_q;

    logic f2_sign_q, f3_sign_q, f4_sign_q, f5_sign_q, f6_sign_q;
    logic f2_sub_q,  f3_sub_q,  f4_sub_q,  f5_sub_q,  f6_sub_q;

    logic [7:0] f2_exp_q, f3_exp_q, f4_exp_q, f5_exp_q, f6_exp_q;

    logic f2_special_q, f3_special_q, f4_special_q, f5_special_q, f6_special_q;
    logic [31:0] f2_special_result_q, f3_special_result_q;
    logic [31:0] f4_special_result_q, f5_special_result_q, f6_special_result_q;

    logic f2_special_invalid_q, f3_special_invalid_q;
    logic f4_special_invalid_q, f5_special_invalid_q, f6_special_invalid_q;

    logic [META_W-1:0] f2_meta_q, f3_meta_q, f4_meta_q;
    logic [META_W-1:0] f5_meta_q, f6_meta_q;


    // ================================================================
    // Valid pipeline
    // ================================================================

    logic [7:0] valid_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            valid_q <= 8'd0;
        else if (clear_i)
            valid_q <= 8'd0;
        else begin
            valid_q[0] <= in_valid_i;
            valid_q[1] <= valid_q[0];
            valid_q[2] <= valid_q[1];
            valid_q[3] <= valid_q[2];
            valid_q[4] <= valid_q[3];
            valid_q[5] <= valid_q[4];
            valid_q[6] <= valid_q[5];
            valid_q[7] <= valid_q[6];
        end
    end

    assign out_valid_o = valid_q[7];


    // ================================================================
    // Datapath
    // ================================================================

    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni) begin

            f0_a_sign_q <= 1'b0;
            f0_a_exp_q  <= 8'd0;
            f0_a_sig_q  <= 24'd0;
            f0_b_sign_q <= 1'b0;
            f0_b_exp_q  <= 8'd0;
            f0_b_sig_q  <= 24'd0;

            f0_special_q         <= 1'b0;
            f0_special_result_q  <= 32'd0;
            f0_special_invalid_q <= 1'b0;
            f0_meta_q            <= '0;

            f05_order_q     <= 1'b0;
            f05_a_nonzero_q <= 1'b0;
            f05_b_nonzero_q <= 1'b0;

            f05_a_eff_q        <= 8'd0;
            f05_b_eff_q        <= 8'd0;

            f05_a_sign_q       <= 1'b0;
            f05_b_sign_q       <= 1'b0;

            f05_a_sig_q        <= 24'd0;
            f05_b_sig_q        <= 24'd0;

            f05_special_q         <= 1'b0;
            f05_special_result_q  <= 32'd0;
            f05_special_invalid_q <= 1'b0;
            f05_meta_q            <= '0;

            f1_large_sign_q <= 1'b0;
            f1_subtract_q   <= 1'b0;
            f1_exp_q        <= 8'd0;
            f1_large_q      <= 27'd0;
            f1_small_q      <= 27'd0;
            f1_shift_q      <= 5'd0;
            f1_diff_q <= 8'd0;
            f1_small_nonzero_q <= 1'b0;

            f1_special_q         <= 1'b0;
            f1_special_result_q  <= 32'd0;
            f1_special_invalid_q <= 1'b0;
            f1_meta_q            <= '0;

            f2_large_q <= 27'd0; f2_small_q <= 27'd0;
            f3_large_q <= 27'd0; f3_small_q <= 27'd0;
            f4_large_q <= 27'd0; f4_small_q <= 27'd0;
            f5_large_q <= 27'd0; f5_small_q <= 27'd0;
            f6_large_q <= 27'd0; f6_small_q <= 27'd0;

            f2_shift_q <= 5'd0; f3_shift_q <= 5'd0;
            f4_shift_q <= 5'd0; f5_shift_q <= 5'd0;

            f2_ge27_q <= 1'b0; f3_ge27_q <= 1'b0;
            f4_ge27_q <= 1'b0; f5_ge27_q <= 1'b0;

            f2_nonzero_q <= 1'b0; f3_nonzero_q <= 1'b0;
            f4_nonzero_q <= 1'b0; f5_nonzero_q <= 1'b0;

            f2_sign_q <= 1'b0; f3_sign_q <= 1'b0;
            f4_sign_q <= 1'b0; f5_sign_q <= 1'b0; f6_sign_q <= 1'b0;

            f2_sub_q <= 1'b0; f3_sub_q <= 1'b0;
            f4_sub_q <= 1'b0; f5_sub_q <= 1'b0; f6_sub_q <= 1'b0;

            f2_exp_q <= 8'd0; f3_exp_q <= 8'd0;
            f4_exp_q <= 8'd0; f5_exp_q <= 8'd0; f6_exp_q <= 8'd0;

            f2_special_q <= 1'b0; f3_special_q <= 1'b0;
            f4_special_q <= 1'b0; f5_special_q <= 1'b0; f6_special_q <= 1'b0;

            f2_special_result_q <= 32'd0;
            f3_special_result_q <= 32'd0;
            f4_special_result_q <= 32'd0;
            f5_special_result_q <= 32'd0;
            f6_special_result_q <= 32'd0;

            f2_special_invalid_q <= 1'b0;
            f3_special_invalid_q <= 1'b0;
            f4_special_invalid_q <= 1'b0;
            f5_special_invalid_q <= 1'b0;
            f6_special_invalid_q <= 1'b0;

            f2_meta_q <= '0; f3_meta_q <= '0;
            f4_meta_q <= '0; f5_meta_q <= '0; f6_meta_q <= '0;

        end
        else begin

            // F0
            f0_a_sign_q <= a_sign_c;
            f0_a_exp_q  <= a_exp_c;
            f0_a_sig_q  <= a_sig_c;

            f0_b_sign_q <= b_sign_c;
            f0_b_exp_q  <= b_exp_c;
            f0_b_sig_q  <= b_sig_c;

            f0_special_q         <= special_c;
            f0_special_result_q  <= special_result_c;
            f0_special_invalid_q <= special_invalid_c;
            f0_meta_q            <= meta_i;


            // F0.5 : comparison boundary
            f05_order_q <= exp_gt | (exp_eq & sig_a_ge_b);
            f05_a_nonzero_q <= |f0_a_sig_q;
            f05_b_nonzero_q <= |f0_b_sig_q;

            f05_a_eff_q        <= a_eff;
            f05_b_eff_q        <= b_eff;

            f05_a_sign_q       <= f0_a_sign_q;
            f05_b_sign_q       <= f0_b_sign_q;

            f05_a_sig_q        <= f0_a_sig_q;
            f05_b_sig_q        <= f0_b_sig_q;

            f05_special_q         <= f0_special_q;
            f05_special_result_q  <= f0_special_result_q;
            f05_special_invalid_q <= f0_special_invalid_q;
            f05_meta_q            <= f0_meta_q;


            // F1 : ordering / exponent difference
            f1_large_sign_q <= large_sign_c;
            f1_subtract_q   <= subtract_c;
            f1_exp_q        <= common_exp_c;

            f1_large_q <= {large_sig_raw_c, 3'b000};
            f1_small_q <= {small_sig_raw_c, 3'b000};

            f1_shift_q <= exponent_difference_c[4:0];

            f1_diff_q <= exponent_difference_c;

            f1_small_nonzero_q <=
                a_is_large ? f05_b_nonzero_q : f05_a_nonzero_q;

            f1_special_q         <= f05_special_q;
            f1_special_result_q  <= f05_special_result_q;
            f1_special_invalid_q <= f05_special_invalid_q;
            f1_meta_q            <= f05_meta_q;


            // F2 : shift 16
            f2_large_q <= f1_large_q;
            f2_small_q <=
                f1_shift_q[4]
                ? jam16(f1_small_q)
                : f1_small_q;

            f2_shift_q <= f1_shift_q;
            f2_ge27_q <= (f1_diff_q >= 8'd27);
            f2_nonzero_q <= f1_small_nonzero_q;
            f2_sign_q <= f1_large_sign_q;
            f2_sub_q  <= f1_subtract_q;
            f2_exp_q  <= f1_exp_q;

            f2_special_q <= f1_special_q;
            f2_special_result_q <= f1_special_result_q;
            f2_special_invalid_q <= f1_special_invalid_q;
            f2_meta_q <= f1_meta_q;


            // F3 : shift 8
            f3_large_q <= f2_large_q;
            f3_small_q <=
                f2_shift_q[3]
                ? jam8(f2_small_q)
                : f2_small_q;

            f3_shift_q <= f2_shift_q;
            f3_ge27_q  <= f2_ge27_q;
            f3_nonzero_q <= f2_nonzero_q;
            f3_sign_q <= f2_sign_q;
            f3_sub_q  <= f2_sub_q;
            f3_exp_q  <= f2_exp_q;

            f3_special_q <= f2_special_q;
            f3_special_result_q <= f2_special_result_q;
            f3_special_invalid_q <= f2_special_invalid_q;
            f3_meta_q <= f2_meta_q;


            // F4 : shift 4
            f4_large_q <= f3_large_q;
            f4_small_q <=
                f3_shift_q[2]
                ? jam4(f3_small_q)
                : f3_small_q;

            f4_shift_q <= f3_shift_q;
            f4_ge27_q  <= f3_ge27_q;
            f4_nonzero_q <= f3_nonzero_q;
            f4_sign_q <= f3_sign_q;
            f4_sub_q  <= f3_sub_q;
            f4_exp_q  <= f3_exp_q;

            f4_special_q <= f3_special_q;
            f4_special_result_q <= f3_special_result_q;
            f4_special_invalid_q <= f3_special_invalid_q;
            f4_meta_q <= f3_meta_q;


            // F5 : shift 2
            f5_large_q <= f4_large_q;
            f5_small_q <=
                f4_shift_q[1]
                ? jam2(f4_small_q)
                : f4_small_q;

            f5_shift_q <= f4_shift_q;
            f5_ge27_q  <= f4_ge27_q;
            f5_nonzero_q <= f4_nonzero_q;
            f5_sign_q <= f4_sign_q;
            f5_sub_q  <= f4_sub_q;
            f5_exp_q  <= f4_exp_q;

            f5_special_q <= f4_special_q;
            f5_special_result_q <= f4_special_result_q;
            f5_special_invalid_q <= f4_special_invalid_q;
            f5_meta_q <= f4_meta_q;


            // F6 : shift 1 + >=27 saturation
            f6_large_q <= f5_large_q;

            if (f5_ge27_q)
                f6_small_q <= {26'd0, f5_nonzero_q};
            else if (f5_shift_q[0])
                f6_small_q <= jam1(f5_small_q);
            else
                f6_small_q <= f5_small_q;

            f6_sign_q <= f5_sign_q;
            f6_sub_q  <= f5_sub_q;
            f6_exp_q  <= f5_exp_q;

            f6_special_q <= f5_special_q;
            f6_special_result_q <= f5_special_result_q;
            f6_special_invalid_q <= f5_special_invalid_q;
            f6_meta_q <= f5_meta_q;

        end
    end


    assign large_sign_o          = f6_sign_q;
    assign subtract_o            = f6_sub_q;
    assign common_exponent_o     = f6_exp_q;

    assign large_significand_o   = f6_large_q;
    assign small_significand_o   = f6_small_q;

    assign special_handled_o     = f6_special_q;
    assign special_result_o      = f6_special_result_q;
    assign special_invalid_o     = f6_special_invalid_q;

    assign meta_o                = f6_meta_q;

endmodule

`default_nettype wire
