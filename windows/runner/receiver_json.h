// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <flutter/encodable_value.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <cmath>
#include <limits>
#include <stdexcept>

// Windows' Flutter C++ wrapper only supplies the standard binary codec.
// Use the system JSON implementation for the native receiver's JSON contract.
namespace receiver_json {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
using namespace winrt::Windows::Data::Json;

inline IJsonValue to_json(const Value& value) {
    if (value.IsNull()) return JsonValue::Parse(L"null");
    if (const auto* flag = std::get_if<bool>(&value)) return JsonValue::CreateBooleanValue(*flag);
    if (const auto* number = std::get_if<int32_t>(&value)) return JsonValue::CreateNumberValue(*number);
    if (const auto* number = std::get_if<int64_t>(&value)) return JsonValue::CreateNumberValue(static_cast<double>(*number));
    if (const auto* number = std::get_if<double>(&value)) return JsonValue::CreateNumberValue(*number);
    if (const auto* text = std::get_if<std::string>(&value)) return JsonValue::CreateStringValue(winrt::to_hstring(*text));
    if (const auto* map = std::get_if<Map>(&value)) {
        JsonObject object;
        for (const auto& entry : *map) {
            object.Insert(winrt::to_hstring(std::get<std::string>(entry.first)), to_json(entry.second));
        }
        return object;
    }
    if (const auto* list = std::get_if<List>(&value)) {
        JsonArray array;
        for (const auto& entry : *list) array.Append(to_json(entry));
        return array;
    }
    throw std::runtime_error("Unsupported receiver JSON value");
}

inline Value from_json(const IJsonValue& value) {
    switch (value.ValueType()) {
    case JsonValueType::Null: return Value();
    case JsonValueType::Boolean: return Value(value.GetBoolean());
    case JsonValueType::String: return Value(winrt::to_string(value.GetString()));
    case JsonValueType::Number: {
        const double number = value.GetNumber();
        // Match Flutter's integer representation so snapshot consumers can
        // read dimensions and identifiers without treating them as doubles.
        if (std::isfinite(number) && std::trunc(number) == number &&
            number >= static_cast<double>(std::numeric_limits<int64_t>::min()) &&
            number < -static_cast<double>(std::numeric_limits<int64_t>::min())) {
            return Value(static_cast<int64_t>(number));
        }
        return Value(number);
    }
    case JsonValueType::Object: {
        Map map;
        for (const auto& entry : value.GetObject()) {
            map.emplace(Value(winrt::to_string(entry.Key())), from_json(entry.Value()));
        }
        return Value(std::move(map));
    }
    case JsonValueType::Array: {
        List list;
        for (const auto& entry : value.GetArray()) list.push_back(from_json(entry));
        return Value(std::move(list));
    }
    }
    throw std::runtime_error("Unsupported receiver JSON type");
}

inline std::string encode(const Map& value) {
    return winrt::to_string(to_json(Value(value)).Stringify());
}

inline Map decode(const char* text) {
    if (!text) return {};
    JsonObject object{nullptr};
    if (!JsonObject::TryParse(winrt::to_hstring(text), object)) return {};
    return std::get<Map>(from_json(object));
}
} // namespace receiver_json
