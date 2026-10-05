// SPDX-License-Identifier: GPL-3.0-only
#include "audio_clock_tests.h"
#include <cstdio>

int main() {
    try {
        check_audio_clock();
        check_audio_clock_variable_refills();
        std::puts("Windows audio presentation clock: OK");
        return 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "%s\n", error.what());
        return 1;
    }
}
