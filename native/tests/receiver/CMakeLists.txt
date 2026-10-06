# SPDX-License-Identifier: GPL-3.0-only
find_package(Threads REQUIRED)
add_executable(receiver_tests control_test.cpp $<TARGET_OBJECTS:airplay_receiver_control>)
target_link_libraries(receiver_tests PRIVATE plist Threads::Threads)
add_test(NAME receiver_lifecycle COMMAND receiver_tests)
set_tests_properties(receiver_lifecycle PROPERTIES LABELS "receiver" TIMEOUT 10)
