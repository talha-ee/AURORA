`timescale 1ns/1ps
`default_nettype none

module ee_runtime_command_frontend #(
    parameter integer ENERGY_W     = 32,
    parameter integer TILE_ID_W    = 16,
    parameter integer TILE_COUNT_W = 16
)(
    input  logic clk_i,
    input  logic rst_ni,

    // =========================================================
    // Global runtime control
    // =========================================================

    input  logic enable_i,

    // =========================================================
    // Energy / power / thermal telemetry
    // =========================================================

    input  logic [ENERGY_W-1:0] energy_budget_i,
    input  logic [ENERGY_W-1:0] energy_used_i,

    input  logic [7:0] power_level_i,
    input  logic [7:0] thermal_level_i,

    // =========================================================
    // Learning feedback
    // =========================================================

    input  logic signed [15:0] improvement_i,
    input  logic               improvement_valid_i,

    // =========================================================
    // Job interface
    // =========================================================

    input  logic                    start_i,
    input  logic [TILE_COUNT_W-1:0] total_tiles_i,

    // =========================================================
    // Compute-group handshake
    // =========================================================

    input  logic [3:0] engine_ready_i,
    input  logic [3:0] engine_done_i,

    output logic [3:0] engine_start_o,

    output logic [(4*TILE_ID_W)-1:0] engine_tile_id_o,

    // =========================================================
    // Arithmetic-engine enables
    // =========================================================

    output logic int4_enable_o,
    output logic int8_enable_o,
    output logic bf16_enable_o,

    // =========================================================
    // Active runtime configuration
    // =========================================================

    output logic [1:0] precision_mode_o,
    output logic [1:0] compute_level_o,

    output logic [3:0] compute_group_enable_o,

    output logic [3:0] adaptation_rank_o,
    output logic [7:0] update_interval_o,
    output logic [3:0] adaptation_scope_o,

    output logic training_enable_o,

    // =========================================================
    // Status
    // =========================================================

    output logic job_busy_o,
    output logic job_done_o,

    output logic scheduler_ready_o,
    output logic safe_to_switch_o,

    output logic reconfiguration_pending_o,

    output logic [TILE_COUNT_W-1:0] tiles_issued_o,
    output logic [TILE_COUNT_W-1:0] tiles_completed_o,

    output logic [1:0] governor_state_o,
    output logic [1:0] scheduler_state_o,

    output logic [3:0] command_occupied_o,

    output logic illegal_precision_o
);
    wire core_rst_ni;
    ee_runtime_reset_release u_reset_release (
        .clk_i(clk_i),.arst_ni(rst_ni),.core_rst_no(core_rst_ni)
    );



    // =========================================================
    // GOVERNOR SIGNALS
    // =========================================================

    logic [1:0] governor_precision;
    logic [1:0] governor_compute;

    logic [3:0] governor_rank;
    logic [7:0] governor_interval;
    logic [3:0] governor_scope;

    logic governor_training;
    logic governor_valid;


    // =========================================================
    // COMMITTED CONFIGURATION SIGNALS
    // =========================================================

    logic [1:0] committed_precision;
    logic [1:0] committed_compute;

    logic [3:0] committed_rank;
    logic [7:0] committed_interval;
    logic [3:0] committed_scope;

    logic committed_training;

    logic committed_valid;
    logic config_pending;


    // =========================================================
    // DISPATCH SIGNALS
    // =========================================================

    logic dispatch_valid;

    logic dispatch_training;

    logic [1:0] dispatch_precision;
    logic [1:0] dispatch_compute;

    logic [3:0] dispatch_group_mask;


    // =========================================================
    // ENERGY-ELASTIC GOVERNOR
    // =========================================================

    logic bootstrap_q, config_transfer_q, config_busy_q;
    logic [3:0] done_q;
    wire [3:0] command_valid, command_ready;
    wire [(4*TILE_ID_W)-1:0] command_tile_id;
    wire scheduler_ready_raw, scheduler_safe;

    wire config_busy = bootstrap_q | governor_valid | config_pending |
                       committed_valid | config_transfer_q | dispatch_valid;


    ee_energy_elastic_governor_pipe #(
        .ENERGY_W(ENERGY_W)
    ) u_governor (

        .clk_i                  (clk_i),
        .rst_ni                 (core_rst_ni),

        .enable_i               (enable_i),

        .energy_budget_i        (energy_budget_i),
        .energy_used_i          (energy_used_i),

        .power_level_i          (power_level_i),
        .thermal_level_i        (thermal_level_i),

        .improvement_i          (improvement_i),
        .improvement_valid_i    (improvement_valid_i),

        .precision_mode_o       (governor_precision),
        .compute_level_o        (governor_compute),

        .adaptation_rank_o      (governor_rank),
        .update_interval_o      (governor_interval),
        .adaptation_scope_o     (governor_scope),

        .training_enable_o      (governor_training),

        .governor_state_o       (governor_state_o),

        .config_valid_o         (governor_valid)
    );


    // =========================================================
    // RUNTIME CONFIGURATION MANAGER
    // =========================================================

    ee_runtime_config_manager_direct u_config_manager (

        .clk_i                  (clk_i),
        .rst_ni                 (core_rst_ni),

        .proposal_valid_i       (governor_valid),

        .precision_mode_i       (governor_precision),
        .compute_level_i        (governor_compute),

        .adaptation_rank_i      (governor_rank),
        .update_interval_i      (governor_interval),
        .adaptation_scope_i     (governor_scope),

        .training_enable_i      (governor_training),

        .safe_to_switch_i       (safe_to_switch_o),

        .precision_mode_o       (committed_precision),
        .compute_level_o        (committed_compute),

        .adaptation_rank_o      (committed_rank),
        .update_interval_o      (committed_interval),
        .adaptation_scope_o     (committed_scope),

        .training_enable_o      (committed_training),

        .config_valid_o         (committed_valid),

        .pending_o              (config_pending)
    );


    // =========================================================
    // COMPUTE DISPATCHER
    // =========================================================

    compute_dispatcher u_dispatcher (

        .clk_i                   (clk_i),
        .rst_ni                  (core_rst_ni),

        .config_valid_i          (committed_valid | bootstrap_q),

        .precision_mode_i        (committed_precision),
        .compute_level_i         (committed_compute),

        .training_enable_i       (committed_training),

        .int4_enable_o           (int4_enable_o),
        .int8_enable_o           (int8_enable_o),
        .bf16_enable_o           (bf16_enable_o),

        .compute_group_enable_o  (dispatch_group_mask),

        .training_enable_o       (dispatch_training),

        .precision_mode_o        (dispatch_precision),
        .compute_level_o         (dispatch_compute),

        .dispatch_valid_o        (dispatch_valid),

        .illegal_precision_o     (illegal_precision_o)
    );


    // =========================================================
    // ENERGY-ELASTIC WORK SCHEDULER
    // =========================================================

    ee_work_scheduler_boundary #(
        .TILE_ID_W       (TILE_ID_W),
        .TILE_COUNT_W    (TILE_COUNT_W)
    ) u_scheduler (

        .clk_i                   (clk_i),
        .rst_ni                  (core_rst_ni),

        .config_valid_i          (dispatch_valid),

        .compute_group_enable_i  (dispatch_group_mask),

        .reconfig_pending_i      (config_busy_q),
        .config_pipeline_busy_i  (config_busy),

        .start_i                 (start_i && scheduler_ready_o),
        .total_tiles_i           (total_tiles_i),

        .group_ready_i           (command_ready),
        .group_done_i            (done_q),

        .tile_valid_o            (command_valid),
        .tile_id_o               (command_tile_id),

        .job_busy_o              (job_busy_o),
        .job_done_o              (job_done_o),

        .safe_to_switch_o        (scheduler_safe),

        .scheduler_ready_o       (scheduler_ready_raw),

        .tiles_issued_o          (tiles_issued_o),
        .tiles_completed_o       (tiles_completed_o),

        .active_group_mask_o     (compute_group_enable_o),

        .scheduler_state_o       (scheduler_state_o)
    );


    // =========================================================
    // Expose committed/dispatched architectural state
    // =========================================================

    assign precision_mode_o =
        dispatch_precision;

    assign compute_level_o =
        dispatch_compute;

    assign adaptation_rank_o =
        committed_rank;

    assign update_interval_o =
        committed_interval;

    assign adaptation_scope_o =
        committed_scope;

    assign training_enable_o =
        dispatch_training;

    assign reconfiguration_pending_o =
        config_pending;


    // Deliver the reset critical configuration through the dispatcher.
    assign scheduler_ready_o = scheduler_ready_raw && !config_busy && !config_busy_q;
    assign safe_to_switch_o = scheduler_safe && !(|command_occupied_o) &&
                              !(|engine_start_o);

    always_ff @(posedge clk_i or negedge core_rst_ni) begin
        if (!core_rst_ni) begin
            bootstrap_q <= 1'b1;
            config_transfer_q <= 1'b0;
            config_busy_q <= 1'b1;
            done_q <= 4'b0;
        end else begin
            bootstrap_q <= 1'b0;
            config_transfer_q <= committed_valid | bootstrap_q;
            config_busy_q <= config_busy;
            done_q <= engine_done_i;
        end
    end

    genvar cg;
    generate for (cg=0; cg<4; cg=cg+1) begin : GEN_COMMAND
        compute_group_command_buffer #(.TILE_ID_W(TILE_ID_W)) u_command (
            .clk_i(clk_i), .rst_ni(core_rst_ni),
            .cmd_valid_i(command_valid[cg]),
            .cmd_tile_id_i(command_tile_id[cg*TILE_ID_W +: TILE_ID_W]),
            .cmd_ready_o(command_ready[cg]),
            .engine_ready_i(engine_ready_i[cg]),
            .engine_start_o(engine_start_o[cg]),
            .engine_tile_id_o(engine_tile_id_o[cg*TILE_ID_W +: TILE_ID_W]),
            .occupied_o(command_occupied_o[cg]),
            .buffered_tile_id_o()
        );
    end endgenerate

