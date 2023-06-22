// convert as much to use inode_set_ctime_current as possible
@@
identifier timei;
struct inode *inode;
expression E1, E2;
@@
(
- inode->i_ctime = E1 = E2 = current_time(timei)
+ E1 = E2 = inode_set_ctime_current(inode)
|
- inode->i_ctime = E1 = current_time(timei)
+ E1 = inode_set_ctime_current(inode)
|
- E1 = inode->i_ctime = current_time(timei)
+ E1 = inode_set_ctime_current(inode)
|
- inode->i_ctime = current_time(timei)
+ inode_set_ctime_current(inode)
)

@@
struct inode *inode;
expression E1, E2, E3;
@@
(
- E1 = current_time(inode)
+ E1 = inode_set_ctime_current(inode)
|
- E1 = current_time(E3)
+ E1 = inode_set_ctime_current(inode)
)
...
(
- inode->i_ctime = E1;
|
- E2 = inode->i_ctime = E1;
+ E2 = E1;
)
