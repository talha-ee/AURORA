`timescale 1ns/1ps
`default_nettype none

module runtime_config_manager (

    input  logic       clk_i,
    input  logic       rst_ni,

    // =========================================================
    // Proposed configuration from governor
    // =========================================================

    input  logic       proposal_valid_i,

    input  logic [1:0] precision_mode_i,
    input  logic [1:0] compute_level_i,

    input  logic [3:0] adaptation_rank_i,
    input  logic [7:0] update_interval_i,
    input  logic [3:0] adaptation_scope_i,

    input  logic       training_enable_i,

    // =========================================================
    // Safe switching point
    //
    // Later this comes from the work scheduler:
    //
    // accelerator idle
    // OR
    // completed tile / safe adaptation boundary
    // =========================================================

    input  logic       safe_to_switch_i,


    // =========================================================
    // Committed runtime configuration
    // =========================================================

    output logic [1:0] precision_mode_o,
    output logic [1:0] compute_level_o,

    output logic [3:0] adaptation_rank_o,
    output logic [7:0] update_interval_o,
    output logic [3:0] adaptation_scope_o,

    output logic       training_enable_o,

    // One-cycle pulse when a new configuration is committed
    output logic       config_valid_o,

    // A newer governor decision is waiting for a safe boundary
    output logic       pending_o
);


    // =========================================================
    // Pending configuration registers
    // =========================================================

    logic [1:0] pending_precision;
    logic [1:0] pending_compute_level;

    logic [3:0] pending_rank;
    logic [7:0] pending_update_interval;
    logic [3:0] pending_scope;

    logic       pending_training;


    // =========================================================
    // Configuration comparison
    // =========================================================

    logic proposal_diff;
    logic pending_diff;


    always_comb begin

        proposal_diff =
            (precision_mode_i      != precision_mode_o)      ||
            (compute_level_i       != compute_level_o)       ||
            (adaptation_rank_i     != adaptation_rank_o)     ||
            (update_interval_i     != update_interval_o)     ||
            (adaptation_scope_i    != adaptation_scope_o)    ||
            (training_enable_i     != training_enable_o);


        pending_diff =
            (pending_precision       != precision_mode_o)     ||
            (pending_compute_level   != compute_level_o)      ||
            (pending_rank            != adaptation_rank_o)    ||
            (pending_update_interval != update_interval_o)    ||
            (pending_scope           != adaptation_scope_o)   ||
            (pending_training        != training_enable_o);

    end


    // =========================================================
    // Commit controller
    //
    // Policy:
    //
    // 1. Governor may propose configurations continuously.
    //
    // 2. If compute is busy, latest proposal is stored.
    //
    // 3. Newer proposals replace older pending proposals.
    //
    // 4. Configuration changes only at safe boundaries.
    //
    // 5. Duplicate configurations do not generate unnecessary
    //    dispatcher activity.
    // =========================================================

    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni) begin

            // Safe reset operating point:
            // INT4 + 25% compute + training disabled.

            precision_mode_o      <= 2'b00;
            compute_level_o       <= 2'b00;

            adaptation_rank_o     <= 4'd1;
            update_interval_o     <= 8'd16;
            adaptation_scope_o    <= 4'd1;

            training_enable_o     <= 1'b0;

            config_valid_o        <= 1'b0;

            pending_o             <= 1'b0;

            pending_precision       <= 2'b00;
            pending_compute_level   <= 2'b00;

            pending_rank            <= 4'd1;
            pending_update_interval <= 8'd16;
            pending_scope           <= 4'd1;

            pending_training        <= 1'b0;

        end

        else begin

            // config_valid is a pulse, not a permanent level.
            config_valid_o <= 1'b0;


            // =================================================
            // SAFE BOUNDARY
            // =================================================

            if (safe_to_switch_i) begin

                // ---------------------------------------------
                // A new governor proposal exists right now.
                //
                // Always prefer this newest proposal over an
                // older pending one.
                // ---------------------------------------------

                if (proposal_valid_i) begin

                    if (proposal_diff) begin

                        precision_mode_o <=
                            precision_mode_i;

                        compute_level_o <=
                            compute_level_i;

                        adaptation_rank_o <=
                            adaptation_rank_i;

                        update_interval_o <=
                            update_interval_i;

                        adaptation_scope_o <=
                            adaptation_scope_i;

                        training_enable_o <=
                            training_enable_i;

                        config_valid_o <= 1'b1;

                    end

                    pending_o <= 1'b0;

                end


                // ---------------------------------------------
                // No new proposal this cycle.
                // Commit previously stored proposal.
                // ---------------------------------------------

                else if (pending_o) begin

                    if (pending_diff) begin

                        precision_mode_o <=
                            pending_precision;

                        compute_level_o <=
                            pending_compute_level;

                        adaptation_rank_o <=
                            pending_rank;

                        update_interval_o <=
                            pending_update_interval;

                        adaptation_scope_o <=
                            pending_scope;

                        training_enable_o <=
                            pending_training;

                        config_valid_o <= 1'b1;

                    end

                    pending_o <= 1'b0;

                end
            end


            // =================================================
            // COMPUTE BUSY / UNSAFE TO SWITCH
            //
            // Store newest governor proposal.
            // =================================================

            else begin

                if (proposal_valid_i) begin

                    if (proposal_diff) begin

                        pending_precision <=
                            precision_mode_i;

                        pending_compute_level <=
                            compute_level_i;

                        pending_rank <=
                            adaptation_rank_i;

                        pending_update_interval <=
                            update_interval_i;

                        pending_scope <=
                            adaptation_scope_i;

                        pending_training <=
                            training_enable_i;

                        pending_o <= 1'b1;

                    end
                    else begin

                        // Latest governor decision already matches
                        // active configuration. Cancel any older
                        // deferred request.
                        pending_o <= 1'b0;

                    end

                end
            end
        end
    end


endmodule

`default_nettype wire
