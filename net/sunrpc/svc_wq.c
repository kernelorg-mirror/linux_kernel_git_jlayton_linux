/*
 * svc_wq - support for workqueue-based rpc svcs
 */

#include <linux/sched.h>
#include <linux/errno.h>
#include <linux/slab.h>
#include <linux/sunrpc/stats.h>
#include <linux/sunrpc/svc_xprt.h>
#include <linux/module.h>
#include <linux/workqueue.h>
#include <trace/events/sunrpc.h>

static struct svc_rqst *
find_svc_rqst(struct svc_serv *serv)
{
	int node = numa_node_id();
	struct svc_rqst *rqstp;
	struct svc_pool *pool = &serv->sv_pools[node];

	rcu_read_lock();
	list_for_each_entry_rcu(rqstp, &pool->sp_all_threads, rq_all) {
		if (!test_and_set_bit(RQ_BUSY, &rqstp->rq_flags)) {
			rcu_read_unlock();
			return rqstp;
		}
	}
	rcu_read_unlock();
	return NULL;
}

/*
 * Find a svc_rqst to use. Try to find an already allocated-one on the list
 * first, and then allocate if there isn't one available.
 */
struct svc_rqst *
find_or_alloc_svc_rqst(struct svc_serv *serv)
{
	int node = numa_node_id();
	struct svc_rqst *rqstp;
	struct svc_pool *pool = &serv->sv_pools[node];

	rqstp = find_svc_rqst(serv);
	if (likely(rqstp))
		return rqstp;

	rqstp = svc_rqst_alloc(serv, pool, node);
	if (rqstp) {
		spin_lock_bh(&pool->sp_lock);
		list_add_tail_rcu(&rqstp->rq_all, &pool->sp_all_threads);
		++pool->sp_nrthreads;
		spin_unlock_bh(&pool->sp_lock);
	}
	return rqstp;
}
EXPORT_SYMBOL_GPL(find_or_alloc_svc_rqst);

static unsigned long
count_svc_rqst_objects(struct shrinker *shrinker, struct shrink_control *sc)
{
	struct svc_serv *serv = container_of(shrinker, struct svc_serv,
						sv_shrinker);
	struct svc_pool *pool = &serv->sv_pools[sc->nid];
	struct svc_rqst *rqstp;
	unsigned long count = 0;

	rcu_read_lock();
	list_for_each_entry_rcu(rqstp, &pool->sp_all_threads, rq_all) {
		/* Don't count it if it's busy */
		if (test_bit(RQ_BUSY, &rqstp->rq_flags))
			continue;

		/* Don't count it if it was used within the last second */
		if (time_before(jiffies, rqstp->rq_time + HZ))
			continue;

		++count;
	}
	rcu_read_unlock();

	return count;
}

static unsigned long
scan_svc_rqst_objects(struct shrinker *shrinker, struct shrink_control *sc)
{
	struct svc_serv *serv = container_of(shrinker, struct svc_serv,
						sv_shrinker);
	struct svc_pool *pool = &serv->sv_pools[sc->nid];
	struct svc_rqst *rqstp;
	unsigned long count = 0;

	spin_lock_bh(&pool->sp_lock);
	list_for_each_entry_rcu(rqstp, &pool->sp_all_threads, rq_all) {
		/* Don't free it if it's busy */
		if (test_and_set_bit(RQ_BUSY, &rqstp->rq_flags))
			continue;

		list_del_rcu(&rqstp->rq_all);
		svc_rqst_free(rqstp);
		--pool->sp_nrthreads;
		++count;
		if (sc->nr_to_scan-- == 0)
			break;
	}
	spin_unlock_bh(&pool->sp_lock);

	return count;
}

static int
init_svc_rqst_cache(struct svc_serv *serv)
{
	struct shrinker *shrinker = &serv->sv_shrinker;

	memset(shrinker, 0, sizeof(*shrinker));

	shrinker->count_objects = count_svc_rqst_objects;
	shrinker->scan_objects = scan_svc_rqst_objects;
	shrinker->seeks = DEFAULT_SEEKS;
	shrinker->flags = SHRINKER_NUMA_AWARE;

	return register_shrinker(shrinker);
}

void
exit_svc_rqst_cache(struct svc_serv *serv)
{
	int node;

	unregister_shrinker(&serv->sv_shrinker);

	for (node = 0; node < serv->sv_nrpools; node++) {
		struct svc_pool *pool = &serv->sv_pools[node];

		spin_lock_bh(&pool->sp_lock);
		while (!list_empty(&pool->sp_all_threads)) {
			struct svc_rqst *rqstp = list_first_entry(
					&pool->sp_all_threads, struct svc_rqst,
					rq_all);

			WARN_ON_ONCE(test_bit(RQ_BUSY, &rqstp->rq_flags));
			list_del_rcu(&rqstp->rq_all);
			svc_rqst_free(rqstp);
		}
		pool->sp_nrthreads = 0;
		spin_unlock_bh(&pool->sp_lock);
	}
}

