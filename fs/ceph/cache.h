/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Ceph cache definitions.
 *
 *  Copyright (C) 2013 by Adfin Solutions, Inc. All Rights Reserved.
 *  Written by Milosz Tanski (milosz@adfin.com)
 */

#ifndef _CEPH_CACHE_H
#define _CEPH_CACHE_H

#ifdef CONFIG_CEPH_FSCACHE

extern struct fscache_netfs ceph_cache_netfs;

int ceph_fscache_register(void);
void ceph_fscache_unregister(void);

int ceph_fscache_register_fs(struct ceph_fs_client* fsc, struct fs_context *fc);
void ceph_fscache_unregister_fs(struct ceph_fs_client* fsc);

void ceph_fscache_register_inode_cookie(struct inode *inode);
void ceph_fscache_unregister_inode_cookie(struct ceph_inode_info* ci);

void ceph_fscache_use_cookie(struct inode *inode, bool will_modify);
void ceph_fscache_unuse_cookie(struct inode *inode, bool update);

void ceph_fscache_update_cookie(struct inode *inode);
void ceph_fscache_invalidate(struct inode *inode, unsigned int flags);

static inline void ceph_fscache_inode_init(struct ceph_inode_info *ci)
{
	ci->fscache = NULL;
}

static inline struct fscache_cookie *ceph_fscache_cookie(struct ceph_inode_info *ci)
{
	return ci->fscache;
}

static inline void ceph_wait_on_page_fscache(struct page *page)
{
	wait_on_page_fscache(page);
}

static inline void ceph_fscache_resize_cookie(struct ceph_inode_info *ci, loff_t new_size)
{
	struct fscache_cookie *cookie = ceph_fscache_cookie(ci);

	if (cookie)
		fscache_resize_cookie(cookie, new_size);
}
#else /* CONFIG_CEPH_FSCACHE */

static inline int ceph_fscache_register(void)
{
	return 0;
}

static inline void ceph_fscache_unregister(void)
{
}

static inline int ceph_fscache_register_fs(struct ceph_fs_client* fsc,
					   struct fs_context *fc)
{
	return 0;
}

static inline void ceph_fscache_unregister_fs(struct ceph_fs_client* fsc)
{
}

static inline void ceph_fscache_inode_init(struct ceph_inode_info *ci)
{
}

static inline void ceph_fscache_register_inode_cookie(struct inode *inode)
{
}

static inline void ceph_fscache_unregister_inode_cookie(struct ceph_inode_info* ci)
{
}

static inline void ceph_fscache_use_cookie(struct inode *inode, bool will_modify)
{
}

static inline void ceph_fscache_unuse_cookie(struct inode *inode, bool update)
{
}

static inline void ceph_fscache_update_cookie(struct inode *inode)
{
}

static inline void ceph_fscache_invalidate(struct inode *inode, unsigned int flags)
{
}

static inline struct fscache_cookie *ceph_fscache_cookie(struct ceph_inode_info *ci)
{
	return NULL;
}

static inline void ceph_wait_on_page_fscache(struct page *page)
{
}

static inline void ceph_fscache_resize_cookie(struct ceph_inode_info *ci, loff_t new_size)
{
}
#endif /* CONFIG_CEPH_FSCACHE */

#endif
