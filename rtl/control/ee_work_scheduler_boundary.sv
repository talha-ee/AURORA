`timescale 1ns/1ps
`default_nettype none

module ee_work_scheduler_boundary #(
    parameter integer TILE_ID_W    = 16,
    parameter integer TILE_COUNT_W = 16
)(
    input  logic clk_i,
    input  logic rst_ni,

    input  logic       config_valid_i,
    input  logic [3:0] compute_group_enable_i,

    input  logic       reconfig_pending_i,
    input  logic       config_pipeline_busy_i,

    input  logic                    start_i,
    input  logic [TILE_COUNT_W-1:0] total_tiles_i,

    input  logic [3:0] group_ready_i,
    input  logic [3:0] group_done_i,

    output logic [3:0] tile_valid_o,

    output logic [(4*TILE_ID_W)-1:0] tile_id_o,

    output logic job_busy_o,
    output logic job_done_o,

    output logic safe_to_switch_o,
    output logic scheduler_ready_o,

    output logic [TILE_COUNT_W-1:0] tiles_issued_o,
    output logic [TILE_COUNT_W-1:0] tiles_completed_o,

    output logic [3:0] active_group_mask_o,

    output logic [1:0] scheduler_state_o
);
    wire [2:0] direct_alloc_count;
    ee_direct_alloc_count u_direct_count (
        .free_i(free_mask),
        .ge_i({remaining_ge_4,remaining_ge_3,remaining_ge_2,remaining_ge_1}),
        .enable_i(issue_enable),.count_o(direct_alloc_count)
    );


    localparam logic [1:0] ST_IDLE        = 2'b00;
    localparam logic [1:0] ST_RUN         = 2'b01;
    localparam logic [1:0] ST_DRAIN       = 2'b10;
    localparam logic [1:0] ST_WAIT_CONFIG = 2'b11;


    // ============================================================
    // ACTIVE CONFIGURATION
    // ============================================================

    logic [3:0] active_groups_q;
    logic       config_seen_q;


    // ============================================================
    // JOB BOOKKEEPING
    // ============================================================

    // Next tile ID that has not yet been RESERVED.
    logic [TILE_COUNT_W-1:0] next_tile_q;

    // Number of tiles not yet RESERVED into scheduler slots.
    //
    // IMPORTANT:
    // This replaces repeated:
    //
    //     allocation_cursor < total_tiles_q
    //
    // comparisons.
    logic [TILE_COUNT_W-1:0] remaining_q;

    logic [TILE_COUNT_W-1:0] issued_q;
    logic [TILE_COUNT_W-1:0] completed_q;



    // ============================================================
    // REGISTERED ISSUE SLOTS
    // ============================================================

    logic [3:0] slot_valid_q;

    logic [TILE_ID_W-1:0]
        slot_tile_q [0:3];


    // Remember why DRAIN was entered.
    logic drain_for_reconfig_q;


    // ============================================================
    // CURRENT HANDSHAKES
    // ============================================================

    wire [3:0] accept_mask =
        slot_valid_q &
        group_ready_i;


    logic [2:0] accept_count_c;
    logic [2:0] done_count_c;


    always_comb begin

        accept_count_c =
            {2'b00, accept_mask[0]} +
            {2'b00, accept_mask[1]} +
            {2'b00, accept_mask[2]} +
            {2'b00, accept_mask[3]};

        done_count_c =
            {2'b00, group_done_i[0]} +
            {2'b00, group_done_i[1]} +
            {2'b00, group_done_i[2]} +
            {2'b00, group_done_i[3]};

    end


    // ============================================================

    // Handshake counting and wide counter updates are separate stages.
    // Wait for both stages and the equality register before completing drain.
    logic [2:0] accept_count, done_count;
    logic counts_equal_q, accounting_busy_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if(!rst_ni) begin
            accept_count<=0; done_count<=0;
            counts_equal_q<=1; accounting_busy_q<=0;
        end else begin
            counts_equal_q<=(issued_q==completed_q);
            accounting_busy_q<=
                ((scheduler_state_o==ST_RUN)||(scheduler_state_o==ST_DRAIN)) &&
                ((accept_count!=0)||(done_count!=0));

            if((scheduler_state_o==ST_RUN)||(scheduler_state_o==ST_DRAIN)) begin
                accept_count<=accept_count_c;
                done_count<=done_count_c;
            end else begin
                accept_count<=0;
                done_count<=0;
            end
        end
    end

    // PARALLEL ISSUE ALLOCATOR
    //
    // OLD:
    //
    //   group0 compare + increment
    //      -> group1 compare + increment
    //      -> group2 compare + increment
    //      -> group3 compare + increment
    //
    // NEW:
    //
    //   free-mask
    //       -> four tiny parallel prefix ranks
    //       -> four parallel allocation decisions
    //
    // No 16-bit allocation dependency exists between groups.
    // ============================================================

    wire [3:0] free_mask =
        active_groups_q &
        (
            ~slot_valid_q |
            accept_mask
        );


    wire issue_enable =
        (scheduler_state_o == ST_RUN) &&
        !reconfig_pending_i &&
        (remaining_ge_1);


    // ------------------------------------------------------------
    // Remaining-count threshold decode.
    //
    // We can allocate at most four tiles per cycle, so we only
    // need to know whether remaining >= 1,2,3,4.
    //
    // This is much smaller than four cascaded 16-bit comparisons.
    // ------------------------------------------------------------

    wire remaining_hi =
        |remaining_q[TILE_COUNT_W-1:2];

    
    wire [3:0] remaining_limits_next, remaining_limits_load;
    ee_remaining_limits #(.W(TILE_COUNT_W)) u_limits_next (
        .count_i(remaining_q),.delta_i(alloc_count),.ge_o(remaining_limits_next)
    );
    ee_remaining_limits #(.W(TILE_COUNT_W)) u_limits_load (
        .count_i(total_tiles_i),.delta_i(3'd0),.ge_o(remaining_limits_load)
    );
    logic remaining_ge_1;

    logic remaining_ge_2;

    logic remaining_ge_3;

    logic remaining_ge_4;


    // ------------------------------------------------------------
    // Number of free enabled groups preceding each group.
    // ------------------------------------------------------------

    logic [1:0] prefix_1;
    logic [1:0] prefix_2;
    logic [1:0] prefix_3;


    always_comb begin

        prefix_1 =
            {1'b0, free_mask[0]};

        prefix_2 =
            {1'b0, free_mask[0]} +
            {1'b0, free_mask[1]};

        prefix_3 =
            {1'b0, free_mask[0]} +
            {1'b0, free_mask[1]} +
            {1'b0, free_mask[2]};

    end


    // ------------------------------------------------------------
    // Rank -> remaining test
    // ------------------------------------------------------------

    logic allow_group_1;
    logic allow_group_2;
    logic allow_group_3;


    always_comb begin

        case (prefix_1)

            2'd0:
                allow_group_1 = remaining_ge_1;

            default:
                allow_group_1 = remaining_ge_2;

        endcase


        case (prefix_2)

            2'd0:
                allow_group_2 = remaining_ge_1;

            2'd1:
                allow_group_2 = remaining_ge_2;

            default:
                allow_group_2 = remaining_ge_3;

        endcase


        case (prefix_3)

            2'd0:
                allow_group_3 = remaining_ge_1;

            2'd1:
                allow_group_3 = remaining_ge_2;

            2'd2:
                allow_group_3 = remaining_ge_3;

            default:
                allow_group_3 = remaining_ge_4;

        endcase

    end


    logic [3:0] plan_mask_c;


    always_comb begin

        plan_mask_c =
            4'b0000;

        if (issue_enable) begin

            plan_mask_c[0] =
                free_mask[0] &&
                remaining_ge_1;

            plan_mask_c[1] =
                free_mask[1] &&
                allow_group_1;

            plan_mask_c[2] =
                free_mask[2] &&
                allow_group_2;

            plan_mask_c[3] =
                free_mask[3] &&
                allow_group_3;

        end

    end


    logic [2:0] plan_count_c;


    always_comb begin

        plan_count_c =
            {2'b00, plan_mask_c[0]} +
            {2'b00, plan_mask_c[1]} +
            {2'b00, plan_mask_c[2]} +
            {2'b00, plan_mask_c[3]};

    end


    // ============================================================

    // Register the issue plan before wide counter arithmetic.
    // Previously reserved plans must drain before switching.
    logic [3:0] alloc_mask;
    logic [2:0] alloc_count;
    logic [1:0] prefix_1_q, prefix_2_q, prefix_3_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if(!rst_ni) begin
            alloc_mask<=0; alloc_count<=0;
            prefix_1_q<=0; prefix_2_q<=0; prefix_3_q<=0;
        end else begin
            alloc_mask<=0; alloc_count<=0;
            if(scheduler_state_o==ST_RUN && !(|alloc_mask)) begin
                alloc_mask<=plan_mask_c; alloc_count <= direct_alloc_count;
                prefix_1_q<=prefix_1; prefix_2_q<=prefix_2; prefix_3_q<=prefix_3;
            end
        end
    end
    // TILE IDs
    // ============================================================


    wire [4*TILE_ID_W-1:0] planned_ids;
    ee_scheduler_id3_pipe #(.W(TILE_ID_W)) u_id_stage (
        .clk_i(clk_i), .base_i(next_tile_q),
        .rank_q_i({prefix_3_q[1:0],prefix_2_q[1:0],prefix_1_q[1:0],2'd0}),
        .tile_o(planned_ids)
    );
    wire [TILE_ID_W-1:0] alloc_tile_0 = planned_ids[0*TILE_ID_W +: TILE_ID_W];

    wire [TILE_ID_W-1:0] alloc_tile_1 = planned_ids[1*TILE_ID_W +: TILE_ID_W];

    wire [TILE_ID_W-1:0] alloc_tile_2 = planned_ids[2*TILE_ID_W +: TILE_ID_W];

    wire [TILE_ID_W-1:0] alloc_tile_3 = planned_ids[3*TILE_ID_W +: TILE_ID_W];


    // ============================================================
    // NEXT COUNTER VALUES
    // ============================================================

    wire [TILE_COUNT_W-1:0] next_tile_after_alloc;
    ee_control_step3 #(.W(TILE_COUNT_W),.SUB(0)) u_next_tile_after_alloc (
        .a_i(next_tile_q), .step_i(alloc_count), .sum_o(next_tile_after_alloc)
    );


    wire [TILE_COUNT_W-1:0] remaining_after_alloc;
    ee_control_step3 #(.W(TILE_COUNT_W),.SUB(1)) u_remaining_after_alloc (
        .a_i(remaining_q), .step_i(alloc_count), .sum_o(remaining_after_alloc)
    );


    wire [TILE_COUNT_W-1:0] issued_after_handshake;
    ee_control_step3 #(.W(TILE_COUNT_W),.SUB(0)) u_issued_after_handshake (
        .a_i(issued_q), .step_i(accept_count), .sum_o(issued_after_handshake)
    );


    wire [TILE_COUNT_W-1:0] completed_after_handshake;
    ee_control_step3 #(.W(TILE_COUNT_W),.SUB(0)) u_completed_after_handshake (
        .a_i(completed_q), .step_i(done_count), .sum_o(completed_after_handshake)
    );





    // ============================================================
    // OUTPUTS
    // ============================================================

    always_comb begin

        tile_valid_o =
            slot_valid_q;

        tile_id_o =
            {
                slot_tile_q[3],
                slot_tile_q[2],
                slot_tile_q[1],
                slot_tile_q[0]
            };

        job_busy_o =
            (scheduler_state_o != ST_IDLE);



        scheduler_ready_o =
            config_seen_q &&
            (scheduler_state_o == ST_IDLE);

        tiles_issued_o =
            issued_q;

        tiles_completed_o =
            completed_q;

        active_group_mask_o =
            active_groups_q;

    end


    // ============================================================
    // MAIN REGISTERED SCHEDULER
    // ============================================================

    integer g;


    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (!rst_ni) begin

            scheduler_state_o <=
                ST_IDLE;
            safe_to_switch_o <= 1'b1;

            active_groups_q <=
                4'b0000;

            config_seen_q <=
                1'b0;

            next_tile_q <=
                '0;

            remaining_q <=
                '0;
            {remaining_ge_4,remaining_ge_3,remaining_ge_2,remaining_ge_1} <= 4'b0000;

            issued_q <=
                '0;

            completed_q <=
                '0;



            slot_valid_q <=
                4'b0000;

            for (
                g = 0;
                g < 4;
                g = g + 1
            ) begin

                slot_tile_q[g] <=
                    '0;

            end

            drain_for_reconfig_q <=
                1'b0;

            job_done_o <=
                1'b0;

        end

        else begin

            job_done_o <=
                1'b0;


            // ====================================================
            // Capture committed compute configuration.
            // ====================================================

            if (config_valid_i) begin

                active_groups_q <=
                    compute_group_enable_i;

                config_seen_q <=
                    1'b1;

            end


            // ====================================================
            // Running/draining accounting
            // ====================================================

            if (
                (scheduler_state_o == ST_RUN) ||
                (scheduler_state_o == ST_DRAIN)
            ) begin

                issued_q <=
                    issued_after_handshake;

                completed_q <=
                    completed_after_handshake;




                // -----------------------------------------------
                // Existing issue slots accepted this cycle.
                // -----------------------------------------------

                for (
                    g = 0;
                    g < 4;
                    g = g + 1
                ) begin

                    if (accept_mask[g])
                        slot_valid_q[g] <=
                            1'b0;

                end


                // -----------------------------------------------
                // Parallel refill.
                //
                // alloc_mask is zero automatically in DRAIN.
                // -----------------------------------------------

                if (alloc_mask[0]) begin

                    slot_valid_q[0] <=
                        1'b1;

                    slot_tile_q[0] <=
                        alloc_tile_0;

                end


                if (alloc_mask[1]) begin

                    slot_valid_q[1] <=
                        1'b1;

                    slot_tile_q[1] <=
                        alloc_tile_1;

                end


                if (alloc_mask[2]) begin

                    slot_valid_q[2] <=
                        1'b1;

                    slot_tile_q[2] <=
                        alloc_tile_2;

                end


                if (alloc_mask[3]) begin

                    slot_valid_q[3] <=
                        1'b1;

                    slot_tile_q[3] <=
                        alloc_tile_3;

                end


                next_tile_q <=
                    next_tile_after_alloc;

                remaining_q <=
                    remaining_after_alloc;
            {remaining_ge_4,remaining_ge_3,remaining_ge_2,remaining_ge_1} <= remaining_limits_next;

            end


            // ====================================================
            // STATE MACHINE
            // ====================================================

            case (scheduler_state_o)

                // ------------------------------------------------
                // IDLE
                // ------------------------------------------------

                ST_IDLE: begin

                    slot_valid_q <=
                        4'b0000;

                    drain_for_reconfig_q <=
                        1'b0;

                    if (
                        start_i &&
                        config_seen_q
                    ) begin

                        next_tile_q <=
                            '0;

                        remaining_q <=
                            total_tiles_i;
            {remaining_ge_4,remaining_ge_3,remaining_ge_2,remaining_ge_1} <= remaining_limits_load;

                        issued_q <=
                            '0;

                        completed_q <=
                            '0;



                        slot_valid_q <=
                            4'b0000;

                        if (
                            total_tiles_i ==
                            {TILE_COUNT_W{1'b0}}
                        ) begin

                            job_done_o <=
                                1'b1;

                            scheduler_state_o <=
                                ST_IDLE;
            safe_to_switch_o <= 1'b1;

                        end
                        else begin

                            scheduler_state_o <=
                                ST_RUN;
            safe_to_switch_o <= 1'b0;

                        end

                    end

                end


                // ------------------------------------------------
                // RUN
                // ------------------------------------------------

                ST_RUN: begin

                    // Highest priority: stop issuing immediately
                    // when runtime configuration must change.
                    if (reconfig_pending_i) begin

                        drain_for_reconfig_q <=
                            1'b1;

                        scheduler_state_o <=
                            ST_DRAIN;
            safe_to_switch_o <= 1'b0;

                    end

                    // remaining_q is REGISTERED.
                    //
                    // We intentionally transition one cycle after
                    // the final parallel allocation.  This removes
                    // allocator arithmetic from the state path.
                    else if (
                        (!remaining_ge_1)
                    ) begin

                        drain_for_reconfig_q <=
                            1'b0;

                        scheduler_state_o <=
                            ST_DRAIN;
            safe_to_switch_o <= 1'b0;

                    end

                end


                // ------------------------------------------------
                // DRAIN
                // ------------------------------------------------

                ST_DRAIN: begin

                    // Use registered slot/inflight state only.
                    //
                    // Waiting one extra cycle after the final
                    // handshake is intentional for timing.
                    if (
                        (alloc_mask == 4'b0000) &&
                        (slot_valid_q == 4'b0000) &&
                        (
                            counts_equal_q && !accounting_busy_q &&
                            (accept_count == 3'd0) && (done_count == 3'd0)
                        )
                    ) begin

                        if (drain_for_reconfig_q) begin

                            scheduler_state_o <=
                                ST_WAIT_CONFIG;
            safe_to_switch_o <= 1'b1;

                        end
                        else begin

                            job_done_o <=
                                1'b1;

                            scheduler_state_o <=
                                ST_IDLE;
            safe_to_switch_o <= 1'b1;

                        end

                    end

                end


                // ------------------------------------------------
                // WAIT FOR NEW COMMITTED CONFIGURATION
                // ------------------------------------------------

                ST_WAIT_CONFIG: begin

                    slot_valid_q <=
                        4'b0000;

                    if (!reconfig_pending_i && !config_pipeline_busy_i) begin

                        drain_for_reconfig_q <=
                            1'b0;

                        scheduler_state_o <=
                            ST_RUN;
            safe_to_switch_o <= 1'b0;

                    end

                end


                default: begin

                    scheduler_state_o <=
                        ST_IDLE;
            safe_to_switch_o <= 1'b1;

                    slot_valid_q <=
                        4'b0000;

                    drain_for_reconfig_q <=
                        1'b0;

                end

            endcase

        end

    end


`ifndef SYNTHESIS
    always @(negedge clk_i) begin
        if(rst_ni && (safe_to_switch_o !==
            ((scheduler_state_o==ST_IDLE)||(scheduler_state_o==ST_WAIT_CONFIG))))
            $fatal(1,"Registered safe-state bit disagrees with scheduler state");
    end
`endif


`ifndef SYNTHESIS
    always @(negedge clk_i) begin
        if(rst_ni && ({remaining_ge_4,remaining_ge_3,remaining_ge_2,remaining_ge_1} !==
            {(remaining_q>=4),(remaining_q>=3),(remaining_q>=2),(remaining_q>=1)}))
            $fatal(1,"Registered allocation limits disagree with remaining count");
    end
`endif

endmodule


module ee_control_add3_prefix #(parameter integer W=16)(
    input wire [W-1:0] a_i,b_i,
    input wire cin_i,
    output wire [W-1:0] sum_o
);
    localparam integer NC=(W+2)/3, PW=NC*3, LEVELS=$clog2(NC);
    wire [PW-1:0] a={{(PW-W){1'b0}},a_i}, b={{(PW-W){1'b0}},b_i};
    wire [NC-1:0] cg,cp;
    wire [2:0] s0[0:NC-1],s1[0:NC-1];
    wire [PW-1:0] selected;

    generate for(genvar k=0;k<NC;k=k+1) begin : ADD3
        wire [3:0] t0={1'b0,a[k*3+:3]}+{1'b0,b[k*3+:3]};
        wire [3:0] t1=t0+4'd1;
        assign s0[k]=t0[2:0]; assign s1[k]=t1[2:0];
        assign cg[k]=t0[3]; assign cp[k]=&(a[k*3+:3]^b[k*3+:3]);
    end endgenerate

    wire [NC-1:0] CARRY_g [0:LEVELS], CARRY_p [0:LEVELS];
    assign CARRY_g[0]=cg; assign CARRY_p[0]=cp;
    generate for(genvar st=0;st<LEVELS;st=st+1) begin : CARRY_LEVEL
        for(genvar bitn=0;bitn<NC;bitn=bitn+1) begin : B
            if(bitn >= (1<<st)) begin
                assign CARRY_g[st+1][bitn] = CARRY_g[st][bitn] |
                    (CARRY_p[st][bitn] & CARRY_g[st][bitn-(1<<st)]);
                assign CARRY_p[st+1][bitn] = CARRY_p[st][bitn] &
                    CARRY_p[st][bitn-(1<<st)];
            end else begin
                assign CARRY_g[st+1][bitn]=CARRY_g[st][bitn];
                assign CARRY_p[st+1][bitn]=CARRY_p[st][bitn];
            end
        end
    end endgenerate

    generate for(genvar k=0;k<NC;k=k+1) begin : SELECT3
        wire carry;
        if(k==0) assign carry=cin_i;
        else assign carry=CARRY_g[LEVELS][k-1] | (CARRY_p[LEVELS][k-1]&cin_i);
        assign selected[k*3+:3]=carry ? s1[k] : s0[k];
    end endgenerate
    assign sum_o=selected[W-1:0];
endmodule

`default_nettype wire


module ee_scheduler_id3_pipe #(parameter integer W=16)(
    input wire clk_i,
    input wire [W-1:0] base_i,
    input wire [7:0] rank_q_i,
    output wire [4*W-1:0] tile_o
);
    localparam integer NC=(W+2)/3, PW=NC*3;
    wire [PW-1:0] padded={{(PW-W){1'b0}},base_i};
    logic [PW-1:0] base_q;
    logic [2:0] increment_q[0:NC-1];
    logic [NC-1:0] propagate_q;
    logic [3:0] low_q[0:3];

    // Payload advances with planning; plan validity guards its use.
    always_ff @(posedge clk_i) begin
        base_q<=padded;
        for(integer k=1;k<NC;k=k+1) begin
            increment_q[k]<=padded[k*3+:3]+3'd1;
            propagate_q[k]<=&padded[k*3+:3];
        end
    end

    generate for(genvar offset=0;offset<4;offset=offset+1) begin : LOW
        always_ff @(posedge clk_i)
            low_q[offset]<={1'b0,padded[2:0]}+4'(offset);
    end endgenerate

    generate for(genvar group=0;group<4;group=group+1) begin : ID
        wire [3:0] low=low_q[rank_q_i[group*2+:2]];
        wire [PW-1:0] assembled;
        assign assembled[2:0]=low[2:0];
        for(genvar k=1;k<NC;k=k+1) begin : UPPER
            wire carry;
            if(k==1) assign carry=low[3];
            else assign carry=low[3] & (&propagate_q[k-1:1]);
            assign assembled[k*3+:3]=
                carry ? increment_q[k] : base_q[k*3+:3];
        end
        assign tile_o[group*W+:W]=assembled[W-1:0];
    end endgenerate
endmodule



module ee_control_step3 #(parameter integer W=16, SUB=0)(
    input wire [W-1:0] a_i,
    input wire [2:0] step_i,
    output wire [W-1:0] sum_o
);
    wire [2:0] x=a_i[2:0]^step_i;
    wire [2:0] g, p;
    wire [3:0] c;

    generate if(SUB) begin : BORROW
        assign g=(~a_i[2:0]) & step_i;
        assign p=~x;
    end else begin : CARRY
        assign g=a_i[2:0] & step_i;
        assign p=x;
    end endgenerate

    assign c[0]=1'b0;
    assign c[1]=g[0];
    assign c[2]=g[1] | (p[1]&g[0]);
    assign c[3]=g[2] | (p[2]&g[1]) | (p[2]&p[1]&g[0]);
    assign sum_o[2:0]=x^c[2:0];

    generate if(W>3) begin : HIGH
        wire [W-1:3] upper_p;

        // Keep upper-bit detection parallel to low-bit arithmetic.
        (* keep_hierarchy = 1 *)
        ee_control_step_upper #(.W(W),.SUB(SUB)) u_upper (
            .a_i(a_i[W-1:3]), .prop_o(upper_p)
        );

        assign sum_o[W-1:3]=
            a_i[W-1:3] ^ ({(W-3){c[3]}} & upper_p);
    end endgenerate
endmodule


module ee_control_step_upper #(parameter integer W=16, SUB=0)(
    input wire [W-1:3] a_i,
    output wire [W-1:3] prop_o
);
    assign prop_o[3]=1'b1;
    generate for(genvar k=4;k<W;k=k+1) begin : PREFIX
        (* keep_hierarchy = 1 *)
        ee_control_prefix_reduce #(.N(k-3),.SUB(SUB)) u_reduce (
            .a_i(a_i[k-1:3]),.prop_o(prop_o[k])
        );
    end endgenerate
endmodule

(* keep_hierarchy = 1 *)
module ee_control_prefix_reduce #(parameter integer N=1, SUB=0)(
    input wire [N-1:0] a_i,
    output wire prop_o
);
    generate if(SUB) assign prop_o=~|a_i;
    else assign prop_o=&a_i;
    endgenerate
endmodule




module ee_remaining_limits #(parameter integer W=16)(
    input wire [W-1:0] count_i,
    input wire [2:0] delta_i,
    output wire [3:0] ge_o
);
    wire [3:0] low=4'(count_i);
    wire high;
    generate if(W>4) assign high=|count_i[W-1:4];
    else assign high=1'b0;
    endgenerate

    wire [7:0] ge;
    wire [4:0] select_delta;

    generate for(genvar t=1;t<=8;t=t+1) begin : THRESHOLD
        assign ge[t-1]=high | (low>=4'(t));
    end endgenerate

    generate for(genvar d=0;d<=4;d=d+1) begin : DELTA
        assign select_delta[d]=(delta_i==3'(d));
    end endgenerate

    generate for(genvar k=0;k<4;k=k+1) begin : LIMIT
        assign ge_o[k]=(select_delta[0]&ge[k]) |
            (select_delta[1]&ge[k+1]) | (select_delta[2]&ge[k+2]) |
            (select_delta[3]&ge[k+3]) | (select_delta[4]&ge[k+4]);
    end endgenerate
endmodule


module ee_direct_alloc_count (
    input wire [3:0] free_i,
    input wire [3:0] ge_i,
    input wire enable_i,
    output wire [2:0] count_o
);
    wire p0=free_i[0]|free_i[1];
    wire p1=free_i[2]|free_i[3];
    wire g0=free_i[0]&free_i[1];
    wire g1=free_i[2]&free_i[3];

    wire f1=p0|p1;
    wire f2=g0|g1|(p0&p1);
    wire f3=(g0&p1)|(g1&p0);
    wire f4=g0&g1;

    wire t1=f1&ge_i[0];
    wire t2=f2&ge_i[1];
    wire t3=f3&ge_i[2];
    wire t4=f4&ge_i[3];

    assign count_o[0]=enable_i & ((t1 & ~t2) | (t3 & ~t4));
    assign count_o[1]=enable_i & t2 & ~t4;
    assign count_o[2]=enable_i & t4;
endmodule
