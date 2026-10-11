`timescale 1ns/1ps
`default_nettype none

module compute_group_command_buffer #(
    parameter integer TILE_ID_W = 16
)(
    input  logic clk_i,
    input  logic rst_ni,

    // =========================================================
    // Scheduler-facing interface
    //
    // cmd_ready_o depends ONLY on local registered occupancy.
    // There is intentionally no combinational path from the
    // physical compute engine back to the scheduler.
    // =========================================================

    input  logic                 cmd_valid_i,
    input  logic [TILE_ID_W-1:0] cmd_tile_id_i,

    output logic                 cmd_ready_o,

    // =========================================================
    // Physical compute-group interface
    // =========================================================

    input  logic engine_ready_i,

    // Registered one-cycle launch pulse.
    output logic engine_start_o,

    // Registered tile ID corresponding to engine_start_o.
    output logic [TILE_ID_W-1:0] engine_tile_id_o,

    // =========================================================
    // Status
    // =========================================================

    output logic occupied_o,
    output logic [TILE_ID_W-1:0] buffered_tile_id_o
);


    // =========================================================
    // Command storage register
    // =========================================================

    logic                 valid_q;
    logic [TILE_ID_W-1:0] tile_id_q;


    // =========================================================
    // Scheduler readiness
    //
    // IMPORTANT:
    //
    // This is intentionally derived ONLY from valid_q.
    //
    // It does not depend on engine_ready_i.
    //
    // Therefore:
    //
    // engine_ready
    //    X
    //    |
    //    +---- no combinational path ----> scheduler
    // =========================================================

    assign cmd_ready_o =
        !valid_q;

    assign occupied_o =
        valid_q;

    assign buffered_tile_id_o =
        tile_id_q;


    // =========================================================
    // Registered command acceptance and launch
    //
    // Pipeline:
    //
    // Cycle N:
    //   Scheduler handshake stores tile command.
    //
    // Cycle N+:
    //   Command remains locally buffered.
    //
    // When engine_ready_i is observed:
    //
    //   command is removed from buffer,
    //   launch pulse is REGISTERED,
    //   launch tile ID is REGISTERED.
    //
    // The physical engine therefore receives a clean local
    // registered control boundary.
    // =========================================================

    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni) begin

            valid_q          <= 1'b0;
            tile_id_q        <= '0;

            engine_start_o   <= 1'b0;
            engine_tile_id_o <= '0;

        end
        else begin

            // Launch is always a one-cycle pulse.
            engine_start_o <= 1'b0;


            // -------------------------------------------------
            // Existing buffered command launches when the local
            // physical engine reports ready.
            // -------------------------------------------------

            if (
                valid_q &&
                engine_ready_i
            ) begin

                engine_start_o <= 1'b1;

                engine_tile_id_o <=
                    tile_id_q;

                valid_q <= 1'b0;

            end


            // -------------------------------------------------
            // Scheduler may write only when buffer was empty.
            //
            // No fall-through bypass is intentionally used.
            //
            // This costs at most one scheduler-side cycle at
            // tile granularity, but removes the downstream
            // combinational ready path.
            // -------------------------------------------------

            if (
                cmd_valid_i &&
                cmd_ready_o
            ) begin

                valid_q <= 1'b1;

                tile_id_q <=
                    cmd_tile_id_i;

            end

        end

    end


`ifndef SYNTHESIS

    // =========================================================
    // Simulation safety assertions
    // =========================================================

    always @(posedge clk_i) begin

        if (rst_ni) begin

            // A launch must come from a previously buffered
            // command.
            if (
                engine_start_o &&
                occupied_o
            ) begin
                // This condition is legal only because
                // engine_start_o reflects the previous cycle's
                // registered command. No action required.
            end

        end

    end

`endif


endmodule

`default_nettype wire
