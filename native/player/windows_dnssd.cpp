// SPDX-License-Identifier: GPL-3.0-only
// Windows system DNS-SD implementation of the existing UxPlay discovery API.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <windows.h>
#include <windns.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>
extern "C" {
#include "dnssd.h"
#include "dnssdint.h"
}

namespace {
using Properties = std::vector<std::pair<std::string, std::string>>;
std::wstring wide(const std::string &value) {
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
    if (count <= 0) return {};
    std::wstring result(count, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), count);
    return result;
}
struct Registration {
    std::atomic<int> refs{1};
    std::mutex lock;
    HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    DNS_SERVICE_REGISTER_REQUEST request{};
    DNS_SERVICE_CANCEL cancel{};
    DWORD status = ERROR_IO_PENDING;
    bool completed = false, abandoned = false, removing = false;
    ~Registration() { if (request.pServiceInstance) DnsServiceFreeInstance(request.pServiceInstance); if (done) CloseHandle(done); }
    void release() { if (refs.fetch_sub(1) == 1) delete this; }
    static void remove_instance(PDNS_SERVICE_INSTANCE instance) {
        auto *operation = new Registration;
        operation->removing = true;
        operation->request.Version = DNS_QUERY_REQUEST_VERSION1;
        operation->request.pServiceInstance = DnsServiceCopyInstance(instance);
        operation->request.pRegisterCompletionCallback = complete;
        operation->request.pQueryContext = operation;
        operation->request.unicastEnabled = FALSE;
        if (!operation->request.pServiceInstance || DnsServiceDeRegister(&operation->request, nullptr) != DNS_REQUEST_PENDING)
            operation->release();
        // The callback owns this operation until withdrawal completes.
    }
    static VOID WINAPI complete(DWORD status, PVOID context, PDNS_SERVICE_INSTANCE instance) {
        auto *operation = static_cast<Registration *>(context);
        {
            std::lock_guard<std::mutex> guard(operation->lock);
            operation->status = status; operation->completed = true;
            if (operation->abandoned && !operation->removing && status == ERROR_SUCCESS)
                remove_instance(instance ? instance : operation->request.pServiceInstance);
            if (instance) DnsServiceFreeInstance(instance);
            SetEvent(operation->done);
        }
        operation->release();
    }
    void withdraw() {
        bool cancel_pending = false;
        { std::lock_guard<std::mutex> guard(lock);
          abandoned = true;
          if (completed && status == ERROR_SUCCESS) remove_instance(request.pServiceInstance);
          else if (!completed) cancel_pending = true; }
        if (cancel_pending) DnsServiceRegisterCancel(&cancel);
    }
};
struct Service {
    Registration *registration = nullptr;
    std::vector<uint8_t> txt;
    ~Service() { if (registration) { registration->withdraw(); registration->release(); } }
};
std::vector<uint8_t> txt_record(const Properties &properties) {
    std::vector<uint8_t> result;
    for (const auto &item : properties) {
        const auto entry = item.first + "=" + item.second;
        if (entry.size() > 255) return {};
        result.push_back(static_cast<uint8_t>(entry.size()));
        result.insert(result.end(), entry.begin(), entry.end());
    }
    return result;
}
int advertise(Service &service, const std::string &name, const char *type, uint16_t port, Properties properties) {
    service.txt = txt_record(properties);
    std::vector<std::wstring> keys, values;
    for (const auto &item : properties) { keys.push_back(wide(item.first)); values.push_back(wide(item.second)); }
    std::vector<PCWSTR> key_ptrs, value_ptrs;
    for (size_t i = 0; i < keys.size(); ++i) { key_ptrs.push_back(keys[i].c_str()); value_ptrs.push_back(values[i].c_str()); }
    wchar_t hostname[256]{}; DWORD count = 256;
    if (!GetComputerNameExW(ComputerNameDnsHostname, hostname, &count)) return static_cast<int>(GetLastError());
    const auto host = std::wstring(hostname) + L".local";
    const auto service_name = wide(name) + wide(std::string(".") + type + ".local");
    auto *operation = new Registration;
    if (!operation->done) { operation->release(); return ERROR_NOT_ENOUGH_MEMORY; }
    operation->request.pServiceInstance = DnsServiceConstructInstance(service_name.c_str(), host.c_str(),
        nullptr, nullptr, port, 0, 0, static_cast<DWORD>(keys.size()), key_ptrs.data(), value_ptrs.data());
    if (!operation->request.pServiceInstance) { operation->release(); return ERROR_NOT_ENOUGH_MEMORY; }
    operation->request.Version = DNS_QUERY_REQUEST_VERSION1;
    operation->request.pRegisterCompletionCallback = Registration::complete;
    operation->request.pQueryContext = operation;
    operation->request.unicastEnabled = FALSE;
    operation->refs.fetch_add(1);
    const auto result = DnsServiceRegister(&operation->request, &operation->cancel);
    if (result != DNS_REQUEST_PENDING) { operation->release(); operation->release(); return static_cast<int>(result); }
    service.registration = operation;
    if (WaitForSingleObject(operation->done, 10000) != WAIT_OBJECT_0) return ERROR_TIMEOUT;
    std::lock_guard<std::mutex> guard(operation->lock);
    return static_cast<int>(operation->status);
}
} // namespace