endmodule

`default_nettype wire

`timescale 1ns/1ps
`default_nettype none

module ee_runtime_config_manager_direct (

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
            if (safe_to_switch_i) begin
                if (proposal_valid_i) begin
                precision_mode_o <= precision_mode_i;
                compute_level_o <= compute_level_i;
                adaptation_rank_o <= adaptation_rank_i;
                update_interval_o <= update_interval_i;
                adaptation_scope_o <= adaptation_scope_i;
                training_enable_o <= training_enable_i;
                end else if (pending_o) begin
                precision_mode_o <= pending_precision;
                compute_level_o <= pending_compute_level;
                adaptation_rank_o <= pending_rank;
                update_interval_o <= pending_update_interval;
                adaptation_scope_o <= pending_scope;
                training_enable_o <= pending_training;
                end
            end else if (proposal_valid_i) begin
                pending_precision <= precision_mode_i;
                pending_compute_level <= compute_level_i;
                pending_rank <= adaptation_rank_i;
                pending_update_interval <= update_interval_i;
                pending_scope <= adaptation_scope_i;
                pending_training <= training_enable_i;
            end



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


module ee_runtime_reset_release(
    input wire clk_i,
    input wire arst_ni,
    output wire core_rst_no
);
    (* async_reg = "true" *) logic [1:0] release_q;
    always_ff @(negedge clk_i or negedge arst_ni) begin
        if(!arst_ni) release_q<=2'b00;
        else release_q<={release_q[0],1'b1};
    end
    assign core_rst_no=release_q[1];
endmodule
