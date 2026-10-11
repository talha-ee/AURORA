`timescale 1ns/1ps
`default_nettype none


// ================================================================
// LOCAL 4-BIT CARRY-SAVE ACCUMULATOR SLICE
//
// add_valid_i only controls four local addend bits.
// The accumulator payload itself has NO valid/write-enable mux.
//
// When no DOT is valid:
//      addend_q = 0
//
// The CSA therefore preserves the numerical accumulator value.
// ================================================================
module ee_int8_csa_acc_slice (
    input  logic       clk_i,
    input  logic       rst_ni,
    input  logic       clear_i,

    input  logic       add_valid_i,
    input  logic [3:0] addend_i,

    input  logic       carry_in_i,

    output logic [3:0] sum_o,
    output logic [3:0] carry_o,

    output logic       maj_msb_o
);

    logic [3:0] addend_q;
    logic [3:0] sum_q;
    logic [3:0] carry_q;


    // ------------------------------------------------------------
    // Local addend register.
    //
    // Invalid cycles explicitly inject zero.
    // No accumulator write enable required.
    // ------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni)
            addend_q <= 4'b0000;

        else if (clear_i)
            addend_q <= 4'b0000;

        else if (add_valid_i)
            addend_q <= addend_i;

        else
            addend_q <= 4'b0000;

    end


    // ------------------------------------------------------------
    // Local 3:2 compressor
    // ------------------------------------------------------------

    wire [3:0] maj =
        (sum_q   & carry_q) |
        (sum_q   & addend_q) |
        (carry_q & addend_q);


    wire [3:0] next_sum =
        sum_q ^
        carry_q ^
        addend_q;


    // Carry-save carry is already shifted left by one.
    //
    // bit 0 receives majority from previous physical slice.
    // No ripple-carry propagation exists.
    wire [3:0] next_carry = {
        maj[2:0],
        carry_in_i
    };


    // ------------------------------------------------------------
    // Free-running accumulator payload
    // ------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni) begin

            sum_q   <= 4'b0000;
            carry_q <= 4'b0000;

        end

        else if (clear_i) begin

            sum_q   <= 4'b0000;
            carry_q <= 4'b0000;

        end

        else begin

            sum_q   <= next_sum;
            carry_q <= next_carry;

        end

    end


    // Carry from bit 3 becomes carry bit 0 of next slice.
    assign maj_msb_o =
        maj[3];


    assign sum_o =
        sum_q;

    assign carry_o =
        carry_q;

endmodule



// ================================================================
// INT8 PE
//
// LOCKED 500-MHz DOT4
//          |
//          v
//   8 x local 4-bit CSA accumulator slices
//
// No global accumulator payload enable.
// ================================================================
module ee_int8_pe_csa (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        clear_i,

    input  logic        in_valid_i,
    input  logic [31:0] lhs_i,
    input  logic [31:0] rhs_i,

    output logic        acc_update_o,
    output logic        acc_valid_o,

    output logic [31:0] acc_sum_o,
    output logic [31:0] acc_carry_o
);


    // ============================================================
    // LOCKED DOT4 LEAF
    // ============================================================

    logic               dot_valid;
    logic signed [17:0] dot;


    ee_int8_dot4_pipe u_dot4 (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .clear_i     (clear_i),

        .in_valid_i  (in_valid_i),
        .lhs_i       (lhs_i),
        .rhs_i       (rhs_i),

        .out_valid_o (dot_valid),
        .dot_o       (dot)
    );


    wire [31:0] dot_ext = {
        {14{dot[17]}},
        dot
    };


    // ============================================================
    // VALIDITY PIPELINE
    //
    // DOT is first captured into each local slice's addend_q.
    // One cycle later that addend is committed into the CSA state.
    // ============================================================

    logic add_valid_q;
    logic seen_q;


    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni) begin

            add_valid_q <= 1'b0;
            seen_q      <= 1'b0;

        end

        else if (clear_i) begin

            add_valid_q <= 1'b0;
            seen_q      <= 1'b0;

        end

        else begin

            add_valid_q <= dot_valid;

            if (add_valid_q)
                seen_q <= 1'b1;

        end

    end


    assign acc_update_o =
        add_valid_q;


    assign acc_valid_o =
        seen_q;


    // ============================================================
    // EIGHT PHYSICAL 4-BIT ACCUMULATOR SLICES
    // ============================================================

    wire [31:0] slice_sum;
    wire [31:0] slice_carry;

    wire [7:0] maj_msb;


    genvar g;

    generate

        for (
            g = 0;
            g < 8;
            g = g + 1
        ) begin : GEN_ACC_SLICE

            if (g == 0) begin : GEN_FIRST

                ee_int8_csa_acc_slice u_acc_slice (
                    .clk_i       (clk_i),
                    .rst_ni      (rst_ni),
                    .clear_i     (clear_i),

                    .add_valid_i (dot_valid),

                    .addend_i (
                        dot_ext[
                            g*4 +: 4
                        ]
                    ),

                    .carry_in_i  (1'b0),

                    .sum_o (
                        slice_sum[
                            g*4 +: 4
                        ]
                    ),

                    .carry_o (
                        slice_carry[
                            g*4 +: 4
                        ]
                    ),

                    .maj_msb_o (
                        maj_msb[g]
                    )
                );

            end

            else begin : GEN_NEXT

                ee_int8_csa_acc_slice u_acc_slice (
                    .clk_i       (clk_i),
                    .rst_ni      (rst_ni),
                    .clear_i     (clear_i),

                    .add_valid_i (dot_valid),

                    .addend_i (
                        dot_ext[
                            g*4 +: 4
                        ]
                    ),

                    .carry_in_i (
                        maj_msb[g-1]
                    ),

                    .sum_o (
                        slice_sum[
                            g*4 +: 4
                        ]
                    ),

                    .carry_o (
                        slice_carry[
                            g*4 +: 4
                        ]
                    ),

                    .maj_msb_o (
                        maj_msb[g]
                    )
                );

            end

        end

    endgenerate


    assign acc_sum_o =
        slice_sum;


    assign acc_carry_o =
        slice_carry;


endmodule

`default_nettype wire
