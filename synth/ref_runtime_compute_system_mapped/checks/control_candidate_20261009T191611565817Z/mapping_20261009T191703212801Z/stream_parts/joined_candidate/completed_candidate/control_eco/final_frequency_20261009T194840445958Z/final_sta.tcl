if {[catch {
puts EE_READ_LIBERTY; flush stdout
read_liberty {/home/alien/.volare/volare/sky130/versions/0fe599b2afb6708d281543108caf8310912f54af/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib}
puts EE_READ_VERILOG; flush stdout
read_verilog {synth/ref_runtime_compute_system_mapped/checks/control_candidate_20261009T191611565817Z/mapping_20261009T191703212801Z/stream_parts/joined_candidate/completed_candidate/control_eco/runtime_compute_system_control_eco_500mhz_sta_compatible.v}
puts EE_LINK_DESIGN; flush stdout
link_design ee_runtime_compute_system
report_units
proc ee_at {period} {
create_clock -name core_clk -period $period [get_ports clk_i]
set_clock_uncertainty 0.050 [get_clocks core_clk]
set nonclock_inputs [get_ports {rst_ni enable_i energy_budget_i* energy_used_i* power_level_i* thermal_level_i* improvement_i* improvement_valid_i start_i total_tiles_i* data_valid_i* data_last_i* lhs_i* rhs_i* result_ready_i*}]
set_input_delay 0.100 -clock core_clk $nonclock_inputs
set_input_transition 0.050 $nonclock_inputs
set_output_delay 0.100 -clock core_clk [all_outputs]
set_load 0.005 [all_outputs]
set s [sta::worst_slack -max]
set h [sta::worst_slack -min]
if {abs($s)>1000 || abs($h)>1000} {error "Invalid timing values or units"}
if {$h<0} {error "Hold violation during search; no closure claimed"}
puts [format "EE_TRIAL %.9f %.9f %.9f" $period $s $h]; flush stdout
return $s
}
set lo 2.000000000
set slo [ee_at $lo]
if {abs($slo-(-1.483411000))>0.00001} {error "Baseline did not reproduce"}
if {$slo>=0} {error "Expected failing 2 ns baseline"}
set hi 3.883411000
set shi [ee_at $hi]
for {set k 0} {$shi<0 && $k<8} {incr k} {
set hi [expr {$hi+max(0.4,-2.0*$shi)}]
set shi [ee_at $hi]
}
if {$shi<0} {error "No passing upper period found"}
for {set k 0} {$hi-$lo>0.001 && $k<24} {incr k} {
set mid [expr {($lo+$hi)/2.0}]
set sm [ee_at $mid]
if {$sm>=0} {set hi $mid; set shi $sm} else {set lo $mid; set slo $sm}
}
puts [format "EE_BOUNDARY %.9f %.9f %.9f %.9f" $lo $hi $slo $shi]; flush stdout
set final [expr {ceil(max(3.883411000,$hi+0.4)*1000.0)/1000.0}]
set final_slack [ee_at $final]
if {$final_slack<0} {error "Final operating point failed setup"}
puts [format "EE_FINAL_PERIOD %.9f" $final]; flush stdout
puts EE_CHECK_SETUP_BEGIN; flush stdout
check_setup
puts EE_CHECK_SETUP_END; flush stdout
puts EE_FINAL_SUMMARY; flush stdout
report_worst_slack -max -digits 9
report_tns -digits 9
report_worst_slack -min -digits 9
report_tns -min -digits 9
puts EE_SETUP_PATHS; flush stdout
report_checks -path_delay max -format full_clock_expanded -fields {slew cap fanout} -group_path_count 3 -digits 6
puts EE_HOLD_PATHS; flush stdout
report_checks -path_delay min -format full_clock_expanded -fields {slew cap fanout} -group_path_count 2 -digits 6
puts EE_RECOVERY; flush stdout
report_check_types -recovery -digits 6
puts EE_REMOVAL; flush stdout
report_check_types -removal -digits 6
puts EE_SLEW; flush stdout
report_check_types -max_slew -digits 6
puts EE_CAP; flush stdout
report_check_types -max_capacitance -digits 6
puts EE_FINAL_FINISHED; flush stdout
} reason]} {
puts stderr "EE_STA_FATAL: $reason"
flush stderr
exit 2
}
exit
