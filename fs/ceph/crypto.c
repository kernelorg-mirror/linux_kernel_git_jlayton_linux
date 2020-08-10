// SPDX-License-Identifier: GPL-2.0
#include <linux/ceph/ceph_debug.h>
#include <linux/xattr.h>
#include <linux/fscrypt.h>
#include <linux/base64.h>

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

int ceph_fscrypt_new_context(struct inode *parent, struct ceph_acl_sec_ctx *as)
{
	int ret, ctxsize;
	size_t name_len;
	char *name;
	struct ceph_pagelist *pagelist = as->pagelist;

	/* Do nothing if subtree isn't encrypted */
	if (!IS_ENCRYPTED(parent))
		return 0;

	ctxsize = fscrypt_new_context_from_parent(parent, as->fscrypt);
	if (ctxsize <= 0)
		return ctxsize;

	/* marshal it in page array */
	if (!pagelist) {
		pagelist = ceph_pagelist_alloc(GFP_KERNEL);
		if (!pagelist)
			return -ENOMEM;
		ret = ceph_pagelist_reserve(pagelist, PAGE_SIZE);
		if (ret)
			goto out;
		ceph_pagelist_encode_32(pagelist, 1);
	}

	name = CEPH_XATTR_NAME_ENCRYPTION_CONTEXT;
	name_len = strlen(name);
	ret = ceph_pagelist_reserve(pagelist, 4 * 2 + name_len + ctxsize);
	if (ret)
		goto out;

	if (as->pagelist) {
		BUG_ON(pagelist->length <= sizeof(__le32));
		if (list_is_singular(&pagelist->head)) {
			le32_add_cpu((__le32*)pagelist->mapped_tail, 1);
		} else {
			struct page *page = list_first_entry(&pagelist->head,
							     struct page, lru);
			void *addr = kmap_atomic(page);
			le32_add_cpu((__le32*)addr, 1);
			kunmap_atomic(addr);
		}
	}

	ceph_pagelist_encode_32(pagelist, name_len);
	ceph_pagelist_append(pagelist, name, name_len);
	ceph_pagelist_encode_32(pagelist, ctxsize);
	ceph_pagelist_append(pagelist, as->fscrypt, ctxsize);
out:
	if (pagelist && !as->pagelist)
		ceph_pagelist_release(pagelist);
	return ret;
}

int ceph_fname_to_usr(struct inode *parent, char *name, u32 len,
			struct fscrypt_str *tname, struct fscrypt_str *oname)
{
	int ret, declen;
	u32 save_len;
	struct fscrypt_str myname = FSTR_INIT(NULL, 0);

	if (!IS_ENCRYPTED(parent)) {
		oname->name = name;
		oname->len = len;
		return 0;
	}

	ret = fscrypt_get_encryption_info(parent);
	if (ret)
		return ret;

	if (tname) {
		save_len = tname->len;
	} else {
		int err;

		save_len = 0;
		err = fscrypt_fname_alloc_buffer(NAME_MAX, &myname);
		if (err)
			return err;
		tname = &myname;
	}

	declen = base64_decode(name, len, tname->name);
	if (declen < 0 || declen > NAME_MAX) {
		ret = -EIO;
		goto out;
	}

	tname->len = declen;

	ret = fscrypt_fname_disk_to_usr(parent, 0, 0, tname, oname);

	if (save_len)
		tname->len = save_len;
out:
	fscrypt_fname_free_buffer(&myname);
	return ret;
}
