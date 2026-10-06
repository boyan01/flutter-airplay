// SPDX-License-Identifier: GPL-3.0-or-later
#include "dns_sd.h"
#include <stdlib.h>
#include <string.h>
struct AndroidService { int prepared; };
int32_t DNSServiceRegister(DNSServiceRef *ref, DNSServiceFlags flags, uint32_t idx,
    const char *name, const char *type, const char *domain, const char *host,
    uint16_t port, uint16_t len, const void *txt, DNSServiceRegisterReply cb, void *ctx) {
    (void)flags; (void)idx; (void)name; (void)type; (void)domain; (void)host;
    (void)port; (void)len; (void)txt; (void)cb; (void)ctx;
    // This only prepares a record; it does not signal Bonjour readiness.
    *ref = calloc(1, sizeof(struct AndroidService));
    return *ref ? 0 : -1;
}
void DNSServiceRefDeallocate(DNSServiceRef ref) { free(ref); }
void TXTRecordCreate(TXTRecordRef *r, uint16_t len, void *buf) {
    (void)len; (void)buf; r->bytes = NULL; r->length = 0;
}
int32_t TXTRecordSetValue(TXTRecordRef *r, const char *key, uint8_t len, const void *val) {
    size_t k = strlen(key), entry = k + 1 + len;
    if (!k || strchr(key, '=') || entry > 255 || (len && !val)) return -1;
    size_t offset = 0, old = 0;
    while (offset < r->length) {
        size_t n = r->bytes[offset];
        if (n >= k + 1 && !memcmp(r->bytes + offset + 1, key, k)
            && r->bytes[offset + 1 + k] == '=') { old = n + 1; break; }
        offset += n + 1;
    }
    size_t total = r->length - old + entry + 1;
    if (total > UINT16_MAX) return -1;
    uint8_t *next = malloc(total);
    if (!next) return -1;
    if (offset) memcpy(next, r->bytes, offset);
    next[offset] = (uint8_t)entry;
    memcpy(next + offset + 1, key, k);
    next[offset + 1 + k] = '=';
    if (len) memcpy(next + offset + k + 2, val, len);
    size_t tail = r->length - offset - old;
    if (tail) memcpy(next + offset + entry + 1, r->bytes + offset + old, tail);
    free(r->bytes); r->bytes = next; r->length = (uint16_t)total;
    return 0;
}
uint16_t TXTRecordGetLength(const TXTRecordRef *r) { return r->length; }
const void *TXTRecordGetBytesPtr(const TXTRecordRef *r) { return r->bytes; }
void TXTRecordDeallocate(TXTRecordRef *r) { free(r->bytes); r->bytes = NULL; r->length = 0; }
