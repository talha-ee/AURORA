`timescale 1ns/1ps
`default_nettype none

module compute_dispatcher (
    input  logic       clk_i,
    input  logic       rst_ni,

    // Configuration from Energy-Elastic Governor
    input  logic       config_valid_i,

    // 00 = INT4
    // 01 = INT8
    // 10 = BF16
    // 11 = reserved
    input  logic [1:0] precision_mode_i,

    // 00 = 25%
    // 01 = 50%
    // 10 = 75%
    // 11 = 100%
    input  logic [1:0] compute_level_i,

    input  logic       training_enable_i,

    // ---------------------------------------------------------
    // Registered engine controls
    // ---------------------------------------------------------
    output logic       int4_enable_o,
    output logic       int8_enable_o,
    output logic       bf16_enable_o,

    // Four independently schedulable compute groups
    output logic [3:0] compute_group_enable_o,

    output logic       training_enable_o,

    output logic [1:0] precision_mode_o,
    output logic [1:0] compute_level_o,

    output logic       dispatch_valid_o,
    output logic       illegal_precision_o
);

    localparam logic [1:0] PREC_INT4 = 2'b00;
    localparam logic [1:0] PREC_INT8 = 2'b01;
    localparam logic [1:0] PREC_BF16 = 2'b10;

    // =========================================================
    // PIPELINE STAGE 0
    // Capture governor configuration.
    //
    // This prevents governor fanout from directly reaching all
    // compute-engine control logic.
    // =========================================================

    logic       valid_s0;
    logic [1:0] precision_s0;
    logic [1:0] compute_level_s0;
    logic       training_s0;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            valid_s0         <= 1'b0;
            precision_s0     <= PREC_INT4;
            compute_level_s0 <= 2'b00;
            training_s0      <= 1'b0;
        end
        else begin
            valid_s0 <= config_valid_i;

            if (config_valid_i) begin
                precision_s0     <= precision_mode_i;
                compute_level_s0 <= compute_level_i;
                training_s0      <= training_enable_i;
            end
        end
    end


    // =========================================================
    // PIPELINE STAGE 1
    // Decode precision and active compute capacity.
    // =========================================================

    logic       int4_next;
    logic       int8_next;
    logic       bf16_next;

    logic [3:0] group_enable_next;

    logic       illegal_precision_next;


    always_comb begin

        int4_next = 1'b0;
        int8_next = 1'b0;
        bf16_next = 1'b0;

        illegal_precision_next = 1'b0;


        // -----------------------------------------------------
        // Precision engine selection
        // -----------------------------------------------------

        case (precision_s0)

            PREC_INT4:
                int4_next = 1'b1;

            PREC_INT8:
                int8_next = 1'b1;

            PREC_BF16:
                bf16_next = 1'b1;

            default: begin
                illegal_precision_next = 1'b1;

                // Safe fallback
                int4_next = 1'b1;
            end

        endcase


        // -----------------------------------------------------
        // Compute-resource selection
        // -----------------------------------------------------

        case (compute_level_s0)

            2'b00:
                group_enable_next = 4'b0001;

            2'b01:
                group_enable_next = 4'b0011;

            2'b10:
                group_enable_next = 4'b0111;

            default:
                group_enable_next = 4'b1111;

        endcase
    end


    // =========================================================
    // Registered dispatcher outputs
    //
    // No long combinational control path goes directly into the
    // accelerator engines.
    // =========================================================

    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni) begin

            int4_enable_o          <= 1'b0;
            int8_enable_o          <= 1'b0;
            bf16_enable_o          <= 1'b0;

            compute_group_enable_o <= 4'b0000;

            training_enable_o      <= 1'b0;

            precision_mode_o       <= PREC_INT4;
            compute_level_o        <= 2'b00;

            dispatch_valid_o       <= 1'b0;
            illegal_precision_o    <= 1'b0;
        end

        else begin

            dispatch_valid_o <= valid_s0;

            if (valid_s0) begin

                int4_enable_o <= int4_next;
                int8_enable_o <= int8_next;
                bf16_enable_o <= bf16_next;

                compute_group_enable_o <=
                    group_enable_next;

                training_enable_o <=
                    training_s0;

                precision_mode_o <=
                    precision_s0;

                compute_level_o <=
                    compute_level_s0;

                illegal_precision_o <=
                    illegal_precision_next;
            end
        end
    end


`ifndef SYNTHESIS

    // Exactly one arithmetic engine may be selected.
    always @(posedge clk_i) begin

        if (
            rst_ni &&
            dispatch_valid_o
        ) begin

            if (
                (int4_enable_o +
                 int8_enable_o +
                 bf16_enable_o) != 1
            ) begin

                $fatal(
                    1,
                    "Dispatcher engine selection is not one-hot"
                );

            end
        end

    end

`endif


endmodule

`default_nettype wire
