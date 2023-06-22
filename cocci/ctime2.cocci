// get the places that set individual timespec64 fields
@@
struct inode *inode;
expression val, val2;
@@
- inode->i_ctime.tv_sec = val
+ inode_set_ctime(inode, val, val2)
...
- inode->i_ctime.tv_nsec = val2;

// get places that just set the tv_sec
@@
struct inode *inode;
expression sec, E1, E2, E3;
@@
(
- E3 = inode->i_ctime.tv_sec = sec
+ E3 = inode_set_ctime(inode, sec, 0).tv_sec
|
- inode->i_ctime.tv_sec = sec
+ inode_set_ctime(inode, sec, 0)
)
<...
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
...>

