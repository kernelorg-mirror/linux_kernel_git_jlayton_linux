// SPDX-License-Identifier: GPL-2.0
/*
 * base64 encode/decode functions
 *
 * Originally lifted from fs/crypto/fname.c
 *
 * Copyright (C) 2015, Jaegeuk Kim
 * Copyright (C) 2015, Eric Biggers
 */

#include <linux/types.h>
#include <linux/export.h>
#include <linux/string.h>

static const char lookup_table[65] =
	"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+,";

/**
 * base64_encode() - base64-encode some bytes
 * @src: the bytes to encode
 * @len: number of bytes to encode
 * @dst: (output) the base64-encoded string.  Not NUL-terminated.
 *
 * Encodes the input string using characters from the set [A-Za-z0-9+,].
 * The encoded string is roughly 4/3 times the size of the input string.
 *
 * Return: length of the encoded string
 */
int base64_encode(const u8 *src, int len, char *dst)
{
	int i, bits = 0, ac = 0;
	char *cp = dst;

	for (i = 0; i < len; i++) {
		ac += src[i] << bits;
		bits += 8;
		do {
			*cp++ = lookup_table[ac & 0x3f];
			ac >>= 6;
			bits -= 6;
		} while (bits >= 6);
	}
	if (bits)
		*cp++ = lookup_table[ac & 0x3f];
	return cp - dst;
}
EXPORT_SYMBOL(base64_encode);

int base64_decode(const char *src, int len, u8 *dst)
{
	int i, bits = 0, ac = 0;
	const char *p;
	u8 *cp = dst;

	for (i = 0; i < len; i++) {
		p = strchr(lookup_table, src[i]);
		if (p == NULL || src[i] == 0)
			return -2;
		ac += (p - lookup_table) << bits;
		bits += 6;
		if (bits >= 8) {
			*cp++ = ac & 0xff;
			ac >>= 8;
			bits -= 8;
		}
	}
	if (ac)
		return -1;
	return cp - dst;
}
EXPORT_SYMBOL(base64_decode);
