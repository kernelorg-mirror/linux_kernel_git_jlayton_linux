// SPDX-License-Identifier: GPL-2.0
#include <linux/ceph/ceph_debug.h>
#include <linux/xattr.h>
#include <linux/fscrypt.h>

#include "super.h"
#include "crypto.h"

static int ceph_crypt_get_context(struct inode *inode, void *ctx, size_t len)
{
	int ret = __ceph_getxattr(inode, CEPH_XATTR_NAME_ENCRYPTION_CONTEXT, ctx, len);

	if (ret > 0)
		inode_set_flags(inode, S_ENCRYPTED, S_ENCRYPTED);
	return ret;
}

static int ceph_crypt_set_context(struct inode *inode, const void *ctx, size_t len, void *fs_data)
{
	int ret;

	WARN_ON_ONCE(fs_data);
	ret = __ceph_setxattr(inode, CEPH_XATTR_NAME_ENCRYPTION_CONTEXT, ctx, len, XATTR_CREATE);
	if (ret == 0)
		inode_set_flags(inode, S_ENCRYPTED, S_ENCRYPTED);
	return ret;
}

static bool ceph_crypt_empty_dir(struct inode *inode)
{
	struct ceph_inode_info *ci = ceph_inode(inode);

	return ci->i_rsubdirs + ci->i_rfiles == 1;
}

static const union fscrypt_context *
ceph_get_dummy_context(struct super_block *sb)
{
	return ceph_sb_to_client(sb)->dummy_enc_ctx.ctx;
}

static struct fscrypt_operations ceph_fscrypt_ops = {
	.key_prefix		= "ceph:",
	.get_context		= ceph_crypt_get_context,
	.set_context		= ceph_crypt_set_context,
	.get_dummy_context	= ceph_get_dummy_context,
	.empty_dir		= ceph_crypt_empty_dir,
	.max_namelen		= NAME_MAX,
};

int ceph_fscrypt_set_ops(struct super_block *sb)
{
	struct ceph_fs_client *fsc = sb->s_fs_info;

	fscrypt_set_ops(sb, &ceph_fscrypt_ops);

	if (ceph_test_mount_opt(fsc, TEST_DUMMY_ENC)) {
		substring_t arg = { };

		/* Ewwwwwwww */
		if (fsc->mount_options->test_dummy_encryption) {
			arg.from = fsc->mount_options->test_dummy_encryption;
			arg.to = arg.from + strlen(arg.from) - 1;
		}

		return fscrypt_set_test_dummy_encryption(sb, &arg, &fsc->dummy_enc_ctx);
	}
	return 0;
}
