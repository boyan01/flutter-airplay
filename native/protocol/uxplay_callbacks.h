// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "../include/airplay/player.h"
extern "C" {
#include "raop.h"
}
raop_callbacks_t receiver_callbacks(AirplayPlayer* playback);
