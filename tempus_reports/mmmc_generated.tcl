create_library_set -name lib_slow -timing [list /home/install/FOUNDRY/digital/90nm/dig/lib/slow.lib]
create_library_set -name lib_fast -timing [list /home/install/FOUNDRY/digital/90nm/dig/lib/fast.lib]
create_rc_corner -name rc_corner_nominal -T 25.0
create_delay_corner -name delay_corner_worst -library_set lib_slow -rc_corner rc_corner_nominal
create_delay_corner -name delay_corner_best  -library_set lib_fast -rc_corner rc_corner_nominal
create_constraint_mode -name constr_func -sdc_files [list tempus_reports/signoff_generated.sdc]
create_analysis_view -name worst_case -delay_corner delay_corner_worst -constraint_mode constr_func
create_analysis_view -name best_case  -delay_corner delay_corner_best  -constraint_mode constr_func
set_analysis_view -setup [list worst_case] -hold [list best_case]
