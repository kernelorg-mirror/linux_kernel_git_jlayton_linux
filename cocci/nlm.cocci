@@
struct nlm_lock *nlck;
@@
(
- nlck->fl.fl_blocker
+ nlck->fl.fl_core.flc_blocker
|
- nlck->fl.fl_list
+ nlck->fl.fl_core.flc_list
|
- nlck->fl.fl_link
+ nlck->fl.fl_core.flc_link
|
- nlck->fl.fl_blocked_requests
+ nlck->fl.fl_core.flc_blocked_requests
|
- nlck->fl.fl_blocked_member
+ nlck->fl.fl_core.flc_blocked_member
|
- nlck->fl.fl_owner
+ nlck->fl.fl_core.flc_owner
|
- nlck->fl.fl_flags
+ nlck->fl.fl_core.flc_flags
|
- nlck->fl.fl_type
+ nlck->fl.fl_core.flc_type
|
- nlck->fl.fl_pid
+ nlck->fl.fl_core.flc_pid
|
- nlck->fl.fl_link_cpu
+ nlck->fl.fl_core.flc_link_cpu
|
- nlck->fl.fl_wait
+ nlck->fl.fl_core.flc_wait
|
- nlck->fl.fl_file
+ nlck->fl.fl_core.flc_file
)

@@
struct nlm_args *argp;
@@
(
- argp->lock.fl.fl_blocker
+ argp->lock.fl.fl_core.flc_blocker
|
- argp->lock.fl.fl_list
+ argp->lock.fl.fl_core.flc_list
|
- argp->lock.fl.fl_link
+ argp->lock.fl.fl_core.flc_link
|
- argp->lock.fl.fl_blocked_requests
+ argp->lock.fl.fl_core.flc_blocked_requests
|
- argp->lock.fl.fl_blocked_member
+ argp->lock.fl.fl_core.flc_blocked_member
|
- argp->lock.fl.fl_owner
+ argp->lock.fl.fl_core.flc_owner
|
- argp->lock.fl.fl_flags
+ argp->lock.fl.fl_core.flc_flags
|
- argp->lock.fl.fl_type
+ argp->lock.fl.fl_core.flc_type
|
- argp->lock.fl.fl_pid
+ argp->lock.fl.fl_core.flc_pid
|
- argp->lock.fl.fl_link_cpu
+ argp->lock.fl.fl_core.flc_link_cpu
|
- argp->lock.fl.fl_wait
+ argp->lock.fl.fl_core.flc_wait
|
- argp->lock.fl.fl_file
+ argp->lock.fl.fl_core.flc_file
)
