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
// IEEE-754 binary32 round-and-pack stage.
//
// Rounding mode:
//   Round to nearest, ties to even.
//
// Input significand format:
//   bits [26:3] : retained 24-bit significand
//   bit  [2]    : guard
//   bit  [1]    : round
//   bit  [0]    : sticky
//
// Exponent convention:
//   - Normal result: exponent_i is the encoded exponent field.
//   - Subnormal result: exponent_i is effective exponent 1.
//   - Exponent 255 indicates overflow from normalization.
//
// Underflow policy:
//   Tininess is detected after rounding.
// -----------------------------------------------------------------------------

module nce_fp32_round_pack (
    input  logic        result_sign_i,
    input  logic [7:0]  exponent_i,
    input  logic [26:0] significand_i,
    input  logic        is_subnormal_i,
    input  logic        exact_zero_i,

    output logic [31:0] fp32_o,
    output logic        inexact_o,
    output logic        overflow_o,
    output logic        underflow_o
);

    logic [23:0] retained_significand;
    logic        guard_bit;
    logic        round_bit;
    logic        sticky_bit;
    logic        discarded_nonzero;
    logic        round_increment;
    logic [24:0] rounded_significand;

    always @* begin
        retained_significand = significand_i[26:3];
        guard_bit            = significand_i[2];
        round_bit            = significand_i[1];
        sticky_bit           = significand_i[0];

        discarded_nonzero =
            guard_bit |
            round_bit |
            sticky_bit;

        // Round-to-nearest-even:
        // increment when greater than half, or exactly half with odd LSB.
        round_increment =
            guard_bit &&
            (
                round_bit ||
                sticky_bit ||
                retained_significand[0]
            );

        rounded_significand =
            {1'b0, retained_significand} +
            {24'd0, round_increment};

        fp32_o      = 32'h0000_0000;
        inexact_o   = 1'b0;
        overflow_o  = 1'b0;
        underflow_o = 1'b0;

        if (exact_zero_i) begin
            // Exact finite cancellation produces +0 in this arithmetic path.
            fp32_o = 32'h0000_0000;
        end
        else if (exponent_i >= 8'hff) begin
            // Finite arithmetic exceeded the largest representable exponent.
            fp32_o = {
                result_sign_i,
                8'hff,
                23'd0
            };

            inexact_o  = 1'b1;
            overflow_o = 1'b1;
        end
        else if (is_subnormal_i) begin
            inexact_o = discarded_nonzero;

            if (rounded_significand[23]) begin
                // Rounding promoted the largest subnormal to the
                // smallest normal value.
                fp32_o = {
                    result_sign_i,
                    8'h01,
                    rounded_significand[22:0]
                };
            end
            else begin
                fp32_o = {
                    result_sign_i,
                    8'h00,
                    rounded_significand[22:0]
                };

                // Tininess-after-rounding underflow definition.
                underflow_o = discarded_nonzero;
            end
        end
        else if (rounded_significand[24]) begin
            // Significand rounding generated an additional carry.
            if (exponent_i >= 8'hfe) begin
                fp32_o = {
                    result_sign_i,
                    8'hff,
                    23'd0
                };

                inexact_o  = 1'b1;
                overflow_o = 1'b1;
            end
            else begin
                fp32_o = {
                    result_sign_i,
                    exponent_i + 8'd1,
                    23'd0
                };

                inexact_o = discarded_nonzero;
            end
        end
        else begin
            fp32_o = {
                result_sign_i,
                exponent_i,
                rounded_significand[22:0]
            };

            inexact_o = discarded_nonzero;
        end
    end

endmodule

`default_nettype wire
