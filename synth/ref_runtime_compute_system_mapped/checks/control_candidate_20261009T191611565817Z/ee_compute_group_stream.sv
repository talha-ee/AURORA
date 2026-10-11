
`timescale 1ns/1ps
`default_nettype none
module ee_compute_group_stream #(parameter integer TILE_ID_W=16)(
 input wire clk_i,rst_ni,start_i,
 input wire [TILE_ID_W-1:0] tile_id_i,
 input wire [1:0] precision_i,
 output wire ready_o,output logic done_o,
 input wire data_valid_i,data_last_i,
 input wire [127:0] lhs_i,rhs_i,
 output wire data_ready_o,
 output wire result_valid_o,input wire result_ready_i,
 output wire result_last_o,
 output wire [1:0] result_precision_o,
 output wire [TILE_ID_W-1:0] result_tile_id_o,
 output wire [511:0] result_sum_o,result_carry_o
);
 localparam [2:0] IDLE=0,FEED=1,DRAIN=2,CAPTURE=3,HOLD=4;
 logic [2:0] state_q;
 logic [1:0] mode_q;
 logic [TILE_ID_W-1:0] tile_q;
 logic valid_q,last_seen_q;
 logic [127:0] lhs_q,rhs_q;
 logic [15:0] accepted_q,corner_q;
 logic [511:0] integer_sum_q,integer_carry_q;
 wire [1:0] bf_ready,bf_valid;
 wire [63:0] bf_result;
 logic [5:0] accept_ptr_q,write_ptr_q,read_ptr_q;
 logic [6:0] credits_q,queued_q;
 logic [63:0] bf_mem [0:63];
 logic bf_last_mem [0:63];
 wire take=data_valid_i && data_ready_o;
 wire pop=result_valid_o && result_ready_i;
 wire bf_push=(&bf_valid) && mode_q==2;
 assign ready_o=(state_q==IDLE) && rst_ni;
 // EE_CTRL_PREFIX: combinational; original counter cases retained.
  wire [6:0] ee_credits_inc, ee_credits_dec, ee_queued_inc, ee_queued_dec;
  assign ee_credits_inc[0] = ~credits_q[0];
  assign ee_credits_dec[0] = ~credits_q[0];
  assign ee_queued_inc[0] = ~queued_q[0];
  assign ee_queued_dec[0] = ~queued_q[0];
  generate for(genvar ee_b=1; ee_b<7; ee_b=ee_b+1) begin: EE_CTRL_PREFIX
    assign ee_credits_inc[ee_b] = credits_q[ee_b] ^ (&credits_q[ee_b-1:0]);
    assign ee_credits_dec[ee_b] = credits_q[ee_b] ^ (~|credits_q[ee_b-1:0]);
    assign ee_queued_inc[ee_b] = queued_q[ee_b] ^ (&queued_q[ee_b-1:0]);
    assign ee_queued_dec[ee_b] = queued_q[ee_b] ^ (~|queued_q[ee_b-1:0]);
  end endgenerate
  assign data_ready_o=(state_q==FEED) &&
     ((mode_q!=2) || ((credits_q<7'd64) && !start_i));
 assign result_valid_o=mode_q==2 ? (queued_q!=0) : (state_q==HOLD);
 assign result_last_o=mode_q==2 ? bf_last_mem[read_ptr_q] : 1'b1;
 assign result_precision_o=mode_q;
 assign result_tile_id_o=tile_q;
 assign result_sum_o=mode_q==2 ?
     {448'b0,bf_mem[read_ptr_q]} : integer_sum_q;
 assign result_carry_o=mode_q==2 ? 512'b0 : integer_carry_q;

 wire [127:0] skew_a4,skew_b4,skew_a8,skew_b8;
 wire [3:0] skew_av4,skew_bv4,skew_av8,skew_bv8;
 assign skew_a4[0+:32]=mode_q==0 ? lhs_q[0+:32] : 32'b0;
 assign skew_av4[0]=valid_q && mode_q==0;
 assign skew_a8[0+:32]=mode_q==1 ? lhs_q[0+:32] : 32'b0;
 assign skew_av8[0]=valid_q && mode_q==1;
 assign skew_a4[32+:32]=mode_q==0 ? lhs_q[32+:32] : 32'b0;
 assign skew_av4[1]=valid_q && mode_q==0;
 assign skew_a8[32+:32]=mode_q==1 ? lhs_q[32+:32] : 32'b0;
 assign skew_av8[1]=valid_q && mode_q==1;
 assign skew_a4[64+:32]=mode_q==0 ? lhs_q[64+:32] : 32'b0;
 assign skew_av4[2]=valid_q && mode_q==0;
 assign skew_a8[64+:32]=mode_q==1 ? lhs_q[64+:32] : 32'b0;
 assign skew_av8[2]=valid_q && mode_q==1;
 assign skew_a4[96+:32]=mode_q==0 ? lhs_q[96+:32] : 32'b0;
 assign skew_av4[3]=valid_q && mode_q==0;
 assign skew_a8[96+:32]=mode_q==1 ? lhs_q[96+:32] : 32'b0;
 assign skew_av8[3]=valid_q && mode_q==1;
 assign skew_b4[0+:32]=mode_q==0 ? rhs_q[0+:32] : 32'b0;
 assign skew_bv4[0]=valid_q && mode_q==0;
 assign skew_b8[0+:32]=mode_q==1 ? rhs_q[0+:32] : 32'b0;
 assign skew_bv8[0]=valid_q && mode_q==1;
 assign skew_b4[32+:32]=mode_q==0 ? rhs_q[32+:32] : 32'b0;
 assign skew_bv4[1]=valid_q && mode_q==0;
 assign skew_b8[32+:32]=mode_q==1 ? rhs_q[32+:32] : 32'b0;
 assign skew_bv8[1]=valid_q && mode_q==1;
 assign skew_b4[64+:32]=mode_q==0 ? rhs_q[64+:32] : 32'b0;
 assign skew_bv4[2]=valid_q && mode_q==0;
 assign skew_b8[64+:32]=mode_q==1 ? rhs_q[64+:32] : 32'b0;
 assign skew_bv8[2]=valid_q && mode_q==1;
 assign skew_b4[96+:32]=mode_q==0 ? rhs_q[96+:32] : 32'b0;
 assign skew_bv4[3]=valid_q && mode_q==0;
 assign skew_b8[96+:32]=mode_q==1 ? rhs_q[96+:32] : 32'b0;
 assign skew_bv8[3]=valid_q && mode_q==1;
 wire [15:0] u4,u8,v4,v8;
 wire [511:0] s4,c4,s8,c8;
 ee_int4_mesh_4x4 u_int4(
   .clk_i(clk_i),.rst_ni(rst_ni),.clear_i(start_i || mode_q!=0),
   .a_west_i(skew_a4),
   .b_north_i(skew_b4),
   .a_valid_i(skew_av4),
   .b_valid_i(skew_bv4),
   .acc_update_o(u4),.acc_valid_o(v4),
   .acc_sum_o(s4),.acc_carry_o(c4));
 ee_int8_mesh_4x4 u_int8(
   .clk_i(clk_i),.rst_ni(rst_ni),.clear_i(start_i || mode_q!=1),
   .a_west_i(skew_a8),
   .b_north_i(skew_b8),
   .a_valid_i(skew_av8),
   .b_valid_i(skew_bv8),
   .acc_update_o(u8),.acc_valid_o(v8),
   .acc_sum_o(s8),.acc_carry_o(c8));
 ee_bf16_simd2 u_bf16(
   .clk_i(clk_i),.rst_ni(rst_ni),.clear_i(start_i || mode_q!=2),
   .in_valid_i({2{valid_q && mode_q==2}}),.in_ready_o(bf_ready),
   .lhs_i(mode_q==2 ? lhs_q[63:0] : 64'b0),
   .rhs_i(mode_q==2 ? rhs_q[63:0] : 64'b0),
   .out_valid_o(bf_valid),.result_o(bf_result));

 wire [511:0] canonical_s4,canonical_c4,canonical_s8,canonical_c8;
 assign canonical_s4[0+:32]=s4[0+:32];
 assign canonical_c4[0+:32]=c4[0+:32];
 assign canonical_s4[32+:32]=s4[32+:32];
 assign canonical_c4[32+:32]=c4[32+:32];
 assign canonical_s4[64+:32]=s4[64+:32];
 assign canonical_c4[64+:32]=c4[64+:32];
 assign canonical_s4[96+:32]=s4[96+:32];
 assign canonical_c4[96+:32]=c4[96+:32];
 assign canonical_s4[128+:32]=s4[128+:32];
 assign canonical_c4[128+:32]=c4[128+:32];
 assign canonical_s4[160+:32]=s4[160+:32];
 assign canonical_c4[160+:32]=c4[160+:32];
 assign canonical_s4[192+:32]=s4[192+:32];
 assign canonical_c4[192+:32]=c4[192+:32];
 assign canonical_s4[224+:32]=s4[224+:32];
 assign canonical_c4[224+:32]=c4[224+:32];
 assign canonical_s4[256+:32]=s4[256+:32];
 assign canonical_c4[256+:32]=c4[256+:32];
 assign canonical_s4[288+:32]=s4[288+:32];
 assign canonical_c4[288+:32]=c4[288+:32];
 assign canonical_s4[320+:32]=s4[320+:32];
 assign canonical_c4[320+:32]=c4[320+:32];
 assign canonical_s4[352+:32]=s4[352+:32];
 assign canonical_c4[352+:32]=c4[352+:32];
 assign canonical_s4[384+:32]=s4[384+:32];
 assign canonical_c4[384+:32]=c4[384+:32];
 assign canonical_s4[416+:32]=s4[416+:32];
 assign canonical_c4[416+:32]=c4[416+:32];
 assign canonical_s4[448+:32]=s4[448+:32];
 assign canonical_c4[448+:32]=c4[448+:32];
 assign canonical_s4[480+:32]=s4[480+:32];
 assign canonical_c4[480+:32]=c4[480+:32];
 assign canonical_s8[0+:32]=s8[0+:32];
 assign canonical_c8[0+:32]=c8[0+:32];
 assign canonical_s8[32+:32]=s8[32+:32];
 assign canonical_c8[32+:32]=c8[32+:32];
 assign canonical_s8[64+:32]=s8[64+:32];
 assign canonical_c8[64+:32]=c8[64+:32];
 assign canonical_s8[96+:32]=s8[96+:32];
 assign canonical_c8[96+:32]=c8[96+:32];
 assign canonical_s8[128+:32]=s8[128+:32];
 assign canonical_c8[128+:32]=c8[128+:32];
 assign canonical_s8[160+:32]=s8[160+:32];
 assign canonical_c8[160+:32]=c8[160+:32];
 assign canonical_s8[192+:32]=s8[192+:32];
 assign canonical_c8[192+:32]=c8[192+:32];
 assign canonical_s8[224+:32]=s8[224+:32];
 assign canonical_c8[224+:32]=c8[224+:32];
 assign canonical_s8[256+:32]=s8[256+:32];
 assign canonical_c8[256+:32]=c8[256+:32];
 assign canonical_s8[288+:32]=s8[288+:32];
 assign canonical_c8[288+:32]=c8[288+:32];
 assign canonical_s8[320+:32]=s8[320+:32];
 assign canonical_c8[320+:32]=c8[320+:32];
 assign canonical_s8[352+:32]=s8[352+:32];
 assign canonical_c8[352+:32]=c8[352+:32];
 assign canonical_s8[384+:32]=s8[384+:32];
 assign canonical_c8[384+:32]=c8[384+:32];
 assign canonical_s8[416+:32]=s8[416+:32];
 assign canonical_c8[416+:32]=c8[416+:32];
 assign canonical_s8[448+:32]=s8[448+:32];
 assign canonical_c8[448+:32]=c8[448+:32];
 assign canonical_s8[480+:32]=s8[480+:32];
 assign canonical_c8[480+:32]=c8[480+:32];
 wire corner_update=mode_q==0 ? u4[15] : u8[15];
 always_ff @(posedge clk_i) begin
   if(take) begin lhs_q<=lhs_i;rhs_q<=rhs_i;end
   if(state_q==CAPTURE) begin
     integer_sum_q<=mode_q==0 ? canonical_s4 : canonical_s8;
     integer_carry_q<=mode_q==0 ? canonical_c4 : canonical_c8;
   end
   if(take && mode_q==2)
     bf_last_mem[accept_ptr_q]<=data_last_i;
   if(bf_push) bf_mem[write_ptr_q]<=bf_result;
 end

 always_ff @(posedge clk_i or negedge rst_ni) begin
   if(!rst_ni) begin
     state_q<=IDLE;mode_q<=0;tile_q<=0;valid_q<=0;done_o<=0;
     last_seen_q<=0;accepted_q<=0;corner_q<=0;
     accept_ptr_q<=0;write_ptr_q<=0;read_ptr_q<=0;
     credits_q<=0;queued_q<=0;
   end else begin
     done_o<=0;valid_q<=take;
     if(start_i && ready_o) begin
       state_q<=FEED;mode_q<=precision_i;tile_q<=tile_id_i;
       last_seen_q<=0;accepted_q<=0;corner_q<=0;valid_q<=0;
       accept_ptr_q<=0;write_ptr_q<=0;read_ptr_q<=0;
       credits_q<=0;queued_q<=0;
     end else begin
       if(take) begin
         accepted_q<=accepted_q+16'd1;
         if(data_last_i) begin last_seen_q<=1;state_q<=DRAIN;end
       end
       if(mode_q==2) begin
         case({take,pop})
           2'b10:credits_q<=ee_credits_inc;
           2'b01:credits_q<=ee_credits_dec;
           default:;
         endcase
         case({bf_push,pop})
           2'b10:queued_q<=ee_queued_inc;
           2'b01:queued_q<=ee_queued_dec;
           default:;
         endcase
         if(take) accept_ptr_q<=accept_ptr_q+1'b1;
         if(bf_push) write_ptr_q<=write_ptr_q+1'b1;
         if(pop) read_ptr_q<=read_ptr_q+1'b1;
       end else if(
         (state_q==FEED || state_q==DRAIN) && corner_update
       ) begin
         corner_q<=corner_q+16'd1;
         if(last_seen_q && corner_q+16'd1==accepted_q)
           state_q<=CAPTURE;
       end
       if(state_q==CAPTURE) state_q<=HOLD;
       if(pop && result_last_o) begin state_q<=IDLE;done_o<=1;end
     end
   end
 end
`ifndef SYNTHESIS
 always @(posedge clk_i) if(rst_ni) begin
   if(start_i && !ready_o)
     $fatal(1,"Compute group launched while busy");
   if(start_i && precision_i==3)
     $fatal(1,"Reserved precision launched");
   if(mode_q==2 && bf_valid!=0 && bf_valid!=3)
     $fatal(1,"BF16 lanes lost pairing");
   if(credits_q>64 || queued_q>64)
     $fatal(1,"BF16 FIFO credit overflow");
   if(bf_push && queued_q==64 && !pop)
     $fatal(1,"BF16 result FIFO overflow");
   if(take && accepted_q==16'hffff)
     $fatal(1,"Frame exceeds 65535 beats");
 end
`endif
endmodule

module ee_mixed_compute_fabric #(parameter integer TILE_ID_W=16)(
 input wire clk_i,rst_ni,
 input wire [3:0] engine_start_i,
 input wire [4*TILE_ID_W-1:0] engine_tile_id_i,
 input wire [1:0] precision_i,
 output wire [3:0] engine_ready_o,engine_done_o,
 input wire [3:0] data_valid_i,data_last_i,
 input wire [511:0] lhs_i,rhs_i,
 output wire [3:0] data_ready_o,
 output wire [3:0] result_valid_o,input wire [3:0] result_ready_i,
 output wire [3:0] result_last_o,
 output wire [7:0] result_precision_o,
 output wire [4*TILE_ID_W-1:0] result_tile_id_o,
 output wire [2047:0] result_sum_o,result_carry_o
);
 for(genvar g=0;g<4;g=g+1) begin: GROUP
   ee_compute_group_stream #(.TILE_ID_W(TILE_ID_W)) u_group(
     .clk_i(clk_i),.rst_ni(rst_ni),.start_i(engine_start_i[g]),
     .tile_id_i(engine_tile_id_i[g*TILE_ID_W+:TILE_ID_W]),
     .precision_i(precision_i),
     .ready_o(engine_ready_o[g]),.done_o(engine_done_o[g]),
     .data_valid_i(data_valid_i[g]),.data_last_i(data_last_i[g]),
     .lhs_i(lhs_i[g*128+:128]),.rhs_i(rhs_i[g*128+:128]),
     .data_ready_o(data_ready_o[g]),
     .result_valid_o(result_valid_o[g]),
     .result_ready_i(result_ready_i[g]),
     .result_last_o(result_last_o[g]),
     .result_precision_o(result_precision_o[g*2+:2]),
     .result_tile_id_o(result_tile_id_o[g*TILE_ID_W+:TILE_ID_W]),
     .result_sum_o(result_sum_o[g*512+:512]),
     .result_carry_o(result_carry_o[g*512+:512]));
 end
endmodule
`default_nettype wire
