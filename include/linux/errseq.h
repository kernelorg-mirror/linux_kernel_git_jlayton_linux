/* SPDX-License-Identifier: GPL-2.0 */
/*
 * See Documentation/core-api/errseq.rst and lib/errseq.c
 */
#ifndef _LINUX_ERRSEQ_H
#define _LINUX_ERRSEQ_H

typedef u32	errseq_t;

/**
 * errseq_fetch - Grab the current errseq_t value
 * @eseq: Pointer to errseq_t to peek
 *
 * Grab the current errseq_t value and return it. This value is OK
 * to use as a "since" value later, as long as you don't care about
 * unseen errors that happened before this point.
 */
static inline errseq_t errseq_fetch(errseq_t *eseq)
{
	return READ_ONCE(*eseq);
}

errseq_t errseq_set(errseq_t *eseq, int err);
errseq_t errseq_sample(errseq_t *eseq);
errseq_t errseq_sample_new(errseq_t *eseq);
int errseq_check(errseq_t *eseq, errseq_t since);
int errseq_check_and_advance(errseq_t *eseq, errseq_t *since);
#endif
