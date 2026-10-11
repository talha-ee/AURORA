 integer fd,rc,used,n,expected_mode,waited,cycle=0,begin_cycle;
 integer sent[0:3],received[0:3],ids[0:3];
 integer offsets[0:255],lengths[0:255];
 logic active[0:3],seen[0:255],held[0:3];
 logic [1042:0] held_data[0:3];
 logic [127:0] amem[0:65535],bmem[0:65535];
 string command,apath,bpath,opath,lpath;
 integer launched=0,retired=0;
 always @(posedge clk_i) begin
   cycle=cycle+1;
   if(rst_ni) for(integer g=0;g<4;g=g+1) begin
     if(dut.engine_start[g]) begin
       if(active[g]) $fatal(1,"Busy group launched");
       ids[g]=dut.engine_tile_id[g*16+:16];
       if(ids[g]>=n || seen[ids[g]]) $fatal(1,"Invalid tile launch");
       seen[ids[g]]=1;active[g]=1;sent[g]=0;received[g]=0;launched=launched+1;
     end
     if(data_valid_i[g] && data_ready_o[g]) sent[g]=sent[g]+1;
     if(held[g] && (!result_valid_o[g] || held_data[g]!==
       {result_last_o[g],result_precision_o[g*2+:2],result_tile_id_o[g*16+:16],
        result_sum_o[g*512+:512],result_carry_o[g*512+:512]}))
       $fatal(1,"Stalled result changed");
     held[g]=result_valid_o[g] && !result_ready_i[g];
     held_data[g]={result_last_o[g],result_precision_o[g*2+:2],
       result_tile_id_o[g*16+:16],result_sum_o[g*512+:512],result_carry_o[g*512+:512]};
     if(result_valid_o[g] && result_ready_i[g]) begin
       if(!active[g] || result_tile_id_o[g*16+:16]!=ids[g] ||
          result_precision_o[g*2+:2]!=expected_mode ||
          (^result_sum_o[g*512+:512])===1'bx ||
          (^result_carry_o[g*512+:512])===1'bx) $fatal(1,"Invalid result");
       if(result_last_o[g] !== (expected_mode!=2 || received[g]==lengths[ids[g]]-1))
         $fatal(1,"Invalid result last");
       $display("EE_RESULT %0d %0d %h %h",ids[g],received[g],
         result_sum_o[g*512+:512],result_carry_o[g*512+:512]);
       received[g]=received[g]+1;
       if(result_last_o[g]) begin
         if(sent[g]!=lengths[ids[g]]) $fatal(1,"Input count mismatch");
         active[g]=0;retired=retired+1;
       end
     end
   end
 end
 always @(negedge clk_i) begin
   data_valid_i=0;data_last_i=0;lhs_i=0;rhs_i=0;
   result_ready_i=(cycle%11==0)?4'b0:4'b1111;
   for(integer g=0;g<4;g=g+1) if(active[g] && sent[g]<lengths[ids[g]]) begin
     data_valid_i[g]=1;data_last_i[g]=(sent[g]==lengths[ids[g]]-1);
     lhs_i[g*128+:128]=amem[offsets[ids[g]]+sent[g]];
     rhs_i[g*128+:128]=bmem[offsets[ids[g]]+sent[g]];
   end
 end
 initial begin
   rst_ni=0;enable_i=1;energy_budget_i=1024;energy_used_i=650;
   power_level_i=0;thermal_level_i=0;improvement_i=100;improvement_valid_i=0;
   start_i=0;total_tiles_i=0;data_valid_i=0;data_last_i=0;lhs_i=0;rhs_i=0;
   result_ready_i=15;n=0;expected_mode=1;
   for(integer g=0;g<4;g=g+1) begin active[g]=0;held[g]=0;sent[g]=0;received[g]=0;end
   repeat(4) @(negedge clk_i);rst_ni=1;
   fd=$fopen("/dev/stdin","r");if(!fd)$fatal(1,"stdin unavailable");
   $display("EE_READY");$fflush();
   forever begin
     rc=$fscanf(fd,"%s",command);
     if(rc!=1)$finish;
     if(command=="Q")$finish;
     else if(command=="C") begin
       rc=$fscanf(fd,"%d",used);if(rc!=1)$fatal(1,"Bad config");
       @(negedge clk_i);energy_used_i=used;
       repeat(100)@(negedge clk_i);
       if(reconfiguration_pending_o || !scheduler_ready_o)$fatal(1,"Config did not settle");
       $display("EE_CONFIG %0d %0d %0d %0d %0d %0d %0d",precision_mode_o,
         compute_group_enable_o,adaptation_rank_o,update_interval_o,
         adaptation_scope_o,training_enable_o,cycle);$fflush();
     end else if(command=="G") begin
       rc=$fscanf(fd,"%d %d %s %s %s %s",n,expected_mode,apath,bpath,opath,lpath);
       if(rc!=6 || n<1 || n>256 || precision_mode_o!=expected_mode)$fatal(1,"Bad GEMM job");
       $readmemh(apath,amem);$readmemh(bpath,bmem);
       $readmemh(opath,offsets,0,n-1);$readmemh(lpath,lengths,0,n-1);
       for(integer t=0;t<n;t=t+1) begin
         seen[t]=0;if(lengths[t]<1 || offsets[t]+lengths[t]>65536)$fatal(1,"Frame out of range");
       end
       launched=0;retired=0;
       @(negedge clk_i);begin_cycle=cycle;total_tiles_i=n;start_i=1;
       @(negedge clk_i);start_i=0;waited=0;
       while(!job_done_o && waited<2000000) begin @(negedge clk_i);waited=waited+1;end
       if(!job_done_o || launched!=n || retired!=n || tiles_issued_o!=n || tiles_completed_o!=n)
         $fatal(1,"Job accounting/timeout: %0d %0d",tiles_issued_o,tiles_completed_o);
       for(integer t=0;t<n;t=t+1)if(!seen[t])$fatal(1,"Missing tile");
       repeat(10)@(negedge clk_i);
       $display("EE_DONE %0d %0d %0d",n,cycle-begin_cycle,cycle);$fflush();
     end else $fatal(1,"Unknown command");
   end
 end
endmodule
