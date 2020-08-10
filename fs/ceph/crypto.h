// SPDX-License-Identifier: GPL-2.0
/*
 * Ceph fscrypt functionality
 */

#ifndef _CEPH_CRYPTO_H
#define _CEPH_CRYPTO_H

#include <linux/fscrypt.h>

#ifdef CONFIG_FS_ENCRYPTION

#define	CEPH_XATTR_NAME_ENCRYPTION_CONTEXT	"encryption.ctx"

void ceph_fscrypt_set_ops(struct super_block *sb);
int ceph_fscrypt_prepare_context(struct inode *dir, struct inode *inode,
				 struct ceph_acl_sec_ctx *as);

static inline int ceph_fname_alloc_buffer(struct inode *parent, struct fscrypt_str *fname)
{
	if (!IS_ENCRYPTED(parent))
		return 0;
	return fscrypt_fname_alloc_buffer(NAME_MAX, fname);
}

static inline void ceph_fname_free_buffer(struct inode *parent, struct fscrypt_str *fname)
{
	if (IS_ENCRYPTED(parent))
		fscrypt_fname_free_buffer(fname);
}

int ceph_fname_to_usr(struct inode *parent, char *name, u32 len, struct fscrypt_str *tname,
			struct fscrypt_str *oname, bool *is_nokey);

#else /* CONFIG_FS_ENCRYPTION */

static inline int ceph_fscrypt_set_ops(struct super_block *sb)
{
	return 0;
}

static inline int ceph_fscrypt_prepare_context(struct inode *dir, struct inode *inode,
						struct ceph_acl_sec_ctx *as)
{
	return 0;
}

static inline int ceph_fname_alloc_buffer(struct inode *parent, struct fscrypt_str *fname)
{
	return 0;
}

static inline void ceph_fname_free_buffer(struct inode *parent, struct fscrypt_str *fname)
{
}

static inline int ceph_fname_to_usr(struct inode *inode, char *name, u32 len,
			struct fscrypt_str *tname, struct fscrypt_str *oname, bool *is_nokey)
{
	oname->name = dname;
	oname->len = dlen;
	return 0;
}

#endif /* CONFIG_FS_ENCRYPTION */

#endif
