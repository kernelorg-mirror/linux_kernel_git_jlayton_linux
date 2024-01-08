@@
struct file_lock *fl;
@@
(
- fl->fl_blocker
+ fl->fl_core.flc_blocker
|
- fl->fl_list
+ fl->fl_core.flc_list
|
- fl->fl_link
+ fl->fl_core.flc_link
|
- fl->fl_blocked_requests
+ fl->fl_core.flc_blocked_requests
|
- fl->fl_blocked_member
+ fl->fl_core.flc_blocked_member
|
- fl->fl_owner
+ fl->fl_core.flc_owner
|
- fl->fl_flags
+ fl->fl_core.flc_flags
|
- fl->fl_type
+ fl->fl_core.flc_type
|
- fl->fl_pid
+ fl->fl_core.flc_pid
|
- fl->fl_link_cpu
+ fl->fl_core.flc_link_cpu
|
- fl->fl_wait
+ fl->fl_core.flc_wait
|
- fl->fl_file
+ fl->fl_core.flc_file
)

@@
struct file_lock fl;
@@
(
- fl.fl_blocker
+ fl.fl_core.flc_blocker
|
- fl.fl_list
+ fl.fl_core.flc_list
|
- fl.fl_link
+ fl.fl_core.flc_link
|
- fl.fl_blocked_requests
+ fl.fl_core.flc_blocked_requests
|
- fl.fl_blocked_member
+ fl.fl_core.flc_blocked_member
|
- fl.fl_owner
+ fl.fl_core.flc_owner
|
- fl.fl_flags
+ fl.fl_core.flc_flags
|
- fl.fl_type
+ fl.fl_core.flc_type
|
- fl.fl_pid
+ fl.fl_core.flc_pid
|
- fl.fl_link_cpu
+ fl.fl_core.flc_link_cpu
|
- fl.fl_wait
+ fl.fl_core.flc_wait
|
- fl.fl_file
+ fl.fl_core.flc_file
)

@@
struct file_lock *fl;
struct list_head *li;
@@
- list_for_each_entry(fl, li, fl_list)
+ list_for_each_entry(fl, li, fl_core.flc_list)
