// convert the remaining i_ctime accesses
@@
struct inode *inode;
@@
- inode->i_ctime
+ inode_get_ctime(inode)
