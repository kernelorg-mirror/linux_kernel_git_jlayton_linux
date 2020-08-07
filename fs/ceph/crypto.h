/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Ceph fscrypt functionality
 */

#ifndef _CEPH_CRYPTO_H
#define _CEPH_CRYPTO_H

#include <crypto/sha2.h>
#include <linux/fscrypt.h>

#define	CEPH_XATTR_NAME_ENCRYPTION_CONTEXT	"encryption.ctx"

#ifdef CONFIG_FS_ENCRYPTION
struct ceph_fs_client;
struct ceph_acl_sec_ctx;
struct ceph_mds_request;

#define CEPH_FSCRYPT_AUTH_VERSION	1
struct ceph_fscrypt_auth {
	__le32	cfa_version;
	__le32	cfa_blob_len;
	u8	cfa_blob[FSCRYPT_SET_CONTEXT_MAX_SIZE];
} __packed;

static inline u32 ceph_fscrypt_auth_size(u32 ctxsize)
{
	return offsetof(struct ceph_fscrypt_auth, cfa_blob) + ctxsize;
}

/*
 * We want to encrypt filenames when creating them, but the encrypted
 * versions of those names may have illegal characters in them. To mitigate
 * that, we base64 encode them, but that gives us a result that can exceed
 * NAME_MAX.
 *
 * Follow a similar scheme to fscrypt itself, and cap the filename to a
 * smaller size. If the cleartext name is longer than the value below, then
 * sha256 hash the remaining bytes.
 *
 * 189 bytes => 252 bytes base64-encoded, which is <= NAME_MAX (255)
 */
#define CEPH_NOHASH_NAME_MAX (189 - SHA256_DIGEST_SIZE)

void ceph_fscrypt_set_ops(struct super_block *sb);

void ceph_fscrypt_free_dummy_policy(struct ceph_fs_client *fsc);

int ceph_fscrypt_prepare_context(struct inode *dir, struct inode *inode,
				 struct ceph_acl_sec_ctx *as);
void ceph_fscrypt_as_ctx_to_req(struct ceph_mds_request *req, struct ceph_acl_sec_ctx *as);

#else /* CONFIG_FS_ENCRYPTION */

static inline void ceph_fscrypt_set_ops(struct super_block *sb)
{
}

static inline void ceph_fscrypt_free_dummy_policy(struct ceph_fs_client *fsc)
{
}

static inline int ceph_fscrypt_prepare_context(struct inode *dir, struct inode *inode,
						struct ceph_acl_sec_ctx *as)
{
	if (IS_ENCRYPTED(dir))
		return -EOPNOTSUPP;
	return 0;
}

static inline void ceph_fscrypt_as_ctx_to_req(struct ceph_mds_request *req,
						struct ceph_acl_sec_ctx *as_ctx)
{
}
#endif /* CONFIG_FS_ENCRYPTION */

#endif
