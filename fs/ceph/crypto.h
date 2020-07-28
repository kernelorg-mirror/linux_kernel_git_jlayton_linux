// SPDX-License-Identifier: GPL-2.0
/*
 * Ceph fscrypt functionality
 */

#ifndef _CEPH_CRYPTO_H
#define _CEPH_CRYPTO_H

#ifdef CONFIG_FS_ENCRYPTION

#define CEPH_XATTR_NAME_ENCRYPTION_CONTEXT	"encryption.ctx"

#define DUMMY_ENCRYPTION_ENABLED(fsc) ((fsc)->dummy_enc_ctx.ctx != NULL)

int ceph_fscrypt_set_ops(struct super_block *sb);
int ceph_fscrypt_new_context(struct inode *parent, struct ceph_acl_sec_ctx *as);

#else /* CONFIG_FS_ENCRYPTION */

#define DUMMY_ENCRYPTION_ENABLED(fsc) (0)

static inline int ceph_fscrypt_set_ops(struct super_block *sb)
{
	return 0;
}

static int ceph_fscrypt_new_context(struct inode *parent, struct ceph_acl_sec_ctx *as)
{
	return 0;
}

#endif /* CONFIG_FS_ENCRYPTION */

#endif
