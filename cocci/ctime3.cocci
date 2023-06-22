// convert places that set i_ctime to a timespec64 directly
@@
struct inode *inode;
expression ts, E1, E2;
@@
(
- inode->i_ctime = E1 = E2 = ts
+ E1 = E2 = inode_set_ctime_to_ts(inode, ts)
|
- inode->i_ctime = E1 = ts
+ E1 = inode_set_ctime_to_ts(inode, ts)
|
- inode->i_ctime = ts
+ inode_set_ctime_to_ts(inode, ts)
)
