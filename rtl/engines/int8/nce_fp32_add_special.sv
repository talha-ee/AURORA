// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE)
//
// Original RTL Architect and Digital Designer: Talha Alam
// RTL Implementation and Verification: Talha Alam
// Initial Verified RTL Milestone: 2026
//
// This notice records the original technical authorship of this RTL.
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

// -----------------------------------------------------------------------------
// IEEE-754 binary32 addition special-case resolver.
//
// This stage resolves:
//   - Quiet and signaling NaNs
//   - Positive and negative infinity
//   - Infinity plus opposite infinity
//   - Positive and negative zero
//   - Zero plus a finite nonzero operand
//
// When handled_o is low, both operands are finite and nonzero and must proceed
// to the normal FP32 significand alignment and addition datapath.
//
// NaN policy:
//   1. Prefer signaling NaN A
//   2. Prefer signaling NaN B
//   3. Prefer quiet NaN A
//   4. Prefer quiet NaN B
//
// Any returned NaN is quieted.
// -----------------------------------------------------------------------------

module nce_fp32_add_special (
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,

    output logic        handled_o,
    output logic [31:0] result_o,
    output logic        invalid_o
);

    logic a_exp_all_ones;
    logic b_exp_all_ones;
    logic a_exp_zero;
    logic b_exp_zero;
    logic a_frac_zero;
    logic b_frac_zero;

    logic a_zero;
    logic b_zero;
    logic a_infinity;
    logic b_infinity;
    logic a_nan;
    logic b_nan;
    logic a_signaling_nan;
    logic b_signaling_nan;

    function automatic logic [31:0] quiet_nan (
        input logic        sign,
        input logic [21:0] payload
    );
        begin
            quiet_nan = {
                sign,
                8'hff,
                1'b1,
                payload
            };
        end
    endfunction

    assign a_exp_all_ones = (a_i[30:23] == 8'hff);
    assign b_exp_all_ones = (b_i[30:23] == 8'hff);

    assign a_exp_zero = (a_i[30:23] == 8'h00);
    assign b_exp_zero = (b_i[30:23] == 8'h00);

    assign a_frac_zero = (a_i[22:0] == 23'd0);
    assign b_frac_zero = (b_i[22:0] == 23'd0);

    assign a_zero = a_exp_zero && a_frac_zero;
    assign b_zero = b_exp_zero && b_frac_zero;

    assign a_infinity = a_exp_all_ones && a_frac_zero;
    assign b_infinity = b_exp_all_ones && b_frac_zero;

    assign a_nan = a_exp_all_ones && !a_frac_zero;
    assign b_nan = b_exp_all_ones && !b_frac_zero;

    assign a_signaling_nan = a_nan && !a_i[22];
    assign b_signaling_nan = b_nan && !b_i[22];

    
    // Parallel special-case selection; original NaN priority preserved.
    wire sp_nan_a =
        a_signaling_nan | (a_nan & ~b_signaling_nan);

    wire sp_nan_b =
        b_nan & ~a_signaling_nan & (b_signaling_nan | ~a_nan);

    wire sp_bad_inf =
        a_infinity & b_infinity & (a_i[31] ^ b_i[31]);

    wire sp_pass_a =
        (a_infinity & ~b_nan & ~sp_bad_inf) |
        (b_zero & ~a_zero & ~a_exp_all_ones);

    wire sp_pass_b =
        (b_infinity & ~a_exp_all_ones) |
        (a_zero & ~b_zero & ~b_exp_all_ones);

    wire sp_take_a = sp_nan_a | sp_pass_a;
    wire sp_take_b = sp_nan_b | sp_pass_b;

    wire sp_negative_zero =
        a_zero & b_zero & a_i[31] & b_i[31];

    assign handled_o =
    a_exp_all_ones | b_exp_all_ones | a_zero | b_zero;

    assign invalid_o =
        a_signaling_nan | b_signaling_nan | sp_bad_inf;

    // SPECIAL_FIELDS: separate sign, exponent, quiet bit and payload.
    assign result_o[31] =
        (a_i[31] & sp_take_a) |
        (b_i[31] & sp_take_b) |
        sp_negative_zero;

    assign result_o[30:23] =
        {8{a_exp_all_ones | b_exp_all_ones}} |
        (a_i[30:23] & {8{b_zero}}) |
        (b_i[30:23] & {8{a_zero}});

    assign result_o[22] =
        a_nan | b_nan | sp_bad_inf |
        (a_i[22] & b_zero) |
        (b_i[22] & a_zero);

    assign result_o[21:0] =
        (a_i[21:0] & {22{sp_nan_a | b_zero}}) |
        (b_i[21:0] & {22{sp_nan_b | a_zero}});

endmodule

`default_nettype wire
