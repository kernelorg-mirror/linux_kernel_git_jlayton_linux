// SPDX-License-Identifier: GPL-2.0
#include <linux/err.h>
#include <linux/bug.h>
#include <linux/atomic.h>
#include <linux/errseq.h>

/*
 * An errseq_t is a way of recording errors in one place, and allowing any
 * number of "subscribers" to tell whether it has changed since a previous
 * point where it was sampled.
 *
 * It's implemented as an unsigned 32-bit value. The low order bits are
 * designated to hold an error code (between 0 and -MAX_ERRNO). The upper bits
 * are used as a counter. This is done with atomics instead of locking so that
 * these functions can be called from any context.
 *
 * The general idea is for consumers to sample an errseq_t value. That value
 * can later be used to tell whether any new errors have occurred since that
 * sampling was done.
 *
 * Note that there is a risk of collisions if new errors are being recorded
 * frequently, since we have so few bits to use as a counter.
 *
 * To mitigate this, one bit is used as a flag to tell whether the value has been
 * observed in some fashion. That allows us to avoid bumping the counter if no
 * one has sampled it since the last time an error was recorded.
 *
 * A second flag bit is used to indicate whether the latest error that has been
 * recorded has been reported to userland. If the REPORTED bit is not set when the
 * file is opened, then we ensure that the opener will see the error by setting
 * its sample to 0.
 *
 * A new errseq_t should always be zeroed out.  A errseq_t value of all zeroes
 * is the special (but common) case where there has never been an error. An all
 * zero value thus serves as the "epoch" if one wishes to know whether there
 * has ever been an error set since it was first initialized.
 */

/* The low bits are designated for error code (max of MAX_ERRNO) */
#define ERRSEQ_SHIFT		ilog2(MAX_ERRNO + 1)

/* Flag to indicate whether the value will be or has been reported */
#define ERRSEQ_REPORTED		BIT(ERRSEQ_SHIFT)

/* Flag to ndicate that error must be recorded */
#define ERRSEQ_OBSERVED		BIT(ERRSEQ_SHIFT + 1)

/* The lowest bit of the counter */
#define ERRSEQ_CTR_INC		BIT(ERRSEQ_SHIFT + 2)

/* Mask that just contains the counter bits */
#define ERRSEQ_CTR_MASK		~(ERRSEQ_CTR_INC - 1)

/* Mask that just contains flags */
#define ERRSEQ_FLAG_MASK	(ERRSEQ_REPORTED|ERRSEQ_OBSERVED)

/**
 * errseq_same - return true if the errseq counters and values are the same
 * @a: first errseq
 * @b: second errseq
 *
 * Compare two errseqs and return true if they are the same, ignoring their
 * flag bits.
 */
static inline bool errseq_same(errseq_t a, errseq_t b)
{
	return (a & ~ERRSEQ_FLAG_MASK) == (b & ~ERRSEQ_FLAG_MASK);
}

/**
 * errseq_set - set a errseq_t for later reporting
 * @eseq: errseq_t field that should be set
 * @err: error to set (must be between -1 and -MAX_ERRNO)
 *
 * This function sets the error in @eseq, and increments the sequence counter
 * if the last sequence was sampled at some point in the past.
 *
 * Any error set will always overwrite an existing error.
 *
 * Return: The previous value, primarily for debugging purposes. The
 * return value should not be used as a previously sampled value in later
 * calls as it will not have the OBSERVED flag set.
 */
errseq_t errseq_set(errseq_t *eseq, int err)
{
	errseq_t cur, old;

	/* MAX_ERRNO must be able to serve as a mask */
	BUILD_BUG_ON_NOT_POWER_OF_2(MAX_ERRNO + 1);

	/*
	 * Ensure the error code actually fits where we want it to go. If it
	 * doesn't then just throw a warning and don't record anything. We
	 * also don't accept zero here as that would effectively clear a
	 * previous error.
	 */
	old = READ_ONCE(*eseq);

	if (WARN(unlikely(err == 0 || (unsigned int)-err > MAX_ERRNO),
				"err = %d\n", err))
		return old;

	for (;;) {
		errseq_t new;

		/* Clear out flag bits and old errors, and set new error */
		new = (old & ERRSEQ_CTR_MASK) | -err;

		/* Only increment if we have to */
		if (old & ERRSEQ_OBSERVED)
			new += ERRSEQ_CTR_INC;

		/* If there would be no change, then call it done */
		if (new == old) {
			cur = new;
			break;
		}

		/* Try to swap the new value into place */
		cur = cmpxchg(eseq, old, new);

		/*
		 * Call it success if we did the swap or someone else beat us
		 * to it for the same value.
		 */
		if (likely(cur == old || cur == new))
			break;

		/* Raced with an update, try again */
		old = cur;
	}
	return cur;
}
EXPORT_SYMBOL(errseq_set);

