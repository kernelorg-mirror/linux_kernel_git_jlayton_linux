// SPDX-License-Identifier: ((GPL-2.0 WITH Linux-syscall-note) OR BSD-3-Clause)
/* Do not edit directly, auto-generated from: */
/*	Documentation/netlink/specs/nfsd_server.yaml */
/* YNL-GEN kernel source */

#include <net/netlink.h>
#include <net/genetlink.h>

#include "nfs_netlink_gen.h"

#include <uapi/linux/nfsd_server.h>

/* Ops table for nfsd_server */
static const struct genl_split_ops nfsd_server_nl_ops[] = {
	{
		.cmd	= NFSD_CMD_RPC_STATUS_GET,
		.start	= nfsd_server_nl_rpc_status_get_start,
		.dumpit	= nfsd_server_nl_rpc_status_get_dumpit,
		.done	= nfsd_server_nl_rpc_status_get_done,
		.flags	= GENL_CMD_CAP_DUMP,
	},
};

struct genl_family nfsd_server_nl_family __ro_after_init = {
	.name		= NFSD_SERVER_FAMILY_NAME,
	.version	= NFSD_SERVER_FAMILY_VERSION,
	.netnsok	= true,
	.parallel_ops	= true,
	.module		= THIS_MODULE,
	.split_ops	= nfsd_server_nl_ops,
	.n_split_ops	= ARRAY_SIZE(nfsd_server_nl_ops),
};
