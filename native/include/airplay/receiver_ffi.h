// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// Dart supplies NativeApi.postCObject. Attach replaces the old isolate's port
// and returns a subscription token. All messages are copied JSON strings.
uint64_t airplay_receiver_attach(uint64_t handle, int64_t port, void *post_c_object);
bool airplay_receiver_detach(uint64_t handle, uint64_t subscription);
uint32_t airplay_receiver_abi_version(void);

// Copies/enqueues {"method": ..., "arguments": {...}} before returning.
// Replies are {"type":"complete", "request":id, "data":{...}} or include
// "error" on failure. false means the handle/subscription was closed.
// Queued commands and replies are scoped to the current subscription.
bool airplay_receiver_control(uint64_t handle, uint64_t subscription,
    int64_t request, const char *json, size_t size);

#ifdef __cplusplus
}
#endif
