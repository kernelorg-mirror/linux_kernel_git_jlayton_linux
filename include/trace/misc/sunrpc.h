/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Copyright (c) 2021 Oracle and/or its affiliates.
 *
 * Common types and format specifiers for sunrpc.
 */

#if !defined(_TRACE_SUNRPC_BASE_H)
#define _TRACE_SUNRPC_BASE_H

#include <linux/tracepoint.h>

#define SUNRPC_TRACE_PID_SPECIFIER	"%08x"
#define SUNRPC_TRACE_CLID_SPECIFIER	"%08x"
#define SUNRPC_TRACE_TASK_SPECIFIER \
	"task:" SUNRPC_TRACE_PID_SPECIFIER "@" SUNRPC_TRACE_CLID_SPECIFIER

#define SVC_RQST_ENDPOINT_FIELDS(r) \
		__sockaddr(server, (r)->rq_xprt->xpt_locallen) \
		__sockaddr(client, (r)->rq_xprt->xpt_remotelen) \
		__field(unsigned int, netns_ino) \
		__field(u32, xid)

#define SVC_RQST_ENDPOINT_ASSIGNMENTS(r) \
		do { \
			struct svc_xprt *xprt = (r)->rq_xprt; \
			__assign_sockaddr(server, &xprt->xpt_local, \
					  xprt->xpt_locallen); \
			__assign_sockaddr(client, &xprt->xpt_remote, \
					  xprt->xpt_remotelen); \
			__entry->netns_ino = xprt->xpt_net->ns.inum; \
			__entry->xid = be32_to_cpu((r)->rq_xid); \
		} while (0)

#define SVC_RQST_ENDPOINT_FORMAT \
		"xid=0x%08x server=%pISpc client=%pISpc"

#define SVC_RQST_ENDPOINT_VARARGS \
		__entry->xid, __get_sockaddr(server), __get_sockaddr(client)

#endif /* _TRACE_SUNRPC_BASE_H */
