/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_FS_STACK_H
#define _LINUX_FS_STACK_H

/* This file defines generic functions used primarily by stackable
 * filesystems; none of these functions require i_mutex to be held.
 */

#include <linux/fs.h>

/* externs for fs/stack.c */
extern void fsstack_copy_attr_all(struct inode *dest, const struct inode *src);
extern void fsstack_copy_inode_size(struct inode *dst, struct inode *src);

/* inlines */
static inline void fsstack_copy_attr_atime(struct inode *dest,
					   const struct inode *src)
{
	dest->i_atime = src->i_atime;
}

static inline void fsstack_copy_attr_times(struct inode *dest,
					   const struct inode *src)
{
	struct timespec64 ctime;

	dest->i_atime = src->i_atime;
	dest->i_mtime = src->i_mtime;
	ctime = inode_get_ctime(src);
	inode_set_ctime(dest, ctime.tv_sec, ctime.tv_nsec);
}

#endif /* _LINUX_FS_STACK_H */
