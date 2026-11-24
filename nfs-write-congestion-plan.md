# NFS client write congestion rework

Response to Trond's questions on 2f1f31042ef0 ("nfs: Block on write
congestion"). Separate series from the close()/delegation patch, which
no longer depends on this now that it uses filemap_fdatawrite().

## Answers to Trond

**Why only WB_SYNC_NONE?** Historical accident.
- 89a09141df6a (2007) capped pages under writeback per nfs_server via
  bdi congestion. The VM *skipped* congested bdis, and skipping is only
  legal for non-integrity writeback.
- 6df25e58532b (2022) replaced bdi congestion with nfss->write_congested
  and kept the skip, so it kept the WB_SYNC_NONE condition.
- 2f1f31042ef0 (2024) turned skip into block but kept the condition.
  Blocking doesn't violate integrity, so the exemption has no basis now.

**Why no re-check in the loop?** Also inherited. With skip semantics the
entry check was the whole mechanism. Once it blocks, one nfs_writepages()
call (nr_to_write = LONG_MAX from filemap_fdatawrite/flush) can push an
unbounded number of pages past the threshold.

A naive in-loop wait isn't safe with today's accounting.
nfss->writeback is incremented at nfs_folio_set_writeback()
(write.c:286, from nfs_do_writepage()), *before* the request is sent.
Requests queued in a pgio descriptor are counted but not in flight. N
writers each holding queued requests that sum past the OFF threshold,
all waiting, never get woken. Accounting has to move first.

**pNFS.** Charging and waiting both use NFS_SERVER(inode), the MDS,
regardless of where the data goes. So:
- all DSes share one combined cap and one waitqueue
- one slow DS blocks writers to every other DS and to the MDS
- a wide DS set is limited to nfs_congestion_kb in total

Separately: two mounts of the same server get separate nfs_server
structs, so each gets its own budget.

## Design

### 1. Per-endpoint congestion state in struct nfs_client

    struct nfs_write_congestion {
            atomic_long_t      inflight;   /* bytes in WRITE RPCs */
            unsigned long      flags;      /* NFS_WCONG_CONGESTED */
            wait_queue_head_t  wait;
    };

- Embed it in struct nfs_client; remove writeback, write_congested and
  write_congestion_wait from nfs_server.
- Covers the MDS (server->nfs_client) and DSes (nfs4_pnfs_ds->ds_clp)
  the same way. DS clients already sit in the per-net DS cache shared
  across MDSes and mounts, so the budget is per server endpoint.
- Keep the ON/OFF hysteresis. nfs_congestion_kb becomes a per-endpoint
  limit (document it in the sysctl).

### 2. Charge at RPC submission, not at folio writeback

- Charge hdr->args.count to the target client in nfs_initiate_pgio()
  (pagelist.c:779). Every MDS and DS write goes through it (filelayout
  .c:532, flexfilelayout.c:2420, pagelist.c:1018).
- Target client: pass it in explicitly. flexfiles doesn't set
  hdr->ds_clp, so `hdr->ds_clp ?: NFS_SERVER(inode)->nfs_client` isn't
  enough. Callers have ds->ds_clp, or the MDS client.
- Record the charged client and byte count in the hdr. Uncharge once,
  in header free. Make charging idempotent and audit for any path that
  calls nfs_initiate_pgio() twice on one hdr.
- Resends (nfs_pageio_resend, MDS fallback) use a new hdr, so a new
  charge to the new target is correct. rpc_restart_call() reuses the
  hdr, so it isn't charged again.
- flexfiles mirroring: one hdr per mirror, so each mirror DS is charged.
- Queued, unsent requests are no longer counted. That removes the
  deadlock above. Overshoot is limited to roughly one descriptor's worth
  (wsize, or the layout boundary) per writer.
- nfs_folio_set_writeback()/nfs_folio_end_writeback() go back to plain
  folio_start/end_writeback.

Open: O_DIRECT and localio go through nfs_initiate_pgio() too, and
aren't counted today. Recommend charging them, since they load the same
endpoint, but never blocking them (no throttle-capable descriptor).

