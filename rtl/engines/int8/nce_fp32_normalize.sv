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
// IEEE-754 binary32 normalization stage.
//
// Input significand format:
//   bit 27     : possible addition carry
//   bits 26:3  : main significand
//   bit 2      : guard
//   bit 1      : round
//   bit 0      : sticky
//
// Operations:
//   - Right-normalize an addition carry and jam discarded information.
//   - Left-normalize subtraction results.
//   - Stop left normalization at effective exponent 1.
//   - Identify subnormal and exact-zero results.
// -----------------------------------------------------------------------------

module nce_fp32_normalize (
    input  logic        result_sign_i,
    input  logic [7:0]  exponent_i,
    input  logic [27:0] significand_i,
    input  logic        exact_zero_i,

    output logic        result_sign_o,
    output logic [7:0]  exponent_o,
    output logic [26:0] significand_o,
    output logic        is_subnormal_o,
    output logic        exact_zero_o
);

    logic [4:0] leading_index;
    logic [4:0] desired_left_shift;
    logic [4:0] actual_left_shift;
    logic [7:0] exponent_room;

    function automatic logic [4:0] find_msb_index (
        input logic [26:1] value
    );
        begin
            if      (value[26]) find_msb_index = 5'd26;
            else if (value[25]) find_msb_index = 5'd25;
            else if (value[24]) find_msb_index = 5'd24;
            else if (value[23]) find_msb_index = 5'd23;
            else if (value[22]) find_msb_index = 5'd22;
            else if (value[21]) find_msb_index = 5'd21;
            else if (value[20]) find_msb_index = 5'd20;
            else if (value[19]) find_msb_index = 5'd19;
            else if (value[18]) find_msb_index = 5'd18;
            else if (value[17]) find_msb_index = 5'd17;
            else if (value[16]) find_msb_index = 5'd16;
            else if (value[15]) find_msb_index = 5'd15;
            else if (value[14]) find_msb_index = 5'd14;
            else if (value[13]) find_msb_index = 5'd13;
            else if (value[12]) find_msb_index = 5'd12;
            else if (value[11]) find_msb_index = 5'd11;
            else if (value[10]) find_msb_index = 5'd10;
            else if (value[9])  find_msb_index = 5'd9;
            else if (value[8])  find_msb_index = 5'd8;
            else if (value[7])  find_msb_index = 5'd7;
            else if (value[6])  find_msb_index = 5'd6;
            else if (value[5])  find_msb_index = 5'd5;
            else if (value[4])  find_msb_index = 5'd4;
            else if (value[3])  find_msb_index = 5'd3;
            else if (value[2])  find_msb_index = 5'd2;
            else if (value[1])  find_msb_index = 5'd1;
            else               find_msb_index = 5'd0;
        end
    endfunction

    function automatic logic [26:0] shift_right_one_jam (
        input logic [27:0] value
    );
        begin
            shift_right_one_jam = {
                value[27:2],
                value[1] | value[0]
            };
        end
    endfunction

    always @* begin
        result_sign_o      = 1'b0;
        exponent_o         = 8'd0;
        significand_o      = 27'd0;
        is_subnormal_o     = 1'b0;

        leading_index      = 5'd0;
        desired_left_shift = 5'd0;
        actual_left_shift  = 5'd0;
        exponent_room      = 8'd0;

        exact_zero_o =
            exact_zero_i ||
            (significand_i == 28'd0);

        if (!exact_zero_o) begin
            result_sign_o = result_sign_i;

            if (significand_i[27]) begin
                // Addition produced a carry. Shift right by one while
                // preserving discarded information in the sticky bit.
                significand_o =
                    shift_right_one_jam(significand_i);

                // Finite inputs can only reach exponent 255 here.
                if (exponent_i == 8'hff) begin
                    exponent_o = 8'hff;
                end
                else begin
                    exponent_o = exponent_i + 8'd1;
                end
            end
            else begin
                leading_index =
                    find_msb_index(significand_i[26:1]);

                desired_left_shift =
                    5'd26 - leading_index;

                // Effective exponent 1 is the lowest normalization boundary.
                if (exponent_i > 8'd1) begin
                    exponent_room =
                        exponent_i - 8'd1;
                end
                else begin
                    exponent_room = 8'd0;
                end

                if (
                    exponent_room >=
                    {3'd0, desired_left_shift}
                ) begin
                    actual_left_shift =
                        desired_left_shift;
                end
                else begin
                    actual_left_shift =
                        exponent_room[4:0];
                end

                significand_o =
                    significand_i[26:0]
                    << actual_left_shift;

                exponent_o =
                    exponent_i -
                    {3'd0, actual_left_shift};
            end

            // Effective exponent 1 with no hidden bit represents a subnormal.
            is_subnormal_o =
                (exponent_o == 8'd1) &&
                !significand_o[26];
        end
    end

endmodule

`default_nettype wire