struct dnssd_s {
    std::string name, hardware, pk;
    uint32_t features1 = std::strtoul(FEATURES_1, nullptr, 16), features2 = std::strtoul(FEATURES_2, nullptr, 16);
    unsigned char pin = 0;
    std::unique_ptr<Service> audio, video;
};
extern "C" dnssd_t *dnssd_init(const char *name, int name_len, const char *hardware, int length, int *error, unsigned char pin) {
    if (error) *error = DNSSD_ERROR_NOERROR;
    if (!name || name_len < 1 || !hardware || length != 6) { if (error) *error = DNSSD_ERROR_HWADDRLEN; return nullptr; }
    try {
        auto receiver = std::make_unique<dnssd_s>();
        receiver->name.assign(name, name_len); receiver->hardware.assign(hardware, length); receiver->pin = pin;
        return receiver.release();
    } catch (...) { if (error) *error = DNSSD_ERROR_OUTOFMEM; return nullptr; }
}
namespace {
std::string features(dnssd_t *receiver) {
    char value[24]{}; std::snprintf(value, sizeof(value), "0x%X,0x%X", receiver->features1, receiver->features2); return value;
}
std::string identity(dnssd_t *receiver, bool colons) {
    std::string value;
    for (const auto byte : receiver->hardware) {
        char hex[3]{}; std::snprintf(hex, sizeof(hex), "%02X", static_cast<unsigned char>(byte));
        if (colons && !value.empty()) value += ':';
        value += hex;
    }
    return value;
}
}
extern "C" int dnssd_register_raop(dnssd_t *receiver, unsigned short port) {
    if (!receiver || receiver->audio) return ERROR_INVALID_PARAMETER;
    receiver->audio = std::make_unique<Service>();
    Properties properties{{"ch", RAOP_CH}, {"cn", "1,2"}, {"da", RAOP_DA}, {"et", RAOP_ET}, {"vv", RAOP_VV},
        {"ft", features(receiver)}, {"am", GLOBAL_MODEL}, {"md", RAOP_MD}, {"rhd", RAOP_RHD},
        {"pw", receiver->pin ? "true" : "false"}, {"sf", receiver->pin ? "0x84" : RAOP_SF},
        {"sr", RAOP_SR}, {"ss", RAOP_SS}, {"sv", RAOP_SV}, {"tp", RAOP_TP}, {"txtvers", RAOP_TXTVERS},
        {"vs", RAOP_VS}, {"vn", RAOP_VN}, {"pk", receiver->pk}};
    return advertise(*receiver->audio, identity(receiver, false) + "@" + receiver->name, "_raop._tcp", port, std::move(properties));
}
extern "C" int dnssd_register_airplay(dnssd_t *receiver, unsigned short port) {
    if (!receiver || receiver->video) return ERROR_INVALID_PARAMETER;
    receiver->video = std::make_unique<Service>();
    Properties properties{{"deviceid", identity(receiver, true)}, {"features", features(receiver)},
        {"pw", receiver->pin ? "true" : "false"}, {"flags", "0x4"}, {"model", GLOBAL_MODEL}, {"pk", receiver->pk},
        {"pi", AIRPLAY_PI}, {"srcvers", AIRPLAY_SRCVERS}, {"vv", AIRPLAY_VV}};
    return advertise(*receiver->video, receiver->name, "_airplay._tcp", port, std::move(properties));
}
extern "C" void dnssd_unregister_raop(dnssd_t *receiver) { if (receiver) receiver->audio.reset(); }
extern "C" void dnssd_unregister_airplay(dnssd_t *receiver) { if (receiver) receiver->video.reset(); }
extern "C" const char *dnssd_get_raop_txt(dnssd_t *receiver, int *length) {
    *length = receiver && receiver->audio ? static_cast<int>(receiver->audio->txt.size()) : 0;
    return *length ? reinterpret_cast<const char *>(receiver->audio->txt.data()) : nullptr;
}
extern "C" const char *dnssd_get_airplay_txt(dnssd_t *receiver, int *length) {
    *length = receiver && receiver->video ? static_cast<int>(receiver->video->txt.size()) : 0;
    return *length ? reinterpret_cast<const char *>(receiver->video->txt.data()) : nullptr;
}
extern "C" const char *dnssd_get_name(dnssd_t *receiver, int *length) { *length = static_cast<int>(receiver->name.size()); return receiver->name.data(); }
extern "C" const char *dnssd_get_hw_addr(dnssd_t *receiver, int *length) { *length = static_cast<int>(receiver->hardware.size()); return receiver->hardware.data(); }
extern "C" void dnssd_set_pk(dnssd_t *receiver, char *key) { receiver->pk = key ? key : ""; }
extern "C" uint64_t dnssd_get_airplay_features(dnssd_t *receiver) { return (uint64_t(receiver->features2) << 32) | receiver->features1; }
extern "C" void dnssd_set_airplay_features(dnssd_t *receiver, int bit, int value) {
    if (!receiver || bit < 0 || bit > 63 || (value != 0 && value != 1)) return;
    auto &word = bit < 32 ? receiver->features1 : receiver->features2;
    const uint32_t mask = uint32_t(1) << (bit % 32); word = value ? word | mask : word & ~mask;
}
extern "C" void dnssd_destroy(dnssd_t *receiver) { delete receiver; }
