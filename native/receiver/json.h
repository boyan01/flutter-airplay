// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <plist/plist.h>
#include <cstring>
#include <cstdlib>
#include <memory>
#include <stdexcept>
#include <string>

namespace airplay {
struct PlistDeleter { void operator()(void *value) const { plist_free(value); } };
using Json = std::unique_ptr<void, PlistDeleter>;
inline Json json_object() { return Json(plist_new_dict()); }
inline Json parse_json(const char *text) {
    plist_t value = nullptr;
    if (!text || strlen(text) > 1024 * 1024 ||
        plist_from_json(text, uint32_t(strlen(text)), &value) != PLIST_ERR_SUCCESS ||
        plist_get_node_type(value) != PLIST_DICT) {
        plist_free(value); throw std::runtime_error("Invalid receiver JSON object");
    }
    return Json(value);
}
inline std::string json_text(plist_t value) {
    char *text = nullptr; uint32_t size = 0;
    if (plist_to_json(value, &text, &size, 0) != PLIST_ERR_SUCCESS)
        throw std::runtime_error("Cannot encode receiver JSON");
    std::string result(text, size); free(text); return result;
}
inline plist_t item(plist_t value, const char *key) { return plist_dict_get_item(value, key); }
inline std::string text(plist_t value, const char *key, const std::string& fallback = "") {
    auto node = item(value, key);
    if (plist_get_node_type(node) != PLIST_STRING) return fallback;
    uint64_t length = 0; const char *bytes = plist_get_string_ptr(node, &length);
    return bytes ? std::string(bytes, size_t(length)) : fallback;
}
inline bool boolean(plist_t value, const char *key, bool fallback = false) {
    auto node = item(value, key);
    if (plist_get_node_type(node) != PLIST_BOOLEAN) return fallback;
    uint8_t result = 0; plist_get_bool_val(node, &result); return result != 0;
}
inline int64_t integer(plist_t value, const char *key, int64_t fallback = 0) {
    auto node = item(value, key);
    if (plist_get_node_type(node) != PLIST_UINT) return fallback;
    uint64_t result = 0; plist_get_uint_val(node, &result); return int64_t(result);
}
inline void set(plist_t value, const char *key, const std::string& bytes) {
    plist_dict_set_item(value, key, plist_new_string(bytes.c_str()));
}
inline void set(plist_t value, const char *key, const char *bytes) { set(value, key, std::string(bytes)); }
inline void set(plist_t value, const char *key, bool flag) { plist_dict_set_item(value, key, plist_new_bool(flag)); }
inline void set(plist_t value, const char *key, int64_t number) { plist_dict_set_item(value, key, plist_new_uint(uint64_t(number))); }
inline void merge(plist_t target, plist_t source) { plist_dict_merge(&target, source); }
}  // namespace airplay
