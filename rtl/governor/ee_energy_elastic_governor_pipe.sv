`timescale 1ns/1ps
`default_nettype none

module ee_energy_elastic_governor_pipe #(
    parameter ENERGY_W = 32
)(
    input  logic                  clk_i,
    input  logic                  rst_ni,
    input  logic                  enable_i,

    // =========================================================
    // Runtime energy / power / thermal inputs
    // =========================================================
    input  logic [ENERGY_W-1:0]   energy_budget_i,
    input  logic [ENERGY_W-1:0]   energy_used_i,

    input  logic [7:0]            power_level_i,
    input  logic [7:0]            thermal_level_i,

    // =========================================================
    // Learning feedback
    // =========================================================
    input  logic signed [15:0]    improvement_i,
    input  logic                  improvement_valid_i,

    // =========================================================
    // Pipelined runtime configuration outputs
    // =========================================================

    // 00 = INT4
    // 01 = INT8
    // 10 = BF16
    // 11 = reserved
    output logic [1:0]            precision_mode_o,

    // 00 = 25%
    // 01 = 50%
    // 10 = 75%
    // 11 = 100%
    output logic [1:0]            compute_level_o,

    // Adaptation rank, supports up to rank 15
    output logic [3:0]            adaptation_rank_o,

    // Number of cycles between learning updates
    output logic [7:0]            update_interval_o,

    // Number of trainable/adaptable blocks
    output logic [3:0]            adaptation_scope_o,

    output logic                  training_enable_o,

    // 00 critical
    // 01 low
    // 10 medium
    // 11 high
    output logic [1:0]            governor_state_o,

    // Pulses when a new runtime configuration is issued
    output logic                  config_valid_o
);

    // =========================================================
    // Precision encodings
    // =========================================================

    localparam logic [1:0] PREC_INT4 = 2'b00;
    localparam logic [1:0] PREC_INT8 = 2'b01;
    localparam logic [1:0] PREC_BF16 = 2'b10;

    // =========================================================
    // Governor states
    // =========================================================

    localparam logic [1:0] STATE_CRITICAL = 2'b00;
    localparam logic [1:0] STATE_LOW      = 2'b01;
    localparam logic [1:0] STATE_MEDIUM   = 2'b10;
    localparam logic [1:0] STATE_HIGH     = 2'b11;

    // =========================================================
    // PIPELINE STAGE 0
    //
    // Capture runtime telemetry.
    //
    // This isolates external power/thermal/energy counters from
    // the governor decision logic.
    // =========================================================

    logic [ENERGY_W-1:0] energy_budget_s0;
    logic [ENERGY_W-1:0] energy_used_s0;

    logic [7:0] power_level_s0;
    logic [7:0] thermal_level_s0;

    logic signed [15:0] improvement_s0;
    logic               improvement_valid_s0;

    logic enable_s0;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            energy_budget_s0       <= '0;
            energy_used_s0         <= '0;

            power_level_s0         <= '0;
            thermal_level_s0       <= '0;

            improvement_s0         <= '0;
            improvement_valid_s0   <= 1'b0;

            enable_s0              <= 1'b0;
        end
        else begin
            energy_budget_s0       <= energy_budget_i;
            energy_used_s0         <= energy_used_i;

            power_level_s0         <= power_level_i;
            thermal_level_s0       <= thermal_level_i;

            improvement_s0         <= improvement_i;
            improvement_valid_s0   <= improvement_valid_i;

            enable_s0              <= enable_i;
        end
    end

    // =========================================================
    // PIPELINE STAGE 1
    //
    // Energy-state evaluation.
    // =========================================================


    localparam integer NC=(ENERGY_W+3)/4, PW=NC*4, LEVELS=$clog2(NC);
    wire [ENERGY_W-1:0] remaining_energy_s1='0;
    logic [1:0] state_s1;
    wire [PW-1:0] budget_ext={{(PW-ENERGY_W){1'b0}},energy_budget_s0};
    wire [PW-1:0] used_ext={{(PW-ENERGY_W){1'b0}},energy_used_s0};
    logic [3:0] d0_q[0:NC-1], d1_q[0:NC-1];
    logic [NC-1:0] borrow_g_q, borrow_p_q;
    logic [PW-1:0] budget_r1_q, budget_r2_q, remaining_r2_q;
    logic hard_r1_q, low_r1_q, feedback_r1_q;
    logic hard_r2_q, low_r2_q, feedback_r2_q, energy_critical_r2_q;
    logic hard_r3_q, low_r3_q, feedback_r3_q, energy_critical_r3_q;
    logic [NC-1:0] quarter_lt_q, quarter_eq_q, half_lt_q, half_eq_q;
    wire [PW-1:0] remaining_c;
    wire [PW-1:0] quarter_c=budget_r2_q>>2, half_c=budget_r2_q>>1;

    // Register parallel four-bit differences.
    generate for(genvar k=0;k<NC;k=k+1) begin : DIFF4
        wire [4:0] d0={1'b0,budget_ext[k*4+:4]}-{1'b0,used_ext[k*4+:4]};
        wire [4:0] d1=d0-5'd1;
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if(!rst_ni) begin
                d0_q[k]<=0; d1_q[k]<=0;
                borrow_g_q[k]<=0; borrow_p_q[k]<=1;
            end else begin
                d0_q[k]<=d0[3:0]; d1_q[k]<=d1[3:0];
                borrow_g_q[k]<=d0[4];
                borrow_p_q[k]<=(budget_ext[k*4+:4]==used_ext[k*4+:4]);
            end
        end
    end endgenerate

    wire [NC-1:0] BORROW_g [0:LEVELS], BORROW_p [0:LEVELS];
    assign BORROW_g[0]=borrow_g_q; assign BORROW_p[0]=borrow_p_q;
    generate for(genvar st=0;st<LEVELS;st=st+1) begin : BORROW_LEVEL
        for(genvar bitn=0;bitn<NC;bitn=bitn+1) begin : B
            if(bitn >= (1<<st)) begin
                assign BORROW_g[st+1][bitn] = BORROW_g[st][bitn] |
                    (BORROW_p[st][bitn] & BORROW_g[st][bitn-(1<<st)]);
                assign BORROW_p[st+1][bitn] = BORROW_p[st][bitn] &
                    BORROW_p[st][bitn-(1<<st)];
            end else begin
                assign BORROW_g[st+1][bitn]=BORROW_g[st][bitn];
                assign BORROW_p[st+1][bitn]=BORROW_p[st][bitn];
            end
        end
    end endgenerate

    generate for(genvar k=0;k<NC;k=k+1) begin : SELECT_DIFF
        if(k==0) assign remaining_c[k*4+:4]=d0_q[k];
        else assign remaining_c[k*4+:4]=BORROW_g[LEVELS][k-1] ? d1_q[k] : d0_q[k];
    end endgenerate

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if(!rst_ni) begin
            budget_r1_q<=0; hard_r1_q<=1; low_r1_q<=0; feedback_r1_q<=0;
            budget_r2_q<=0; remaining_r2_q<=0;
            hard_r2_q<=1; low_r2_q<=0; feedback_r2_q<=0; energy_critical_r2_q<=1;
            hard_r3_q<=1; low_r3_q<=0; feedback_r3_q<=0; energy_critical_r3_q<=1;
        end else begin
            budget_r1_q<=budget_ext;
            hard_r1_q<=!enable_s0 || power_level_s0>=8'd220 || thermal_level_s0>=8'd220;
            low_r1_q<=power_level_s0>=8'd180 || thermal_level_s0>=8'd180;
            feedback_r1_q<=improvement_valid_s0 && improvement_s0<=16'sd1;
            budget_r2_q<=budget_r1_q; remaining_r2_q<=remaining_c;
            energy_critical_r2_q<=BORROW_g[LEVELS][NC-1] | (&borrow_p_q);
            hard_r2_q<=hard_r1_q; low_r2_q<=low_r1_q; feedback_r2_q<=feedback_r1_q;
            energy_critical_r3_q<=energy_critical_r2_q;
            hard_r3_q<=hard_r2_q; low_r3_q<=low_r2_q; feedback_r3_q<=feedback_r2_q;
        end
    end

    // Register local comparisons before the global state decision.
    generate for(genvar k=0;k<NC;k=k+1) begin : COMPARE4
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if(!rst_ni) begin
                quarter_lt_q[k]<=0; quarter_eq_q[k]<=1;
                half_lt_q[k]<=0; half_eq_q[k]<=1;
            end else begin
                quarter_lt_q[k]<=remaining_r2_q[k*4+:4]<quarter_c[k*4+:4];
                quarter_eq_q[k]<=remaining_r2_q[k*4+:4]==quarter_c[k*4+:4];
                half_lt_q[k]<=remaining_r2_q[k*4+:4]<half_c[k*4+:4];
                half_eq_q[k]<=remaining_r2_q[k*4+:4]==half_c[k*4+:4];
            end
        end
    end endgenerate

    wire [NC-1:0] QUARTER_g [0:LEVELS], QUARTER_p [0:LEVELS];
    assign QUARTER_g[0]=quarter_lt_q; assign QUARTER_p[0]=quarter_eq_q;
    generate for(genvar st=0;st<LEVELS;st=st+1) begin : QUARTER_LEVEL
        for(genvar bitn=0;bitn<NC;bitn=bitn+1) begin : B
            if(bitn >= (1<<st)) begin
                assign QUARTER_g[st+1][bitn] = QUARTER_g[st][bitn] |
                    (QUARTER_p[st][bitn] & QUARTER_g[st][bitn-(1<<st)]);
                assign QUARTER_p[st+1][bitn] = QUARTER_p[st][bitn] &
                    QUARTER_p[st][bitn-(1<<st)];
            end else begin
                assign QUARTER_g[st+1][bitn]=QUARTER_g[st][bitn];
                assign QUARTER_p[st+1][bitn]=QUARTER_p[st][bitn];
            end
        end
    end endgenerate

    wire [NC-1:0] HALF_g [0:LEVELS], HALF_p [0:LEVELS];
    assign HALF_g[0]=half_lt_q; assign HALF_p[0]=half_eq_q;
    generate for(genvar st=0;st<LEVELS;st=st+1) begin : HALF_LEVEL
        for(genvar bitn=0;bitn<NC;bitn=bitn+1) begin : B
            if(bitn >= (1<<st)) begin
                assign HALF_g[st+1][bitn] = HALF_g[st][bitn] |
                    (HALF_p[st][bitn] & HALF_g[st][bitn-(1<<st)]);
                assign HALF_p[st+1][bitn] = HALF_p[st][bitn] &
                    HALF_p[st][bitn-(1<<st)];
            end else begin
                assign HALF_g[st+1][bitn]=HALF_g[st][bitn];
                assign HALF_p[st+1][bitn]=HALF_p[st][bitn];
            end
        end
    end endgenerate

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if(!rst_ni) state_s1<=STATE_CRITICAL;
        else if(hard_r3_q || energy_critical_r3_q) state_s1<=STATE_CRITICAL;
        else if(low_r3_q || QUARTER_g[LEVELS][NC-1]) state_s1<=STATE_LOW;
        else if(HALF_g[LEVELS][NC-1] || feedback_r3_q) state_s1<=STATE_MEDIUM;
        else state_s1<=STATE_HIGH;
    end

    logic [1:0] precision_next;
    logic [1:0] compute_level_next;

    logic [3:0] adaptation_rank_next;
    logic [7:0] update_interval_next;
    logic [3:0] adaptation_scope_next;

    logic training_enable_next;


    always_comb begin

        // Safe defaults
        precision_next         = PREC_INT4;
        compute_level_next     = 2'b00;

        adaptation_rank_next   = 4'd1;
        update_interval_next   = 8'd16;
        adaptation_scope_next  = 4'd1;

        training_enable_next   = 1'b0;


        case (state_s1)

            // =================================================
            // HIGH ENERGY
            //
            // BF16 is allowed for sensitive update operations.
            // Full compute fabric available.
            // =================================================

            STATE_HIGH: begin

                precision_next         = PREC_BF16;

                compute_level_next     = 2'b11;

                adaptation_rank_next   = 4'd8;

                update_interval_next   = 8'd1;

                adaptation_scope_next  = 4'd8;

                training_enable_next   = 1'b1;
            end


            // =================================================
            // MEDIUM ENERGY
            //
            // INT8 is the normal adaptive-learning mode.
            // =================================================

            STATE_MEDIUM: begin

                precision_next         = PREC_INT8;

                compute_level_next     = 2'b10;

                adaptation_rank_next   = 4'd4;

                update_interval_next   = 8'd2;

                adaptation_scope_next  = 4'd4;

                training_enable_next   = 1'b1;
            end


            // =================================================
            // LOW ENERGY
            //
            // INT4 and reduced active compute.
            // =================================================

            STATE_LOW: begin

                precision_next         = PREC_INT4;

                compute_level_next     = 2'b01;

                adaptation_rank_next   = 4'd2;

                update_interval_next   = 8'd4;

                adaptation_scope_next  = 4'd2;

                training_enable_next   = 1'b1;
            end


            // =================================================
            // CRITICAL ENERGY
            //
            // Minimum possible adaptation work.
            // =================================================

            default: begin

                precision_next         = PREC_INT4;

                compute_level_next     = 2'b00;

                adaptation_rank_next   = 4'd1;

                update_interval_next   = 8'd16;

                adaptation_scope_next  = 4'd1;

                training_enable_next   = 1'b0;
            end

        endcase
    end


    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni) begin

            precision_mode_o       <= PREC_INT4;

            compute_level_o        <= 2'b00;

            adaptation_rank_o      <= 4'd1;

            update_interval_o      <= 8'd16;

            adaptation_scope_o     <= 4'd1;

            training_enable_o      <= 1'b0;

            governor_state_o       <= STATE_CRITICAL;

            config_valid_o         <= 1'b0;
        end

        else begin

            // Pulse only when the architectural configuration
            // actually changes.
            config_valid_o <= 1'b0;

            if (
                precision_next        != precision_mode_o      ||
                compute_level_next    != compute_level_o       ||
                adaptation_rank_next  != adaptation_rank_o     ||
                update_interval_next  != update_interval_o     ||
                adaptation_scope_next != adaptation_scope_o    ||
                training_enable_next  != training_enable_o     ||
                state_s1              != governor_state_o
            ) begin
                config_valid_o <= 1'b1;
            end

            precision_mode_o       <= precision_next;
            compute_level_o        <= compute_level_next;
            adaptation_rank_o      <= adaptation_rank_next;
            update_interval_o      <= update_interval_next;
            adaptation_scope_o     <= adaptation_scope_next;
            training_enable_o      <= training_enable_next;
            governor_state_o       <= state_s1;
        end
    end


    // Prevent unused-signal warning for now.
    logic unused_remaining_energy;

    always_comb begin
        unused_remaining_energy =
            ^remaining_energy_s1;
    end

endmodule

`default_nettype wire
