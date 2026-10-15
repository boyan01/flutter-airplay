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
inline std::string json_string(const std::string& bytes) {
    constexpr char hex[] = "0123456789abcdef";
    std::string result = "\"";
    for (unsigned char byte : bytes) {
        if (byte == '\\' || byte == '"') { result += '\\'; result += char(byte); }
        else if (byte < 32) { result += "\\u00"; result += hex[byte >> 4]; result += hex[byte & 15]; }
        else result += char(byte);
    }
    return result + '"';
}
inline std::string json_text(plist_t value) {
    if (!value) throw std::runtime_error("Cannot encode receiver JSON");
    // The pinned libplist JSON writer omits backslash escaping. Keep
    // receiver paths and diagnostics intact, escaping every string and key here.
    const auto type = plist_get_node_type(value);
    if (type == PLIST_STRING) {
        uint64_t size = 0; const auto* bytes = plist_get_string_ptr(value, &size);
        return json_string(bytes ? std::string(bytes, size_t(size)) : "");
    }
    if (type == PLIST_DICT) {
        plist_dict_iter raw = nullptr; plist_dict_new_iter(value, &raw);
        std::unique_ptr<void, decltype(&free)> iterator(raw, free);
        std::string result = "{";
        for (;;) {
            char* raw_key = nullptr; plist_t child = nullptr;
            plist_dict_next_item(value, iterator.get(), &raw_key, &child);
            std::unique_ptr<char, decltype(&free)> key(raw_key, free);
            if (!child) break;
            if (result.size() > 1) result += ',';
            result += json_string(key.get()) + ':' + json_text(child);
        }
        return result + '}';
    }
    if (type == PLIST_ARRAY) {
        std::string result = "[";
        for (uint32_t i = 0; i < plist_array_get_size(value); ++i) {
            if (i) result += ',';
            result += json_text(plist_array_get_item(value, i));
        }
        return result + ']';
    }
    // Let libplist retain its numeric and scalar semantics. Its JSON API
    // requires a container, so encode one value in an array and remove it.
    Json scalar(plist_new_array()); plist_array_append_item(scalar.get(), plist_copy(value));
    char *text = nullptr; uint32_t size = 0;
    if (plist_to_json(scalar.get(), &text, &size, 0) != PLIST_ERR_SUCCESS)
        throw std::runtime_error("Cannot encode receiver JSON");
    std::string result(text + 1, size - 2); free(text); return result;
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
inline void set(plist_t value, const char *key, int64_t number) { plist_dict_set_item(value, key, plist_new_int(number)); }
inline void merge(plist_t target, plist_t source) { plist_dict_merge(&target, source); }
}  // namespace airplay
