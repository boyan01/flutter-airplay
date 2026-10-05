# SPDX-License-Identifier: GPL-3.0-only
string(TIMESTAMP BUILD_TIME "%Y-%m-%dT%H:%M:%SZ" UTC)
file(WRITE "${OUTPUT}" "#pragma once\n#define AIRPLAY_BUILD_TIME \"${BUILD_TIME}\"\n")
