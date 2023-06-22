@@
struct inode *inode;
@@
- inode->i_ctime = current_time(inode)
+ inode_set_ctime_current(inode)

@@
struct inode *inode;
expression E1;
@@
- inode->i_ctime = E1 = current_time(inode)
+ E1 = inode_set_ctime_current(inode)

@@
struct inode *inode;
struct timespec64 ts;
@@
- inode->i_ctime = ts
+ inode_set_ctime(inode, ts.tv_sec, ts.tv_nsec)

@@
struct inode *inode;
expression sec, E1, E2;
@@
- inode->i_ctime.tv_sec = sec
+ inode_set_ctime(inode, sec, 0)
...
(
- inode->i_ctime.tv_nsec = 0;
|
- E1 = inode->i_ctime.tv_nsec = 0
+ E1 = 0
|
- inode->i_ctime.tv_nsec = E1 = 0
+ E1 = 0
|
- inode->i_ctime.tv_nsec = E1 = E2 = 0
+ E1 = E2 = 0
)

@@
struct inode *inode;
expression val, val2;
@@
- inode->i_ctime.tv_sec = val
+ inode_set_ctime(inode, val, val2)
...
- inode->i_ctime.tv_nsec = val2;

@@
struct inode *inode;
@@
- inode->i_ctime
+ inode_ctime_get(inode)

