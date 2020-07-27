// SPDX-License-Identifier: GPL-2.0
/*
 * Ceph fscrypt functionality
 */

#ifndef _CEPH_CRYPTO_H
#define _CEPH_CRYPTO_H

#ifdef CONFIG_FS_ENCRYPTION

#define	CEPH_XATTR_NAME_ENCRYPTION_CONTEXT	"encryption.ctx"

int ceph_fscrypt_set_ops(struct super_block *sb);

#else /* CONFIG_FS_ENCRYPTION */

static inline int ceph_fscrypt_set_ops(struct super_block *sb)
{
	return 0;
}

#endif /* CONFIG_FS_ENCRYPTION */

#endif