### 3. Throttle consistently in nfs_writepages(), all sync modes

- Add desc->pg_throttle (enabled only by nfs_writepages()) and
  desc->pg_congested_clp.
- nfs_pgheader_init() copies a pointer to desc->pg_congested_clp into
  the hdr. At charge time, if the target is congested, store the client
  there (with a cl_count ref). Then clear the hdr pointer. It's used only
  synchronously during submission, while desc is guaranteed alive.
- In the writeback_iter() loop, after folio_unlock(): if
  pg_congested_clp is set, wait_event_killable() on that client's
  waitqueue, drop the ref, continue. No folio lock is held. Queued
  requests aren't counted, so the wait can't depend on them.
- Remove the entry check. The first dispatch to a congested target
  reports it. That's at most one RPC of overshoot per writer, and it
  works for pNFS, where the target is unknown until the layout driver
  chooses a DS.
- Applies to WB_SYNC_ALL and WB_SYNC_NONE alike.
- No wait after the final nfs_pageio_complete(). Throttle a producer
  *before it sends more*, not after its last send. A small file's
  close()/fsync() (one RPC, sent at complete time) never waits. That
  avoids the close() latency regression from review.
- Never wait in resend/rpciod/nfsiod contexts. Their descriptors don't
  set pg_throttle.

### 4. pNFS falls out of 2+3

- Each DS is charged and throttled on its own. A slow DS blocks only the
  writers whose next RPC goes to it.
- COMMIT to DS/MDS stays unaccounted (same as today: pages awaiting
  COMMIT are not under writeback).

## Patch split

1. Tracepoints: nfs_write_congestion_{on,off,wait} (client, inflight).
   Lets us compare before and after.
2. Move congestion state from nfs_server to nfs_client (accounting
   unchanged). Fixes the per-mount double budget.
3. Charge at submission per target client (MDS or DS); uncharge at hdr
   free. Remove folio-level accounting.
4. Descriptor feedback plus in-loop wait for all sync modes; remove the
   entry check and the WB_SYNC_NONE condition.
5. Documentation: nfs_congestion_kb is per endpoint.

## Lock-dependency audit (before step 4)

A WB_SYNC_ALL caller now waits on *other* writes completing. Check
that no WB_SYNC_ALL writeback caller holds a lock those completions
(nfs_writeback_done, nfs4_write_done_cb, state recovery triggered by
write errors, delegation return in the state manager) need. Candidates:
- nfs4_inode_return_delegation() -> nfs_wb_all() (delegation.c:832),
  i_rwsem held by setattr/rename callers
- nfs_file_flush()/nfs4_file_flush(), nfs_lock() -> nfs_wb_all()
  (file.c:816,869)
- nfs_sync_inode() from copy/clone (nfs4file.c:286)
Today these already wait for their *own* writes, which depend on the
same recovery machinery. The new dependency is on other writes to the
same endpoint, so check specifically for per-endpoint locks.

## Testing

- Jan's fio randwrite repro from 2f1f31042ef0 (expect >= 184 MB/s).
- fsync-heavy and large-file fsync: confirm WB_SYNC_ALL throttling
  doesn't regress throughput, and the overshoot bound holds (trace
  inflight).
- Small-file create/write/close with a write delegation (92 -> 1500
  files/s test): must not regress.
- pNFS flexfiles with >= 2 DSes, one slowed (tc netem): writers to the
  fast DS keep full throughput. Also mirrored layouts.
- Two mounts of one server: single budget.
- Hung server: wait stays killable; no lockdep splats.

## Alternative to raise with Trond

Drop the private throttle entirely and rely on RPC slot/session-slot
backpressure plus VM dirty throttling (balance_dirty_pages counts
NR_WRITEBACK). Jan's numbers:
- no effective limit (pre-2022): ~170 MB/s
- limit + skip: ~126 MB/s
- limit + block: ~184 MB/s

So the limit is worth only about 8% on that workload. Benchmark
"no limit" on the current tree before taking on steps 2-4. If it's
within noise, removal is the simplest consistent answer, and it fixes
pNFS trivially.