/*
 * This workqueue job should run on each node when the workqueue is created. It
 * walks the list of xprts for its node, and queues the workqueue job for each.
 */
static void
process_queued_xprt_work(struct work_struct *work)
{
	struct svc_pool *pool = container_of(work, struct svc_pool, sp_work);

	spin_lock_bh(&pool->sp_lock);
	while (!list_empty(&pool->sp_sockets)) {
		struct svc_xprt *xprt = list_first_entry(&pool->sp_sockets,
						 struct svc_xprt, xpt_ready);

		list_del_init(&xprt->xpt_ready);
		svc_xprt_get(xprt);
		queue_work(xprt->xpt_server->sv_wq, &xprt->xpt_work);
	}
	spin_unlock_bh(&pool->sp_lock);
}

/*
 * If any svc_xprts are enqueued before the workqueue is available, they get
 * added to the pool->sp_sockets list. When the workqueue becomes available,
 * we must walk the list  for each pool and queue each xprt to the workqueue.
 *
 * In order to minimize inter-node communication, we queue a separate job for
 * each node to walk its own list. We queue this job to any cpu in the node.
 * Since the workqueues are unbound they'll end up queued to the pool_workqueue
 * for their corresponding node, and not necessarily to the given CPU.
 */
static void
process_queued_xprts(struct svc_serv *serv)
{
	int node;

	for (node = 0; node < serv->sv_nrpools; ++node) {
		int cpu = any_online_cpu(*cpumask_of_node(node));
		struct svc_pool *pool = &serv->sv_pools[node];

		INIT_WORK(&pool->sp_work, process_queued_xprt_work);
		queue_work_on(cpu, serv->sv_wq, &pool->sp_work);
	}
}

/*
 * Start up or shut down a workqueue-based RPC service. Basically, we use this
 * to allocate the workqueue and set up the shrinker for the svc_rqst cache.
 * This function assumes that the caller holds one serv->sv_nrthreads reference.
 *
 * The "active" parm is treated as a boolean here. The only meaningful values
 * are non-zero which means that we're starting the service up, or zero which
 * means that we're taking it down.
 */
int
svc_wq_setup(struct svc_serv *serv, struct svc_pool *pool, int active)
{
	int err;
	int nrthreads = serv->sv_nrthreads - 1; /* -1 for caller's reference */

	WARN_ON_ONCE(nrthreads < 0);

	/*
	 * We don't allow startup or shutdown on a per-node basis. If we got
	 * here via the pool_threads interface, then just return an error.
	 */
	if (pool)
		return -EINVAL;

	/*
	 * A zero "active" value is essentially ignored. If the service isn't
	 * up then we don't need to do anything. If it is, then we can't take
	 * down the workqueue until the closing of the xprts is done.
	 */
	if (!nrthreads && active) {
		err = init_svc_rqst_cache(serv);
		if (err)
			return err;

		__module_get(serv->sv_ops->svo_module);
		serv->sv_wq = alloc_workqueue("%s",
					WQ_UNBOUND|WQ_FREEZABLE|WQ_SYSFS,
					0, serv->sv_name);
		if (!serv->sv_wq) {
			exit_svc_rqst_cache(serv);
			module_put(serv->sv_ops->svo_module);
			return -ENOMEM;
		}

		process_queued_xprts(serv);
	}

	/* +1 for caller's reference */
	serv->sv_nrthreads = active + 1;
	return 0;
}
EXPORT_SYMBOL_GPL(svc_wq_setup);

/*
 * A svc_xprt needs to be serviced. Queue its workqueue job and return. In the
 * event that the workqueue isn't available yet, add it to the sp_sockets list
 * so that it can be processed when it does become available.
 */
void
svc_wq_enqueue_xprt(struct svc_xprt *xprt)
{
	struct svc_serv *serv = xprt->xpt_server;
	struct svc_rqst *rqstp;

	if (!svc_xprt_has_something_to_do(xprt))
		return;

	/* Don't enqueue transport while already enqueued */
	if (test_and_set_bit(XPT_BUSY, &xprt->xpt_flags))
		return;

	/* No workqueue yet? Queue the socket until there is one. */
	if (!serv->sv_wq) {
		struct svc_pool *pool = &serv->sv_pools[numa_node_id()];

		spin_lock_bh(&pool->sp_lock);

		/*
		 * It's possible for the workqueue to be started up between
		 * when we checked for it before but before we took the lock.
		 * Check again while holding lock to avoid that potential race.
		 */
		if (serv->sv_wq) {
			spin_unlock_bh(&pool->sp_lock);
			goto out;
		}

		list_add_tail(&xprt->xpt_ready, &pool->sp_sockets);
		spin_unlock_bh(&pool->sp_lock);
		return;
	}

out:
	svc_xprt_get(xprt);
	rqstp = find_svc_rqst(serv);
	if (!rqstp) {
		queue_work(serv->sv_wq, &xprt->xpt_work);
		return;
	}
	rqstp->rq_xprt = xprt;
	queue_work(serv->sv_wq, &rqstp->rq_work);
}
EXPORT_SYMBOL_GPL(svc_wq_enqueue_xprt);
