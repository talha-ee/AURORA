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
// IEEE-754 binary32 decoder and classifier.
//
// Format:
//   bit 31     : sign
//   bits 30:23 : exponent
//   bits 22:0  : fraction
//
// The significand output includes the hidden leading bit for normal values.
// -----------------------------------------------------------------------------

module nce_fp32_decode (
    input  logic [31:0] fp_i,

    output logic        sign_o,
    output logic [7:0]  exponent_o,
    output logic [22:0] fraction_o,
    output logic [23:0] significand_o,

    output logic is_zero_o,
    output logic is_subnormal_o,
    output logic is_normal_o,
    output logic is_infinity_o,
    output logic is_nan_o,
    output logic is_quiet_nan_o,
    output logic is_signaling_nan_o
);

    logic exponent_is_zero;
    logic exponent_is_ones;
    logic fraction_is_zero;

    assign sign_o     = fp_i[31];
    assign exponent_o = fp_i[30:23];
    assign fraction_o = fp_i[22:0];

    assign exponent_is_zero = (exponent_o == 8'h00);
    assign exponent_is_ones = (exponent_o == 8'hff);
    assign fraction_is_zero = (fraction_o == 23'd0);

    assign is_zero_o =
        exponent_is_zero &&
        fraction_is_zero;

    assign is_subnormal_o =
        exponent_is_zero &&
        !fraction_is_zero;

    assign is_normal_o =
        !exponent_is_zero &&
        !exponent_is_ones;

    assign is_infinity_o =
        exponent_is_ones &&
        fraction_is_zero;

    assign is_nan_o =
        exponent_is_ones &&
        !fraction_is_zero;

    // IEEE-754 uses the most-significant fraction bit to distinguish
    // quiet and signaling NaNs.
    assign is_quiet_nan_o =
        is_nan_o &&
        fraction_o[22];

    assign is_signaling_nan_o =
        is_nan_o &&
        !fraction_o[22];

    assign significand_o =
        is_normal_o    ? {1'b1, fraction_o} :
        is_subnormal_o ? {1'b0, fraction_o} :
                         24'd0;

endmodule

`default_nettype wire
