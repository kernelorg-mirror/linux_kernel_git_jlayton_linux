// SPDX-License-Identifier: GPL-2.0-only
/*
 * Ceph cache definitions.
 *
 *  Copyright (C) 2013 by Adfin Solutions, Inc. All Rights Reserved.
 *  Written by Milosz Tanski (milosz@adfin.com)
 */

#include <linux/ceph/ceph_debug.h>

#include <linux/fs_context.h>
#include "super.h"
#include "cache.h"

struct ceph_aux_inode {
	u64 	version;
	u64	mtime_sec;
	u64	mtime_nsec;
};

struct fscache_netfs ceph_cache_netfs = {
	.name		= "ceph",
	.version	= 0,
};

static DEFINE_MUTEX(ceph_fscache_lock);
static LIST_HEAD(ceph_fscache_list);

struct ceph_fscache_entry {
	struct list_head list;
	struct fscache_cookie *fscache;
	size_t uniq_len;
	/* The following members must be last */
	struct ceph_fsid fsid;
	char uniquifier[];
};

int __init ceph_fscache_register(void)
{
	return fscache_register_netfs(&ceph_cache_netfs);
}

void ceph_fscache_unregister(void)
{
	fscache_unregister_netfs(&ceph_cache_netfs);
}

void ceph_fscache_use_cookie(struct inode *inode, bool will_modify)
{
	struct ceph_inode_info *ci = ceph_inode(inode);

	if (ci->fscache)
		fscache_use_cookie(ci->fscache, will_modify);
}

void ceph_fscache_unuse_cookie(struct inode *inode, bool update)
{
	struct ceph_inode_info *ci = ceph_inode(inode);

	if (!ci->fscache)
		return;

	if (update) {
		struct ceph_aux_inode aux = {
						.version = ci->i_version,
						.mtime_sec = inode->i_mtime.tv_sec,
						.mtime_nsec = inode->i_mtime.tv_nsec,
					    };
		loff_t i_size = i_size_read(inode);

		fscache_unuse_cookie(ci->fscache, &aux, &i_size);
	} else {
		fscache_unuse_cookie(ci->fscache, NULL, NULL);
	}
}

void ceph_fscache_update_cookie(struct inode *inode)
{
	struct ceph_inode_info *ci = ceph_inode(inode);
	struct ceph_aux_inode aux;
	loff_t i_size = i_size_read(inode);

	if (!ci->fscache)
		return;

	aux.version = ci->i_version;
	aux.mtime_sec = inode->i_mtime.tv_sec;
	aux.mtime_nsec = inode->i_mtime.tv_nsec;

	fscache_update_cookie(ci->fscache, &aux, &i_size);
}

int ceph_fscache_register_fs(struct ceph_fs_client* fsc, struct fs_context *fc)
{
	const struct ceph_fsid *fsid = &fsc->client->fsid;
	const char *fscache_uniq = fsc->mount_options->fscache_uniq;
	size_t uniq_len = fscache_uniq ? strlen(fscache_uniq) : 0;
	struct ceph_fscache_entry *ent;
	int err = 0;

	mutex_lock(&ceph_fscache_lock);
	list_for_each_entry(ent, &ceph_fscache_list, list) {
		if (memcmp(&ent->fsid, fsid, sizeof(*fsid)))
			continue;
		if (ent->uniq_len != uniq_len)
			continue;
		if (uniq_len && memcmp(ent->uniquifier, fscache_uniq, uniq_len))
			continue;

		errorfc(fc, "fscache cookie already registered for fsid %pU, use fsc=<uniquifier> option",
		       fsid);
		err = -EBUSY;
		goto out_unlock;
	}

	ent = kzalloc(sizeof(*ent) + uniq_len, GFP_KERNEL);
	if (!ent) {
		err = -ENOMEM;
		goto out_unlock;
	}

	memcpy(&ent->fsid, fsid, sizeof(*fsid));
	if (uniq_len > 0) {
		memcpy(&ent->uniquifier, fscache_uniq, uniq_len);
		ent->uniq_len = uniq_len;
	}

	fsc->fscache = fscache_acquire_cookie(ceph_cache_netfs.primary_index,
					      FSCACHE_COOKIE_TYPE_INDEX,
					      "CEPH.fsid", 0, NULL, &ent->fsid,
					      sizeof(ent->fsid) + uniq_len, NULL, 0, 0);
	if (fsc->fscache) {
		ent->fscache = fsc->fscache;
		list_add_tail(&ent->list, &ceph_fscache_list);
	} else {
		pr_warn("Unable to set primary index for fscache! Disabling it.\n");
		kfree(ent);
	}
out_unlock:
	mutex_unlock(&ceph_fscache_lock);
	return err;
}

void ceph_fscache_register_inode_cookie(struct inode *inode)
{
	struct ceph_inode_info *ci = ceph_inode(inode);
	struct ceph_fs_client *fsc = ceph_inode_to_client(inode);
	struct ceph_aux_inode aux;

	/* Register only new inodes */
	if (!(inode->i_state & I_NEW))
		return;

	/* No caching for filesystem */
	if (!fsc->fscache)
		return;

	WARN_ON_ONCE(ci->fscache);

	memset(&aux, 0, sizeof(aux));
	aux.version = ci->i_version;
	aux.mtime_sec = inode->i_mtime.tv_sec;
	aux.mtime_nsec = inode->i_mtime.tv_nsec;
	ci->fscache = fscache_acquire_cookie(fsc->fscache,
					     FSCACHE_COOKIE_TYPE_DATAFILE,
					     "CEPH.inode", 0, NULL,
					     &ci->i_vino,
					     sizeof(ci->i_vino),
					     &aux, sizeof(aux),
					     i_size_read(inode));
}

void ceph_fscache_unregister_inode_cookie(struct ceph_inode_info* ci)
{
	struct fscache_cookie* cookie = xchg(&ci->fscache, NULL);

	if (cookie)
		fscache_relinquish_cookie(cookie, false);
}

void ceph_fscache_invalidate(struct inode *inode, unsigned int flags)
{
	struct ceph_inode_info *ci = ceph_inode(inode);
	struct ceph_aux_inode aux = { .version		= ci->i_version,
				      .mtime_sec	= inode->i_mtime.tv_sec,
				      .mtime_nsec	= inode->i_mtime.tv_nsec };

	aux.version = ci->i_version;
	aux.mtime_sec = inode->i_mtime.tv_sec;
	aux.mtime_nsec = inode->i_mtime.tv_nsec;

	fscache_invalidate(ceph_inode(inode)->fscache, &aux, i_size_read(inode), flags);
}

void ceph_fscache_unregister_fs(struct ceph_fs_client* fsc)
{
	if (fscache_cookie_valid(fsc->fscache)) {
		struct ceph_fscache_entry *ent;
		bool found = false;

		mutex_lock(&ceph_fscache_lock);
		list_for_each_entry(ent, &ceph_fscache_list, list) {
			if (ent->fscache == fsc->fscache) {
				list_del(&ent->list);
				kfree(ent);
				found = true;
				break;
			}
		}
		WARN_ON_ONCE(!found);
		mutex_unlock(&ceph_fscache_lock);

		__fscache_relinquish_cookie(fsc->fscache, false);
	}
	fsc->fscache = NULL;
}
