// catch places that set the i_ctime in an inode embedded in another structure
@@
expression E1, E2, E3;
@@
(
- E3.i_ctime = E1 = E2 = current_time(&E3)
+ E1 = E2 = inode_set_ctime_current(&E3)
|
- E3.i_ctime = E1 = current_time(&E3)
+ E1 = inode_set_ctime_current(&E3)
|
- E1 = E3.i_ctime = current_time(&E3)
+ E1 = inode_set_ctime_current(&E3)
|
- E3.i_ctime = current_time(&E3)
+ inode_set_ctime_current(&E3)
)
