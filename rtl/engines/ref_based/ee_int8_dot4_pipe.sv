`timescale 1ns/1ps
`default_nettype none


// ============================================================================
// NVDLA-STYLE SIGNED INT8 MULTIPLIER FRONT-END
//
// Radix-4 Booth recoding
//      -> registered partial products
//      -> CSA
//      -> CSA
//      -> correction CSA
//
// Output remains in carry-save form.
//
// NO generic '*' operator.
// NO long carry-propagating multiplier chain.
// ============================================================================
module ee_int8_booth_csa_lane (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        clear_i,

    input  logic        in_valid_i,
    input  logic [7:0]  a_i,
    input  logic [7:0]  b_i,

    output logic        out_valid_o,
    output logic [17:0] row0_o,
    output logic [17:0] row1_o
);

    logic [4:0] valid_q;

    logic signed [7:0] a_q;
    logic        [7:0] b_q;


    // ----------------------------------------------------------------
    // Booth digit encoder.
    //
    // Return:
    //   [18]    : negate flag
    //   [17:0]  : magnitude before positional shift
    //
    // Negative Booth terms are represented as one's complement rows
    // plus correction bits. Therefore no carry-propagating negator is
    // placed in the multiplier critical path.
    // ----------------------------------------------------------------

    function automatic [18:0] booth_mag (
        input logic signed [7:0] x,
        input logic [2:0]        code
    );

        logic signed [17:0] sx;
        logic signed [17:0] mag;
        logic               neg;

        begin

            sx  = {{10{x[7]}}, x};

            mag = 18'sd0;
            neg = 1'b0;

            case (code)

                3'b000,
                3'b111: begin
                    mag = 18'sd0;
                    neg = 1'b0;
                end

                3'b001,
                3'b010: begin
                    mag = sx;
                    neg = 1'b0;
                end

                3'b011: begin
                    mag = sx <<< 1;
                    neg = 1'b0;
                end

                3'b100: begin
                    mag = sx <<< 1;
                    neg = 1'b1;
                end

                3'b101,
                3'b110: begin
                    mag = sx;
                    neg = 1'b1;
                end

                default: begin
                    mag = 18'sd0;
                    neg = 1'b0;
                end

            endcase

            booth_mag = {neg, mag};

        end

    endfunction


    // ----------------------------------------------------------------
    // Input register
    // ----------------------------------------------------------------

    // Input payload is free-running.
    //
    // in_valid_i controls only the valid pipeline.
    // This avoids a high-fanout operand-register enable when DOT4
    // is integrated inside a systolic PE.
    always_ff @(posedge clk_i) begin

        a_q <= $signed(a_i);
        b_q <= b_i;

    end


    // ----------------------------------------------------------------
    // Valid pipeline only.
    // Payload flops do not receive reset.
    // ----------------------------------------------------------------

    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni)
            valid_q <= 5'b0;

        else if (clear_i)
            valid_q <= 5'b0;

        else begin
            valid_q[0] <= in_valid_i;
            valid_q[1] <= valid_q[0];
            valid_q[2] <= valid_q[1];
            valid_q[3] <= valid_q[2];
            valid_q[4] <= valid_q[3];
        end

    end


    // ----------------------------------------------------------------
    // Radix-4 Booth groups
    // ----------------------------------------------------------------

    wire [18:0] enc0 =
        booth_mag(
            a_q,
            {b_q[1], b_q[0], 1'b0}
        );

    wire [18:0] enc1 =
        booth_mag(
            a_q,
            b_q[3:1]
        );

    wire [18:0] enc2 =
        booth_mag(
            a_q,
            b_q[5:3]
        );

    wire [18:0] enc3 =
        booth_mag(
            a_q,
            b_q[7:5]
        );


    wire [17:0] raw0 =
        enc0[17:0];

    wire [17:0] raw1 =
        enc1[17:0] << 2;

    wire [17:0] raw2 =
        enc2[17:0] << 4;

    wire [17:0] raw3 =
        enc3[17:0] << 6;


    wire [17:0] booth_row0 =
        enc0[18]
        ? ~raw0
        : raw0;

    wire [17:0] booth_row1 =
        enc1[18]
        ? ~raw1
        : raw1;

    wire [17:0] booth_row2 =
        enc2[18]
        ? ~raw2
        : raw2;

    wire [17:0] booth_row3 =
        enc3[18]
        ? ~raw3
        : raw3;


    wire [2:0] correction_count =
        {2'b00, enc0[18]} +
        {2'b00, enc1[18]} +
        {2'b00, enc2[18]} +
        {2'b00, enc3[18]};


    // ----------------------------------------------------------------
    // S1 : register Booth rows
    // ----------------------------------------------------------------

    logic [17:0] pp0_q;
    logic [17:0] pp1_q;
    logic [17:0] pp2_q;
    logic [17:0] pp3_q;

    logic [2:0] correction_q;


    always_ff @(posedge clk_i) begin

        if (valid_q[0]) begin

            pp0_q <= booth_row0;
            pp1_q <= booth_row1;
            pp2_q <= booth_row2;
            pp3_q <= booth_row3;

            correction_q <=
                correction_count;

        end

    end


    // ----------------------------------------------------------------
    // S2 : CSA 4 -> 3
    // ----------------------------------------------------------------

    wire [17:0] csa0_sum =
        pp0_q ^
        pp1_q ^
        pp2_q;

    wire [17:0] csa0_carry =
        (
            (pp0_q & pp1_q) |
            (pp0_q & pp2_q) |
            (pp1_q & pp2_q)
        ) << 1;


    logic [17:0] csa0_sum_q;
    logic [17:0] csa0_carry_q;

    logic [17:0] pp3_pipe_q;

    logic [2:0] correction_pipe_q;


    always_ff @(posedge clk_i) begin

        if (valid_q[1]) begin

            csa0_sum_q   <= csa0_sum;
            csa0_carry_q <= csa0_carry;

            pp3_pipe_q <=
                pp3_q;

            correction_pipe_q <=
                correction_q;

        end

    end


    // ----------------------------------------------------------------
    // S3 : CSA 3 -> 2
    // ----------------------------------------------------------------

    wire [17:0] csa1_sum =
        csa0_sum_q ^
        csa0_carry_q ^
        pp3_pipe_q;

    wire [17:0] csa1_carry =
        (
            (csa0_sum_q & csa0_carry_q) |
            (csa0_sum_q & pp3_pipe_q) |
            (csa0_carry_q & pp3_pipe_q)
        ) << 1;


    logic [17:0] csa1_sum_q;
    logic [17:0] csa1_carry_q;

    logic [2:0] correction_final_q;


    always_ff @(posedge clk_i) begin

        if (valid_q[2]) begin

            csa1_sum_q   <= csa1_sum;
            csa1_carry_q <= csa1_carry;

            correction_final_q <=
                correction_pipe_q;

        end

    end


    // ----------------------------------------------------------------
    // S4 : add Booth correction in carry-save form
    // ----------------------------------------------------------------

    wire [17:0] correction_row = {
        15'd0,
        correction_final_q
    };


    wire [17:0] csa2_sum =
        csa1_sum_q ^
        csa1_carry_q ^
        correction_row;

    wire [17:0] csa2_carry =
        (
            (csa1_sum_q & csa1_carry_q) |
            (csa1_sum_q & correction_row) |
            (csa1_carry_q & correction_row)
        ) << 1;


    always_ff @(posedge clk_i) begin

        if (valid_q[3]) begin

            row0_o <=
                csa2_sum;

            row1_o <=
                csa2_carry;

        end

    end


    assign out_valid_o =
        valid_q[4];

endmodule



// ============================================================================
// FOUR-LANE INT8 DOT4
//
// 4 Booth multipliers
//        ↓
// 8 carry-save rows
//        ↓
// pipelined CSA reduction
//        ↓
// two final rows
//        ↓
// 4-bit/chunk pipelined carry-propagating addition
//
// Throughput after fill: 1 DOT4 / cycle.
// ============================================================================
module ee_int8_dot4_pipe (
    input  logic               clk_i,
    input  logic               rst_ni,
    input  logic               clear_i,

    input  logic               in_valid_i,
    input  logic [31:0]        lhs_i,
    input  logic [31:0]        rhs_i,

    output logic               out_valid_o,
    output logic signed [17:0] dot_o
);

    wire [3:0] lane_valid;

    wire [17:0] l0_r0, l0_r1;
    wire [17:0] l1_r0, l1_r1;
    wire [17:0] l2_r0, l2_r1;
    wire [17:0] l3_r0, l3_r1;


    ee_int8_booth_csa_lane u_lane0 (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .clear_i     (clear_i),
        .in_valid_i  (in_valid_i),
        .a_i         (lhs_i[7:0]),
        .b_i         (rhs_i[7:0]),
        .out_valid_o (lane_valid[0]),
        .row0_o      (l0_r0),
        .row1_o      (l0_r1)
    );


    ee_int8_booth_csa_lane u_lane1 (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .clear_i     (clear_i),
        .in_valid_i  (in_valid_i),
        .a_i         (lhs_i[15:8]),
        .b_i         (rhs_i[15:8]),
        .out_valid_o (lane_valid[1]),
        .row0_o      (l1_r0),
        .row1_o      (l1_r1)
    );


    ee_int8_booth_csa_lane u_lane2 (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .clear_i     (clear_i),
        .in_valid_i  (in_valid_i),
        .a_i         (lhs_i[23:16]),
        .b_i         (rhs_i[23:16]),
        .out_valid_o (lane_valid[2]),
        .row0_o      (l2_r0),
        .row1_o      (l2_r1)
    );


    ee_int8_booth_csa_lane u_lane3 (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .clear_i     (clear_i),
        .in_valid_i  (in_valid_i),
        .a_i         (lhs_i[31:24]),
        .b_i         (rhs_i[31:24]),
        .out_valid_o (lane_valid[3]),
        .row0_o      (l3_r0),
        .row1_o      (l3_r1)
    );


    // All four Booth lanes are driven by the same in_valid_i and
    // therefore have identical valid latency.
    // Use one canonical valid instead of a high-fanout reduction AND.
    wire lanes_valid =
        lane_valid[0];


    // =================================================================
    // DOT CSA LEVEL 0
    // 8 rows -> 6 rows
    // =================================================================

    wire [17:0] d0_a_sum =
        l0_r0 ^ l0_r1 ^ l1_r0;

    wire [17:0] d0_a_carry =
        (
            (l0_r0 & l0_r1) |
            (l0_r0 & l1_r0) |
            (l0_r1 & l1_r0)
        ) << 1;


    wire [17:0] d0_b_sum =
        l1_r1 ^ l2_r0 ^ l2_r1;

    wire [17:0] d0_b_carry =
        (
            (l1_r1 & l2_r0) |
            (l1_r1 & l2_r1) |
            (l2_r0 & l2_r1)
        ) << 1;


    logic [17:0] d0_a_sum_q;
    logic [17:0] d0_a_carry_q;

    logic [17:0] d0_b_sum_q;
    logic [17:0] d0_b_carry_q;

    logic [17:0] d0_r6_q;
    logic [17:0] d0_r7_q;

    logic dv0_q;


    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni)
            dv0_q <= 1'b0;

        else if (clear_i)
            dv0_q <= 1'b0;

        else
            dv0_q <= lanes_valid;

    end


    always_ff @(posedge clk_i) begin

        d0_a_sum_q   <= d0_a_sum;
        d0_a_carry_q <= d0_a_carry;

        d0_b_sum_q   <= d0_b_sum;
        d0_b_carry_q <= d0_b_carry;

        d0_r6_q <= l3_r0;
        d0_r7_q <= l3_r1;

    end


    // =================================================================
    // DOT CSA LEVEL 1
    // 6 rows -> 4 rows
    // =================================================================

    wire [17:0] d1_a_sum =
        d0_a_sum_q ^
        d0_a_carry_q ^
        d0_b_sum_q;

    wire [17:0] d1_a_carry =
        (
            (d0_a_sum_q & d0_a_carry_q) |
            (d0_a_sum_q & d0_b_sum_q) |
            (d0_a_carry_q & d0_b_sum_q)
        ) << 1;


    wire [17:0] d1_b_sum =
        d0_b_carry_q ^
        d0_r6_q ^
        d0_r7_q;

    wire [17:0] d1_b_carry =
        (
            (d0_b_carry_q & d0_r6_q) |
            (d0_b_carry_q & d0_r7_q) |
            (d0_r6_q & d0_r7_q)
        ) << 1;


    logic [17:0] d1_a_sum_q;
    logic [17:0] d1_a_carry_q;

    logic [17:0] d1_b_sum_q;
    logic [17:0] d1_b_carry_q;

    logic dv1_q;


    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni)
            dv1_q <= 1'b0;

        else if (clear_i)
            dv1_q <= 1'b0;

        else
            dv1_q <= dv0_q;

    end


    always_ff @(posedge clk_i) begin

        d1_a_sum_q   <= d1_a_sum;
        d1_a_carry_q <= d1_a_carry;

        d1_b_sum_q   <= d1_b_sum;
        d1_b_carry_q <= d1_b_carry;

    end


    // =================================================================
    // DOT CSA LEVEL 2
    // 4 rows -> 3 rows
    // =================================================================

    wire [17:0] d2_sum =
        d1_a_sum_q ^
        d1_a_carry_q ^
        d1_b_sum_q;

    wire [17:0] d2_carry =
        (
            (d1_a_sum_q & d1_a_carry_q) |
            (d1_a_sum_q & d1_b_sum_q) |
            (d1_a_carry_q & d1_b_sum_q)
        ) << 1;


    logic [17:0] d2_sum_q;
    logic [17:0] d2_carry_q;
    logic [17:0] d2_pass_q;

    logic dv2_q;


    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni)
            dv2_q <= 1'b0;

        else if (clear_i)
            dv2_q <= 1'b0;

        else
            dv2_q <= dv1_q;

    end


    always_ff @(posedge clk_i) begin

        d2_sum_q   <= d2_sum;
        d2_carry_q <= d2_carry;

        d2_pass_q <=
            d1_b_carry_q;

    end


    // =================================================================
    // DOT CSA LEVEL 3
    // 3 rows -> final 2 rows
    // =================================================================

    wire [17:0] final_sum =
        d2_sum_q ^
        d2_carry_q ^
        d2_pass_q;

    wire [17:0] final_carry =
        (
            (d2_sum_q & d2_carry_q) |
            (d2_sum_q & d2_pass_q) |
            (d2_carry_q & d2_pass_q)
        ) << 1;


    logic [17:0] final_sum_q;
    logic [17:0] final_carry_q;

    logic dv3_q;


    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni)
            dv3_q <= 1'b0;

        else if (clear_i)
            dv3_q <= 1'b0;

        else
            dv3_q <= dv2_q;

    end


    always_ff @(posedge clk_i) begin

        final_sum_q   <= final_sum;
        final_carry_q <= final_carry;

    end


    // =================================================================
    // FINAL CPA
    //
    // Explicit 4-bit registered chunks.
    //
    // We intentionally do NOT ask synthesis to build an 18-bit ripple
    // adder in one cycle.
    // =================================================================

    logic [4:0] cv_q;


    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni)
            cv_q <= 5'b0;

        else if (clear_i)
            cv_q <= 5'b0;

        else begin

            cv_q[0] <= dv3_q;
            cv_q[1] <= cv_q[0];
            cv_q[2] <= cv_q[1];
            cv_q[3] <= cv_q[2];
            cv_q[4] <= cv_q[3];

        end

    end


    // ----------------------------------------------------------------
    // CPA0 bits 3:0
    // ----------------------------------------------------------------

    wire [4:0] add0 =
        {1'b0, final_sum_q[3:0]} +
        {1'b0, final_carry_q[3:0]};


    logic [3:0]  c0_result_q;
    logic        c0_carry_q;

    logic [13:0] c0_a_q;
    logic [13:0] c0_b_q;


    always_ff @(posedge clk_i) begin

        if (dv3_q) begin

            c0_result_q <=
                add0[3:0];

            c0_carry_q <=
                add0[4];

            c0_a_q <=
                final_sum_q[17:4];

            c0_b_q <=
                final_carry_q[17:4];

        end

    end


    // ----------------------------------------------------------------
    // CPA1 bits 7:4
    // ----------------------------------------------------------------

    wire [4:0] add1 =
        {1'b0, c0_a_q[3:0]} +
        {1'b0, c0_b_q[3:0]} +
        c0_carry_q;


    logic [7:0]  c1_result_q;
    logic        c1_carry_q;

    logic [9:0] c1_a_q;
    logic [9:0] c1_b_q;


    always_ff @(posedge clk_i) begin

        if (cv_q[0]) begin

            c1_result_q <= {
                add1[3:0],
                c0_result_q
            };

            c1_carry_q <=
                add1[4];

            c1_a_q <=
                c0_a_q[13:4];

            c1_b_q <=
                c0_b_q[13:4];

        end

    end


    // ----------------------------------------------------------------
    // CPA2 bits 11:8
    // ----------------------------------------------------------------

    wire [4:0] add2 =
        {1'b0, c1_a_q[3:0]} +
        {1'b0, c1_b_q[3:0]} +
        c1_carry_q;


    logic [11:0] c2_result_q;
    logic        c2_carry_q;

    logic [5:0] c2_a_q;
    logic [5:0] c2_b_q;


    always_ff @(posedge clk_i) begin

        if (cv_q[1]) begin

            c2_result_q <= {
                add2[3:0],
                c1_result_q
            };

            c2_carry_q <=
                add2[4];

            c2_a_q <=
                c1_a_q[9:4];

            c2_b_q <=
                c1_b_q[9:4];

        end

    end


    // ----------------------------------------------------------------
    // CPA3 bits 15:12
    // ----------------------------------------------------------------

    wire [4:0] add3 =
        {1'b0, c2_a_q[3:0]} +
        {1'b0, c2_b_q[3:0]} +
        c2_carry_q;


    logic [15:0] c3_result_q;
    logic        c3_carry_q;

    logic [1:0] c3_a_q;
    logic [1:0] c3_b_q;


    always_ff @(posedge clk_i) begin

        if (cv_q[2]) begin

            c3_result_q <= {
                add3[3:0],
                c2_result_q
            };

            c3_carry_q <=
                add3[4];

            c3_a_q <=
                c2_a_q[5:4];

            c3_b_q <=
                c2_b_q[5:4];

        end

    end


    // ----------------------------------------------------------------
    // CPA4 bits 17:16
    // ----------------------------------------------------------------

    wire [2:0] add4 =
        {1'b0, c3_a_q} +
        {1'b0, c3_b_q} +
        c3_carry_q;


    logic signed [17:0] dot_q;


    always_ff @(posedge clk_i) begin

        if (cv_q[3]) begin

            dot_q <= {
                add4[1:0],
                c3_result_q
            };

        end

    end


    assign dot_o =
        dot_q;

    assign out_valid_o =
        cv_q[4];

endmodule

`default_nettype wire