/**
 * errseq_peek - Grab current errseq_t value
 * @eseq: Pointer to errseq_t to be sampled.
 *
 * In some cases, we need to be able to sample the errseq_t, but we're not
 * in a situation where we can report the value to userland. Use this
 * function to do that. This ensures that later errors will be recorded,
 * and that any current errors are reported at least once when it is
 * next sampled.
 *
 * Context: Any context.
 * Return: The current errseq value.
 */
errseq_t errseq_peek(errseq_t *eseq)
{
	errseq_t old = READ_ONCE(*eseq);
	errseq_t new = old;

	if (old != 0) {
		new |= ERRSEQ_OBSERVED;
		if (old != new)
			cmpxchg(eseq, old, new);
	}
	return new;
}
EXPORT_SYMBOL(errseq_peek);

/**
 * errseq_sample() - Sample errseq_t value, and ensure that unseen errors are reported
 * @eseq: Pointer to errseq_t to be sampled.
 *
 * This function allows callers to initialise their errseq_t variable.
 * If the latest error has been "seen", new callers will not see an old error.
 * If there is an unseen error in @eseq, the caller of this function will
 * see it the next time it checks for an error.
 *
 * Context: Any context.
 * Return: The current errseq value.
 */
errseq_t errseq_sample(errseq_t *eseq)
{
	errseq_t new = errseq_peek(eseq);

	if (!(new & ERRSEQ_REPORTED))
		return 0;
	return new;
}
EXPORT_SYMBOL(errseq_sample);

/**
 * errseq_check() - Has an error occurred since a particular sample point?
 * @eseq: Pointer to errseq_t value to be checked.
 * @since: Previously-sampled errseq_t from which to check.
 *
 * Grab the value that eseq points to, and see if it has changed @since
 * the given value was sampled. The @since value is not advanced, so there
 * is no need to mark the value as seen.
 *
 * Return: The latest error set in the errseq_t or 0 if it hasn't changed.
 */
int errseq_check(errseq_t *eseq, errseq_t since)
{
	errseq_t cur = READ_ONCE(*eseq);

	if (errseq_same(cur, since))
		return 0;
	return -(cur & MAX_ERRNO);
}
EXPORT_SYMBOL(errseq_check);

/**
 * errseq_check_and_advance() - Check an errseq_t and advance to current value.
 * @eseq: Pointer to value being checked and reported.
 * @since: Pointer to previously-sampled errseq_t to check against and advance.
 *
 * Grab the eseq value, and see whether it matches the value that @since
 * points to. If it does, then just return 0.
 *
 * If it doesn't, then the value has changed. Set the REPORTED+OBSERVED flags, and
 * try to swap it into place as the new eseq value. Then, set that value as
 * the new "since" value, and return whatever the error portion is set to.
 *
 * Note that no locking is provided here for concurrent updates to the "since"
 * value. The caller must provide that if necessary. Because of this, callers
 * may want to do a lockless errseq_check before taking the lock and calling
 * this.
 *
 * Return: Negative errno if one has been stored, or 0 if no new error has
 * occurred.
 */
int errseq_check_and_advance(errseq_t *eseq, errseq_t *since)
{
	int err = 0;
	errseq_t old, new;

	/*
	 * Most callers will want to use the inline wrapper to check this,
	 * so that the common case of no error is handled without needing
	 * to take the lock that protects the "since" value.
	 */
	old = READ_ONCE(*eseq);
	if (old != *since) {
		int loops = 0;

		/*
		 * Set the flag and try to swap it into place if it has changed.
		 *
		 * If the swap doesn't occur, then it has either been updated by a
		 * writer who is setting a new error and/or bumping the counter, or
		 * another reader who is setting flags.
		 *
		 * We only need to retry in one case -- if we raced with another
		 * reader that is only setting the OBSERVED flag. We need the
		 * current value to have the REPORTED bit set if the other fields
		 * didn't change, or we might report the same error on newly opened
		 * files.
		 */
		do {
			if (unlikely(loops >= 2)) {
				/*
				 * This should never loop more than once, as any
				 * change not involving the REPORTED bit would also
				 * involve non-flag bits. WARN and just go with
				 * what we have in that case.
				 */
				WARN_ON_ONCE(true);
				break;
			}
			loops++;
			new = old | ERRSEQ_REPORTED | ERRSEQ_OBSERVED;
			if (new == old)
				break;
			old = cmpxchg(eseq, old, new);
		} while (old == (new & ~ERRSEQ_REPORTED));
		*since = new;
		err = -(new & MAX_ERRNO);
	}
	return err;
}
EXPORT_SYMBOL(errseq_check_and_advance);
