// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <windows.h>
#include <stdint.h>
static inline int usleep(uint64_t microseconds) { Sleep((DWORD)((microseconds + 999) / 1000)); return 0; }
