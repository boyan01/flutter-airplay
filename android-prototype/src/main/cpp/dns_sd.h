// SPDX-License-Identifier: GPL-3.0-or-later
// Local TXT storage adapter. NsdManager owns the actual network registration.
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef uint32_t DNSServiceFlags;
typedef int32_t DNSServiceErrorType;
typedef struct AndroidService *DNSServiceRef;
typedef struct { uint8_t *bytes; uint16_t length; } TXTRecordRef;
typedef void (*DNSServiceRegisterReply)(DNSServiceRef, DNSServiceFlags,
    DNSServiceErrorType, const char *, const char *, const char *, void *);
DNSServiceErrorType DNSServiceRegister(DNSServiceRef *, DNSServiceFlags, uint32_t,
    const char *, const char *, const char *, const char *, uint16_t, uint16_t,
    const void *, DNSServiceRegisterReply, void *);
void DNSServiceRefDeallocate(DNSServiceRef);
void TXTRecordCreate(TXTRecordRef *, uint16_t, void *);
int32_t TXTRecordSetValue(TXTRecordRef *, const char *, uint8_t, const void *);
uint16_t TXTRecordGetLength(const TXTRecordRef *);
const void *TXTRecordGetBytesPtr(const TXTRecordRef *);
void TXTRecordDeallocate(TXTRecordRef *);
#ifdef __cplusplus
}
#endif
