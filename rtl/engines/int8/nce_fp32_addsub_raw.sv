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
// FP32 finite significand addition/subtraction stage.
//
// Inputs are ordered and aligned by nce_fp32_align.
//
// For equal signs:
//     large_significand + small_significand
//
// For different signs:
//     large_significand - small_significand
//
// Because the alignment stage orders operands by magnitude, subtraction
// cannot generate a negative result.
//
// The 28-bit output preserves the possible addition carry at bit 27.
// -----------------------------------------------------------------------------

module nce_fp32_addsub_raw (
    input  logic        large_sign_i,
    input  logic        subtract_i,
    input  logic [7:0]  common_exponent_i,

    input  logic [26:0] large_significand_i,
    input  logic [26:0] small_significand_i,

    output logic        result_sign_o,
    output logic [7:0]  exponent_o,
    output logic [27:0] significand_o,
    output logic        exact_zero_o
);

    logic [27:0] large_extended;
    logic [27:0] small_extended;
    logic [27:0] arithmetic_result;

    assign large_extended = {
        1'b0,
        large_significand_i
    };

    assign small_extended = {
        1'b0,
        small_significand_i
    };

    assign arithmetic_result =
        subtract_i
        ? (large_extended - small_extended)
        : (large_extended + small_extended);

    assign significand_o = arithmetic_result;
    assign exponent_o    = common_exponent_i;

    assign exact_zero_o =
        (arithmetic_result == 28'd0);

    // Exact cancellation produces +0 under round-to-nearest-even.
    assign result_sign_o =
        exact_zero_o
        ? 1'b0
        : large_sign_i;

endmodule

`default_nettype wire
