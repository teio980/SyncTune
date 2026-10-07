#include "probe_channel.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <processthreadsapi.h>
#include <shobjidl.h>
#include <windows.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.FileProperties.h>
#include <winrt/Windows.Storage.Search.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Security.Credentials.h>
#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Storage.AccessCache.h>
#include <winrt/Windows.Storage.Pickers.h>

#include <memory>
#include <string>
#include <atomic>
#include <sstream>
#include <algorithm>
#include <cwctype>
#include <optional>
#include <vector>
#include <exception>
#include <unordered_map>
#include <mutex>
#include <bcrypt.h>
#include <array>
#include <iomanip>
#include <cctype>
#include <stdexcept>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::Security::Credentials::PasswordCredential;
using winrt::Windows::Security::Credentials::PasswordVault;
using winrt::Windows::Storage::AccessCache::StorageApplicationPermissions;
using winrt::Windows::Storage::ApplicationData;
using winrt::Windows::Storage::CreationCollisionOption;
using winrt::Windows::Storage::NameCollisionOption;
using winrt::Windows::Storage::FileIO;
using winrt::Windows::Storage::Pickers::FolderPicker;
using winrt::Windows::Storage::Pickers::PickerLocationId;
using winrt::Windows::Storage::StorageFile;
using winrt::Windows::Storage::StorageFolder;
using winrt::Windows::Storage::StorageItemTypes;
using winrt::Windows::Storage::FileAccessMode;
using winrt::Windows::Storage::Streams::DataReader;
using winrt::Windows::Storage::Streams::DataWriter;

constexpr auto kTokenFileName = L"synctune_probe_folder_token.txt";
constexpr auto kActiveRootFileName = L"synctune_active_root.txt";
std::mutex g_credential_mutex;

std::wstring NewMarkerName() {
  GUID guid{};
  if (FAILED(CoCreateGuid(&guid))) {
    throw std::runtime_error("CoCreateGuid failed");
  }
  wchar_t text[64]{};
  if (StringFromGUID2(guid, text, ARRAYSIZE(text)) == 0) {
    throw std::runtime_error("StringFromGUID2 failed");
  }
  return L"synctune_probe_marker_" + std::wstring(text + 1, text + 37) + L".txt";
}

std::wstring MarkerText() {
  std::wstringstream stream;
  stream << L"synctune-probe-marker-pid-" << GetCurrentProcessId()
         << L"-tick-" << GetTickCount64();
  return stream.str();
}

std::wstring NewGeneration() {
  GUID guid{};
  if (FAILED(CoCreateGuid(&guid))) {
    throw std::runtime_error("CoCreateGuid failed");
  }
  wchar_t text[64]{};
  if (StringFromGUID2(guid, text, ARRAYSIZE(text)) == 0) {
    throw std::runtime_error("StringFromGUID2 failed");
  }
  return std::wstring(text + 1, text + 37);
}

bool IsAlive(const std::shared_ptr<std::atomic_bool>& alive) {
  return alive && alive->load();
}

bool IsAppContainer() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  DWORD value = 0;
  DWORD length = 0;
  const bool ok = GetTokenInformation(token, TokenIsAppContainer, &value,
                                      sizeof(value), &length) && value != 0;
  CloseHandle(token);
  return ok;
}

std::vector<PasswordCredential> CredentialsFor(const std::string& service,
                                               const std::string& account);
void ReplaceCredential(const std::string& service, const std::string& account,
                       const std::string& secret);

EncodableValue CredentialRoundTrip() {
  std::lock_guard<std::mutex> guard(g_credential_mutex);
  constexpr auto resource = L"SyncTune.AppContainer.Probe";
  constexpr auto username = L"probe-user";
  constexpr auto password = L"probe-secret";
  bool restart_check = false;
  const auto existing = CredentialsFor(winrt::to_string(resource),
                                       winrt::to_string(username));
  if (!existing.empty()) {
    auto persisted = existing.front();
    persisted.RetrievePassword();
    restart_check = persisted.Password() == password;
  }
  ReplaceCredential(winrt::to_string(resource), winrt::to_string(username),
                    winrt::to_string(password));
  PasswordCredential credential(resource, username, password);
  credential.RetrievePassword();
  const bool found = credential.UserName() == username && credential.Password() == password;
  return EncodableMap{{EncodableValue("status"), EncodableValue(found ? "ok" : "failed")},
                      {EncodableValue("restartCheck"),
                       EncodableValue(restart_check ? "ok" : "pending")},
                      {EncodableValue("appContainer"),
                       EncodableValue(IsAppContainer() ? "true" : "false")}};
}

EncodableValue PrivateDatabasePath() {
  const auto local_folder = ApplicationData::Current().LocalFolder();
  return EncodableValue(winrt::to_string(
      local_folder.Path() + L"\\synctune_probe.sqlite"));
}

EncodableValue ProcessInfo() {
  const auto version =
      winrt::Windows::ApplicationModel::Package::Current().Id().Version();
  const auto version_text = std::to_wstring(version.Major) + L"." +
                             std::to_wstring(version.Minor) + L"." +
                             std::to_wstring(version.Build) + L"." +
                             std::to_wstring(version.Revision);
  const auto family = winrt::Windows::ApplicationModel::Package::Current()
                          .Id()
                          .FamilyName();
  return EncodableMap{
      {EncodableValue("pid"),
       EncodableValue(static_cast<int64_t>(GetCurrentProcessId()))},
      {EncodableValue("appContainer"),
       EncodableValue(IsAppContainer() ? "true" : "false")},
      {EncodableValue("packageVersion"),
       EncodableValue(winrt::to_string(version_text))},
      {EncodableValue("packageFamily"),
       EncodableValue(winrt::to_string(family))}};
}

using MethodResult = flutter::MethodResult<EncodableValue>;
using SharedResult = std::shared_ptr<MethodResult>;

// FolderPicker, restore, and the private LocalState writes all use fixed
// filenames. Keep those broker operations serialized so two coroutines cannot
// overwrite the same .tmp file or reconcile the FAL against different roots.
std::shared_ptr<std::atomic_bool> g_broker_busy =
    std::make_shared<std::atomic_bool>(false);

class BusyLease {
 public:
  BusyLease() : acquired_(false) {
    bool expected = false;
    acquired_ = g_broker_busy->compare_exchange_strong(
        expected, true, std::memory_order_acq_rel);
  }
  BusyLease(const BusyLease&) = delete;
  BusyLease& operator=(const BusyLease&) = delete;
  ~BusyLease() {
    if (acquired_) g_broker_busy->store(false, std::memory_order_release);
  }
  bool acquired() const { return acquired_; }

 private:
  bool acquired_;
};

winrt::Windows::Foundation::IAsyncOperation<winrt::hstring> ReadTokenAsync() {
  try {
    auto local_folder = ApplicationData::Current().LocalFolder();
    auto file = co_await local_folder.GetFileAsync(kTokenFileName);
    co_return co_await FileIO::ReadTextAsync(file);
  } catch (const winrt::hresult_error& error) {
    if (error.code() == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)) {
      co_return winrt::hstring();
    }
    throw;
  }
}

winrt::Windows::Foundation::IAsyncOperation<bool> WriteTextAsync(
    const winrt::Windows::Storage::StorageFolder& folder,
    const winrt::hstring& file_name,
    const winrt::hstring& text) {
  auto file = co_await folder.CreateFileAsync(
      file_name, CreationCollisionOption::ReplaceExisting);
  co_await FileIO::WriteTextAsync(file, text);
  co_return true;
}

winrt::Windows::Foundation::IAsyncOperation<bool> WriteTextAtomicAsync(
    const winrt::Windows::Storage::StorageFolder& folder,
    const winrt::hstring& file_name,
    const winrt::hstring& text) {
  const auto temporary_name = file_name + winrt::hstring(L".tmp");
  auto temporary = co_await folder.CreateFileAsync(
      temporary_name, CreationCollisionOption::ReplaceExisting);
  co_await FileIO::WriteTextAsync(temporary, text);
  winrt::Windows::Storage::StorageFile destination{nullptr};
  bool has_destination = false;
  try {
    destination = co_await folder.GetFileAsync(file_name);
    has_destination = true;
  } catch (const winrt::hresult_error& error) {
    if (error.code() != HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)) throw;
  }
  if (has_destination) {
    co_await temporary.MoveAndReplaceAsync(destination);
  } else {
    co_await temporary.RenameAsync(file_name, NameCollisionOption::FailIfExists);
  }
  co_return true;
}

winrt::Windows::Foundation::IAsyncOperation<bool> ValidateFolderAsync(
    const winrt::Windows::Storage::StorageFolder& folder) {
  const auto name = NewMarkerName();
  const auto expected = MarkerText();
  auto file = co_await folder.CreateFileAsync(
      name, CreationCollisionOption::FailIfExists);
  bool valid = false;
  std::exception_ptr failure;
  try {
    co_await FileIO::WriteTextAsync(file, expected);
    const auto actual = co_await FileIO::ReadTextAsync(file);
    valid = actual == expected;
  } catch (...) {
    failure = std::current_exception();
  }
  // Providers can fail after creating the probe. Always attempt cleanup, and
  // preserve the original failure when both the I/O and cleanup fail.
  try {
    co_await file.DeleteAsync();
  } catch (...) {
    if (!failure) failure = std::current_exception();
  }
  if (failure) std::rethrow_exception(failure);
  co_return valid;
}

winrt::Windows::Foundation::IAsyncAction ReadFolderMetadataAsync(
    const winrt::Windows::Storage::StorageFolder& folder) {
  co_await folder.GetBasicPropertiesAsync();
}

bool ReconcileRootAccessList(const winrt::hstring& keep_token) {
  auto list = StorageApplicationPermissions::FutureAccessList();
  for (const auto& entry : list.Entries()) {
    if (entry.Token == keep_token) continue;
    try {
      list.Remove(entry.Token);
    } catch (...) {
      // A failed remove is a hard reconciliation failure. Returning success
      // here would leave a second authorization silently active.
      return false;
    }
  }
  const auto remaining = list.Entries();
  size_t kept = 0;
  for (const auto& entry : remaining) {
    if (entry.Token == keep_token) {
      kept++;
    } else {
      return false;
    }
  }
  return keep_token.empty() ? kept == 0 : kept == 1;
}

winrt::Windows::Foundation::IAsyncOperation<winrt::hstring>
ReadActiveRootAsync() {
  try {
    auto local_folder = ApplicationData::Current().LocalFolder();
    auto file = co_await local_folder.GetFileAsync(kActiveRootFileName);
    co_return co_await FileIO::ReadTextAsync(file);
  } catch (const winrt::hresult_error& error) {
    if (error.code() == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)) {
      co_return winrt::hstring();
    }
    throw;
  }
}

winrt::Windows::Foundation::IAsyncOperation<bool> ClearActiveRootAsync() {
  try {
    auto local_folder = ApplicationData::Current().LocalFolder();
    auto file = co_await local_folder.GetFileAsync(kActiveRootFileName);
    co_await file.DeleteAsync();
  } catch (const winrt::hresult_error& error) {
    if (error.code() != HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)) throw;
  }
  co_return true;
}

struct ActiveRoot {
  winrt::hstring token;
  winrt::hstring path;
  winrt::hstring generation;
};

struct StageSession {
  winrt::hstring token;
  winrt::hstring generation;
  StorageFile file{nullptr};
  uint64_t next_offset = 0;
};

std::mutex g_stage_mutex;
std::unordered_map<std::string, StageSession> g_stage_sessions;

std::optional<ActiveRoot> ParseActiveRoot(const winrt::hstring& record) {
  const auto text = winrt::to_string(record);
  const auto first = text.find('\n');
  const auto second = first == std::string::npos
                          ? std::string::npos
                          : text.find('\n', first + 1);
  if (first == std::string::npos || second == std::string::npos ||
      first == 0 || second == first + 1 || second + 1 >= text.size()) {
    return std::nullopt;
  }
  const auto token = text.substr(0, first);
  const auto path = text.substr(first + 1, second - first - 1);
  const auto generation = text.substr(second + 1);
  if (token.empty() || path.empty() || generation.empty() ||
      generation.find('\n') != std::string::npos) {
    return std::nullopt;
  }
  return ActiveRoot{winrt::to_hstring(token), winrt::to_hstring(path),
                    winrt::to_hstring(generation)};
}

std::string ArgumentString(const flutter::EncodableValue* arguments,
                           const char* key) {
  if (arguments == nullptr) return {};
  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) return {};
  const auto found = map->find(EncodableValue(key));
  if (found == map->end()) return {};
  const auto* value = std::get_if<std::string>(&found->second);
  return value == nullptr ? std::string() : *value;
}

bool HasStringArgument(const flutter::EncodableValue* arguments,
                       const char* key) {
  if (arguments == nullptr) return false;
  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) return false;
  const auto found = map->find(EncodableValue(key));
  return found != map->end() &&
         std::get_if<std::string>(&found->second) != nullptr;
}

std::string NormalizeCredentialComponent(std::string value) {
  const auto first = value.find_first_not_of(" \t\r\n");
  const auto last = value.find_last_not_of(" \t\r\n");
  if (first == std::string::npos) {
    throw std::invalid_argument("invalid credential key");
  }
  value = value.substr(first, last - first + 1);
  if (value.empty() || value.size() > 128) {
    throw std::invalid_argument("invalid credential key");
  }
  for (auto& character : value) {
    const auto byte = static_cast<unsigned char>(character);
    if (byte <= 31 || byte == 127 || character == '/' || character == '\\' ||
        character == ':') {
      throw std::invalid_argument("invalid credential key");
    }
    if (character >= 'A' && character <= 'Z') {
      character = static_cast<char>(character - 'A' + 'a');
    }
  }
  return value;
}

std::vector<PasswordCredential> CredentialsFor(
    const std::string& service, const std::string& account) {
  std::vector<PasswordCredential> matches;
  try {
    const auto entries = PasswordVault().FindAllByResource(
        winrt::to_hstring(service));
    for (uint32_t index = 0; index < entries.Size(); ++index) {
      auto entry = entries.GetAt(index);
      if (winrt::to_string(entry.UserName()) == account) {
        matches.push_back(entry);
      }
    }
  } catch (const winrt::hresult_error& error) {
    if (error.code() != HRESULT_FROM_WIN32(ERROR_NOT_FOUND)) throw;
  }
  return matches;
}

void ReplaceCredential(const std::string& service, const std::string& account,
                       const std::string& secret) {
  auto vault = PasswordVault();
  const auto existing = CredentialsFor(service, account);
  std::vector<std::string> old_passwords;
  old_passwords.reserve(existing.size());
  for (auto entry : existing) {
    entry.RetrievePassword();
    old_passwords.push_back(winrt::to_string(entry.Password()));
  }
  try {
    for (const auto& entry : existing) vault.Remove(entry);
    vault.Add(PasswordCredential(winrt::to_hstring(service),
                                 winrt::to_hstring(account),
                                 winrt::to_hstring(secret)));
  } catch (...) {
    // PasswordVault has no replace transaction. Restore every old value before
    // surfacing the original failure; if rollback itself fails, report an
    // explicit recovery error rather than pretending the old value survived.
    bool restored = true;
    try {
      for (const auto& old_password : old_passwords) {
        vault.Add(PasswordCredential(winrt::to_hstring(service),
                                     winrt::to_hstring(account),
                                     winrt::to_hstring(old_password)));
      }
    } catch (...) {
      restored = false;
    }
    if (!restored) {
      throw std::runtime_error("credential replacement recovery failed");
    }
    throw;
  }
}

EncodableValue CredentialSave(const flutter::EncodableValue& arguments) {
  std::lock_guard<std::mutex> guard(g_credential_mutex);
  const auto service = NormalizeCredentialComponent(
      ArgumentString(&arguments, "service"));
  const auto account = NormalizeCredentialComponent(
      ArgumentString(&arguments, "account"));
  const auto secret = ArgumentString(&arguments, "secret");
  if (!HasStringArgument(&arguments, "secret")) {
    throw std::invalid_argument("missing credential secret");
  }
  ReplaceCredential(service, account, secret);
  return EncodableMap{{EncodableValue("status"), EncodableValue("ok")},
                      {EncodableValue("stored"), EncodableValue(true)}};
}

EncodableValue CredentialRead(const flutter::EncodableValue& arguments) {
  std::lock_guard<std::mutex> guard(g_credential_mutex);
  const auto service = NormalizeCredentialComponent(
      ArgumentString(&arguments, "service"));
  const auto account = NormalizeCredentialComponent(
      ArgumentString(&arguments, "account"));
  const auto matches = CredentialsFor(service, account);
  if (matches.empty()) {
    return EncodableMap{{EncodableValue("status"), EncodableValue("ok")},
                        {EncodableValue("found"), EncodableValue(false)}};
  }
  auto credential = matches.front();
  credential.RetrievePassword();
  return EncodableMap{
      {EncodableValue("status"), EncodableValue("ok")},
      {EncodableValue("found"), EncodableValue(true)},
      {EncodableValue("secret"), EncodableValue(winrt::to_string(
                                                   credential.Password()))}};
}

EncodableValue CredentialDelete(const flutter::EncodableValue& arguments) {
  std::lock_guard<std::mutex> guard(g_credential_mutex);
  const auto service = NormalizeCredentialComponent(
      ArgumentString(&arguments, "service"));
  const auto account = NormalizeCredentialComponent(
      ArgumentString(&arguments, "account"));
  auto vault = PasswordVault();
  for (const auto& entry : CredentialsFor(service, account)) {
    vault.Remove(entry);
  }
  return EncodableMap{{EncodableValue("status"), EncodableValue("ok")},
                      {EncodableValue("deleted"), EncodableValue(true)}};
}

EncodableValue BrokerCapabilities() {
  // StorageFile.OpenTransactedWriteAsync/StorageStreamTransaction is a
  // possible future replace primitive, but this broker has not completed the
  // provider capability and post-commit verification gate. Do not advertise
  // it as compare-and-swap yet.
  return EncodableMap{
      {EncodableValue("status"), EncodableValue("ok")},
      {EncodableValue("platform"), EncodableValue("windows")},
      {EncodableValue("credentials"), EncodableValue("windows_password_vault")},
      {EncodableValue("staging"),
       EncodableValue("persistent_after_finish_root_scoped")},
      {EncodableValue("atomicCreate"),
       EncodableValue("fail_if_exists_verified")},
      {EncodableValue("conditionalReplace"),
       EncodableValue("unsupported_appcontainer_provider")},
      {EncodableValue("conditionalDelete"),
       EncodableValue("unsupported_appcontainer_provider")},
      {EncodableValue("temporaryPermission"), EncodableValue("not_applicable")}};
}

bool IsMusicExtension(std::wstring extension) {
  std::transform(extension.begin(), extension.end(), extension.begin(),
                 [](wchar_t value) { return std::towlower(value); });
  return extension == L"mp3" || extension == L"flac" ||
         extension == L"wav" || extension == L"m4a" || extension == L"aac" ||
         extension == L"ogg" || extension == L"opus";
}

std::optional<std::wstring> RelativePath(const std::wstring& root,
                                          const std::wstring& full) {
  auto normalized_root = root;
  // Trim the root separator even for a drive root (C:\\). Comparing against
  // the untrimmed three-character root made C:\\song.mp3 fail the boundary
  // check, while slicing with root.size() also dropped the first character for
  // roots that arrived with a trailing separator.
  while (!normalized_root.empty() &&
         (normalized_root.back() == L'\\' || normalized_root.back() == L'/')) {
    normalized_root.pop_back();
  }
  if (full.size() <= normalized_root.size() ||
      _wcsnicmp(normalized_root.c_str(), full.c_str(), normalized_root.size()) !=
          0 ||
      (full[normalized_root.size()] != L'\\' &&
       full[normalized_root.size()] != L'/')) {
    return std::nullopt;
  }
  auto relative = full.substr(normalized_root.size());
  while (!relative.empty() && (relative.front() == L'\\' ||
                               relative.front() == L'/')) {
    relative.erase(relative.begin());
  }
  if (relative.empty()) return std::nullopt;
  std::replace(relative.begin(), relative.end(), L'\\', L'/');
  static constexpr const wchar_t* kReserved[] = {
      L"CON", L"PRN", L"AUX", L"NUL", L"COM1", L"COM2", L"COM3", L"COM4",
      L"COM5", L"COM6", L"COM7", L"COM8", L"COM9", L"LPT1", L"LPT2", L"LPT3",
      L"LPT4", L"LPT5", L"LPT6", L"LPT7", L"LPT8", L"LPT9"};
  size_t segment_start = 0;
  while (segment_start < relative.size()) {
    const auto slash = relative.find(L'/', segment_start);
    const auto segment_end = slash == std::wstring::npos ? relative.size() : slash;
    const auto segment = relative.substr(segment_start, segment_end - segment_start);
    if (segment.empty() || segment == L"." || segment == L".." ||
        segment.back() == L'.' || segment.back() == L' ' ||
        segment.find(L':') != std::wstring::npos ||
        segment.find_first_of(L"<>\"|?*") != std::wstring::npos ||
        std::any_of(segment.begin(), segment.end(), [](wchar_t value) {
          return value <= 31 || value == 127;
        })) {
      return std::nullopt;
    }
    if (_wcsicmp(segment.c_str(), L".synctune") == 0 ||
        _wcsicmp(segment.c_str(), L".synctune-local") == 0) {
      return std::nullopt;
    }
    const auto basename = segment.substr(0, segment.find(L'.'));
    for (const auto reserved : kReserved) {
      if (_wcsicmp(basename.c_str(), reserved) == 0) return std::nullopt;
    }
    if (slash == std::wstring::npos) break;
    segment_start = slash + 1;
  }
  return relative;
}

std::vector<winrt::hstring> RelativeSegments(const std::string& raw) {
  if (raw.empty() || raw.front() == '/' || raw.find('\\') != std::string::npos ||
      (raw.size() >= 2 && std::isalpha(static_cast<unsigned char>(raw[0])) &&
       raw[1] == ':')) {
    throw std::invalid_argument("path must be a canonical relative path");
  }
  std::vector<winrt::hstring> parts;
  size_t start = 0;
  while (start <= raw.size()) {
    const auto slash = raw.find('/', start);
    const auto end = slash == std::string::npos ? raw.size() : slash;
    const auto text = raw.substr(start, end - start);
    const auto wide = winrt::to_hstring(text);
    if (text.empty() || text == "." || text == ".." || text.find(':') != std::string::npos ||
        text.back() == '.' || text.back() == ' ' ||
        text.find_first_of("<>\"|?*") != std::string::npos ||
        std::any_of(wide.c_str(), wide.c_str() + wide.size(), [](wchar_t value) {
          return value <= 31 || value == 127;
        }) ||
        _wcsicmp(wide.c_str(), L".synctune") == 0 ||
        _wcsicmp(wide.c_str(), L".synctune-local") == 0) {
      throw std::invalid_argument("invalid relative path segment");
    }
    const auto basename = std::wstring(wide).substr(0, std::wstring(wide).find(L'.'));
    static constexpr const wchar_t* kReserved[] = {
        L"CON", L"PRN", L"AUX", L"NUL", L"COM1", L"COM2", L"COM3", L"COM4",
        L"COM5", L"COM6", L"COM7", L"COM8", L"COM9", L"LPT1", L"LPT2", L"LPT3",
        L"LPT4", L"LPT5", L"LPT6", L"LPT7", L"LPT8", L"LPT9"};
    for (const auto reserved : kReserved) {
      if (_wcsicmp(basename.c_str(), reserved) == 0) {
        throw std::invalid_argument("reserved path segment");
      }
    }
    parts.push_back(wide);
    if (slash == std::string::npos) break;
    start = slash + 1;
  }
  return parts;
}

int64_t ArgumentInt64(const flutter::EncodableValue* arguments,
                      const char* key, int64_t fallback = -1) {
  if (arguments == nullptr) return fallback;
  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) return fallback;
  const auto found = map->find(EncodableValue(key));
  if (found == map->end()) return fallback;
  if (const auto* value = std::get_if<int64_t>(&found->second)) return *value;
  if (const auto* value = std::get_if<int32_t>(&found->second)) return *value;
  return fallback;
}

std::vector<uint8_t> ArgumentBytes(const flutter::EncodableValue* arguments,
                                   const char* key) {
  if (arguments == nullptr) return {};
  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) return {};
  const auto found = map->find(EncodableValue(key));
  if (found == map->end()) return {};
  if (const auto* value = std::get_if<std::vector<uint8_t>>(&found->second)) {
    return *value;
  }
  return {};
}

winrt::Windows::Foundation::IAsyncOperation<bool> IsSafeFolderAsync(
    const StorageFolder& folder);
winrt::Windows::Foundation::IAsyncOperation<bool> IsSafeFileAsync(
    const StorageFile& file);

winrt::Windows::Foundation::IAsyncOperation<StorageFolder>
AuthorizedFolderAsync(const winrt::hstring& token,
                      const winrt::hstring& generation) {
  const auto record = co_await ReadActiveRootAsync();
  const auto active = ParseActiveRoot(record);
  if (!active.has_value() || active->token != token ||
      active->generation != generation) {
    throw std::runtime_error("authorized root generation changed");
  }
  auto folder = co_await StorageApplicationPermissions::FutureAccessList()
                    .GetFolderAsync(token);
  if (_wcsicmp(active->path.c_str(), folder.Path().c_str()) != 0) {
    throw std::runtime_error("authorized root path changed");
  }
  if (!co_await IsSafeFolderAsync(folder)) {
    throw std::runtime_error("authorized root is a reparse point");
  }
  co_return folder;
}

winrt::Windows::Foundation::IAsyncOperation<StorageFolder>
ResolveParentAsync(const StorageFolder& root, const std::string& path) {
  const auto parts = RelativeSegments(path);
  auto folder = root;
  for (size_t i = 0; i + 1 < parts.size(); ++i) {
    folder = co_await folder.GetFolderAsync(parts[i]);
    if (!co_await IsSafeFolderAsync(folder)) {
      throw std::runtime_error("path traverses a reparse point");
    }
  }
  co_return folder;
}

winrt::Windows::Foundation::IAsyncOperation<StorageFile>
ResolveFileAsync(const StorageFolder& root, const std::string& path) {
  const auto parts = RelativeSegments(path);
  auto folder = co_await ResolveParentAsync(root, path);
  auto file = co_await folder.GetFileAsync(parts.back());
  if (!co_await IsSafeFileAsync(file)) {
    throw std::runtime_error("path resolves to a reparse point");
  }
  co_return file;
}

winrt::Windows::Foundation::IAsyncOperation<StorageFolder>
StageFolderAsync(const StorageFolder& root) {
  try {
    auto folder = co_await root.GetFolderAsync(L".synctune-local");
    if (!co_await IsSafeFolderAsync(folder)) {
      throw std::runtime_error("staging directory is a reparse point");
    }
    co_return folder;
  } catch (const winrt::hresult_error& error) {
    if (error.code() != HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)) throw;
  }
  auto folder = co_await root.CreateFolderAsync(
      L".synctune-local", CreationCollisionOption::FailIfExists);
  if (!co_await IsSafeFolderAsync(folder)) {
    throw std::runtime_error("staging directory is a reparse point");
  }
  co_return folder;
}

bool IsUuidText(const std::string& value) {
  if (value.size() != 36 || value[8] != '-' || value[13] != '-' ||
      value[18] != '-' || value[23] != '-') {
    return false;
  }
  for (size_t index = 0; index < value.size(); ++index) {
    if (index == 8 || index == 13 || index == 18 || index == 23) continue;
    if (std::isxdigit(static_cast<unsigned char>(value[index])) == 0) return false;
  }
  return true;
}

winrt::Windows::Foundation::IAsyncOperation<StorageFile>
StageFileAsync(const StorageFolder& root, const std::string& key) {
  if (!IsUuidText(key)) {
    throw std::invalid_argument("invalid staging handle");
  }
  auto folder = co_await StageFolderAsync(root);
  auto file = co_await folder.GetFileAsync(winrt::to_hstring(key + ".part"));
  if (!co_await IsSafeFileAsync(file)) {
    throw std::runtime_error("staged object is a reparse point");
  }
  co_return file;
}

// Returns "<lowercase sha256>:<decimal length>" so the coroutine result is a
// WinRT type while retaining both values for protocol verification.
winrt::Windows::Foundation::IAsyncOperation<winrt::hstring>
HashFileAsync(const StorageFile& file) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_length = 0;
  DWORD result_length = 0;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                  nullptr, 0) < 0) {
    throw std::runtime_error("BCryptOpenAlgorithmProvider failed");
  }
  auto close_algorithm = [&]() {
    if (hash != nullptr) BCryptDestroyHash(hash);
    if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
  };
  try {
    if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                          reinterpret_cast<PUCHAR>(&object_length),
                          sizeof(object_length), &result_length, 0) < 0) {
      throw std::runtime_error("BCryptGetProperty failed");
    }
    std::vector<uint8_t> object(object_length);
    if (BCryptCreateHash(algorithm, &hash, object.data(),
                         static_cast<ULONG>(object.size()),
                         nullptr, 0, 0) < 0) {
      throw std::runtime_error("BCryptCreateHash failed");
    }
    auto stream = co_await file.OpenAsync(FileAccessMode::Read);
    const auto stream_size = stream.Size();
    auto input = stream.GetInputStreamAt(0);
    DataReader reader(input);
    uint64_t length = 0;
    constexpr uint32_t kChunk = 64 * 1024;
    while (length < stream_size) {
      const auto requested = static_cast<uint32_t>(
          std::min<uint64_t>(kChunk, stream_size - length));
      const auto loaded = co_await reader.LoadAsync(requested);
      if (loaded == 0) {
        throw std::runtime_error("file stream ended before its reported length");
      }
      std::vector<uint8_t> bytes(loaded);
      reader.ReadBytes(bytes);
      if (BCryptHashData(hash, bytes.data(), loaded, 0) < 0) {
        throw std::runtime_error("BCryptHashData failed");
      }
      length += loaded;
    }
    if (length != stream_size) {
      throw std::runtime_error("file stream length changed during hashing");
    }
    reader.Close();
    stream.Close();
    std::array<uint8_t, 32> digest{};
    if (BCryptFinishHash(hash, digest.data(),
                         static_cast<ULONG>(digest.size()), 0) < 0) {
      throw std::runtime_error("BCryptFinishHash failed");
    }
    std::ostringstream text;
    text << std::hex << std::setfill('0');
    for (const auto byte : digest) text << std::setw(2) << static_cast<int>(byte);
    close_algorithm();
    co_return winrt::to_hstring(text.str() + ":" + std::to_string(length));
  } catch (...) {
    close_algorithm();
    throw;
  }
}

struct HashedFile {
  std::string sha256;
  uint64_t length;
};

bool IsSha256Text(const std::string& value) {
  return value.size() == 64 &&
         std::all_of(value.begin(), value.end(), [](char character) {
           return std::isxdigit(static_cast<unsigned char>(character)) != 0;
         });
}

HashedFile ParseHashedFile(const winrt::hstring& encoded) {
  const auto text = winrt::to_string(encoded);
  const auto separator = text.rfind(':');
  if (separator == std::string::npos || separator == 0 || separator + 1 >= text.size() ||
      !IsSha256Text(text.substr(0, separator))) {
    throw std::runtime_error("invalid hash response");
  }
  const auto length_text = text.substr(separator + 1);
  size_t consumed = 0;
  const auto length = std::stoull(length_text, &consumed);
  if (consumed != length_text.size()) throw std::runtime_error("invalid hash length");
  return HashedFile{text.substr(0, separator), length};
}

const EncodableMap* ArgumentMap(const flutter::EncodableValue* arguments,
                               const char* key) {
  if (arguments == nullptr) return nullptr;
  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) return nullptr;
  const auto found = map->find(EncodableValue(key));
  if (found == map->end()) return nullptr;
  return std::get_if<EncodableMap>(&found->second);
}

std::string MapString(const EncodableMap* map, const char* key) {
  if (map == nullptr) return {};
  const auto found = map->find(EncodableValue(key));
  if (found == map->end()) return {};
  const auto* value = std::get_if<std::string>(&found->second);
  return value == nullptr ? std::string() : *value;
}

int64_t MapInt64(const EncodableMap* map, const char* key,
                int64_t fallback = -1) {
  if (map == nullptr) return fallback;
  const auto found = map->find(EncodableValue(key));
  if (found == map->end()) return fallback;
  if (const auto* value = std::get_if<int64_t>(&found->second)) return *value;
  if (const auto* value = std::get_if<int32_t>(&found->second)) return *value;
  return fallback;
}

std::string BrokerToken(const flutter::EncodableValue& arguments) {
  return ArgumentString(&arguments, "token");
}

winrt::fire_and_forget ReadChunkAsync(
    flutter::EncodableValue arguments, SharedResult result,
    std::shared_ptr<std::atomic_bool> alive) {
  BusyLease lease;
  if (!lease.acquired()) {
    if (IsAlive(alive)) result->Error("busy", "Another broker operation is in progress.");
    co_return;
  }
  try {
    const auto token_text = BrokerToken(arguments);
    const auto generation_text = ArgumentString(&arguments, "generation");
    const auto path = ArgumentString(&arguments, "path");
    const auto offset = ArgumentInt64(&arguments, "offset", 0);
    const auto max_bytes = ArgumentInt64(&arguments, "maxBytes", 64 * 1024);
    if (token_text.empty() || generation_text.empty() || path.empty() || offset < 0 ||
        max_bytes < 1 || max_bytes > 1024 * 1024) {
      throw std::invalid_argument("invalid read request");
    }
    auto root = co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                               winrt::to_hstring(generation_text));
    auto file = co_await ResolveFileAsync(root, path);
    co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                   winrt::to_hstring(generation_text));
    auto stream = co_await file.OpenAsync(FileAccessMode::Read);
    const auto stream_size = stream.Size();
    if (static_cast<uint64_t>(offset) > stream_size) {
      throw std::runtime_error("read offset exceeds file length");
    }
    const auto requested_total = std::min<uint64_t>(
        static_cast<uint64_t>(max_bytes), stream_size - static_cast<uint64_t>(offset));
    auto input = stream.GetInputStreamAt(static_cast<uint64_t>(offset));
    DataReader reader(input);
    std::vector<uint8_t> bytes;
    while (bytes.size() < requested_total) {
      const auto requested = static_cast<uint32_t>(
          std::min<uint64_t>(64 * 1024, requested_total - bytes.size()));
      const auto loaded = co_await reader.LoadAsync(requested);
      if (loaded == 0) break;
      std::vector<uint8_t> chunk(loaded);
      reader.ReadBytes(chunk);
      bytes.insert(bytes.end(), chunk.begin(), chunk.end());
    }
    reader.Close();
    stream.Close();
    co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                   winrt::to_hstring(generation_text));
    if (IsAlive(alive)) {
      const auto bytes_read = bytes.size();
      result->Success(EncodableMap{
          {EncodableValue("status"), EncodableValue("ok")},
          {EncodableValue("bytes"), EncodableValue(std::move(bytes))},
          {EncodableValue("offset"), EncodableValue(offset)},
          {EncodableValue("nextOffset"),
           EncodableValue(offset + static_cast<int64_t>(bytes_read))},
          {EncodableValue("eof"),
           EncodableValue(bytes_read < static_cast<size_t>(max_bytes))}});
    }
  } catch (const winrt::hresult_error& error) {
    if (IsAlive(alive)) result->Error("broker_error", winrt::to_string(error.message()));
  } catch (const std::exception& error) {
    if (IsAlive(alive)) result->Error("broker_error", error.what());
  }
}

winrt::fire_and_forget StageBeginAsync(
    flutter::EncodableValue arguments, SharedResult result,
    std::shared_ptr<std::atomic_bool> alive) {
  BusyLease lease;
  if (!lease.acquired()) {
    if (IsAlive(alive)) result->Error("busy", "Another broker operation is in progress.");
    co_return;
  }
  try {
    const auto token_text = BrokerToken(arguments);
    const auto generation_text = ArgumentString(&arguments, "generation");
    const auto path = ArgumentString(&arguments, "path");
    if (token_text.empty() || generation_text.empty() || path.empty()) {
      throw std::invalid_argument("invalid staging request");
    }
    auto root = co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                               winrt::to_hstring(generation_text));
    RelativeSegments(path);
    auto folder = co_await StageFolderAsync(root);
    co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                   winrt::to_hstring(generation_text));
    if (!IsAlive(alive)) co_return;
    const auto key = NewGeneration();
    const auto file = co_await folder.CreateFileAsync(
        winrt::hstring(key + std::wstring(L".part")),
        CreationCollisionOption::FailIfExists);
    if (!co_await IsSafeFileAsync(file)) {
      throw std::runtime_error("staged object is a reparse point");
    }
    co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                   winrt::to_hstring(generation_text));
    if (!IsAlive(alive)) co_return;
    {
      std::lock_guard<std::mutex> lock(g_stage_mutex);
      g_stage_sessions.emplace(winrt::to_string(key),
                               StageSession{winrt::to_hstring(token_text),
                                            winrt::to_hstring(generation_text), file,
                                            0});
    }
    if (IsAlive(alive)) {
      result->Success(EncodableMap{
          {EncodableValue("status"), EncodableValue("ok")},
          {EncodableValue("key"), EncodableValue(winrt::to_string(key))},
          {EncodableValue("length"), EncodableValue(static_cast<int64_t>(0))}});
    }
  } catch (const winrt::hresult_error& error) {
    if (IsAlive(alive)) result->Error("broker_error", winrt::to_string(error.message()));
  } catch (const std::exception& error) {
    if (IsAlive(alive)) result->Error("broker_error", error.what());
  }
}

winrt::fire_and_forget StageWriteAsync(
    flutter::EncodableValue arguments, SharedResult result,
    std::shared_ptr<std::atomic_bool> alive) {
  BusyLease lease;
  if (!lease.acquired()) {
    if (IsAlive(alive)) result->Error("busy", "Another broker operation is in progress.");
    co_return;
  }
  try {
    const auto token_text = BrokerToken(arguments);
    const auto generation_text = ArgumentString(&arguments, "generation");
    const auto key = ArgumentString(&arguments, "key");
    const auto offset = ArgumentInt64(&arguments, "offset", -1);
    const auto bytes = ArgumentBytes(&arguments, "bytes");
    if (token_text.empty() || generation_text.empty() || key.empty() || offset < 0 ||
        bytes.size() > 1024 * 1024) {
      throw std::invalid_argument("invalid staging write request");
    }
    co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                   winrt::to_hstring(generation_text));
    StageSession session;
    {
      std::lock_guard<std::mutex> lock(g_stage_mutex);
      const auto found = g_stage_sessions.find(key);
      if (found == g_stage_sessions.end() || found->second.token != winrt::to_hstring(token_text) ||
          found->second.generation != winrt::to_hstring(generation_text) ||
          found->second.next_offset != static_cast<uint64_t>(offset)) {
        throw std::runtime_error("staging generation or offset changed");
      }
      session = found->second;
    }
    co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                   winrt::to_hstring(generation_text));
    if (!IsAlive(alive)) co_return;
    auto stream = co_await session.file.OpenAsync(FileAccessMode::ReadWrite);
    auto output = stream.GetOutputStreamAt(static_cast<uint64_t>(offset));
    DataWriter writer(output);
    writer.WriteBytes(bytes);
    co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                   winrt::to_hstring(generation_text));
    if (!IsAlive(alive)) co_return;
    co_await writer.StoreAsync();
    co_await writer.FlushAsync();
    writer.Close();
    stream.Close();
    co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                   winrt::to_hstring(generation_text));
    const auto next = offset + static_cast<int64_t>(bytes.size());
    {
      std::lock_guard<std::mutex> lock(g_stage_mutex);
      auto found = g_stage_sessions.find(key);
      if (found != g_stage_sessions.end()) found->second.next_offset = next;
    }
    if (IsAlive(alive)) {
      result->Success(EncodableMap{
          {EncodableValue("status"), EncodableValue("ok")},
          {EncodableValue("nextOffset"), EncodableValue(next)}});
    }
  } catch (const winrt::hresult_error& error) {
    if (IsAlive(alive)) result->Error("broker_error", winrt::to_string(error.message()));
  } catch (const std::exception& error) {
    if (IsAlive(alive)) result->Error("broker_error", error.what());
  }
}

winrt::fire_and_forget StageFinishAsync(
    flutter::EncodableValue arguments, SharedResult result,
    std::shared_ptr<std::atomic_bool> alive) {
  BusyLease lease;
  if (!lease.acquired()) {
    if (IsAlive(alive)) result->Error("busy", "Another broker operation is in progress.");
    co_return;
  }
  try {
    const auto token_text = BrokerToken(arguments);
    const auto generation_text = ArgumentString(&arguments, "generation");
    const auto key = ArgumentString(&arguments, "key");
    const auto expected = ArgumentString(&arguments, "expectedSha256");
    if (token_text.empty() || generation_text.empty() || key.empty() ||
        !IsSha256Text(expected)) {
      throw std::invalid_argument("invalid staging finish request");
    }
    co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                   winrt::to_hstring(generation_text));
    auto root = co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                               winrt::to_hstring(generation_text));
    auto file = co_await StageFileAsync(root, key);
    const auto hash = ParseHashedFile(co_await HashFileAsync(file));
    co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                   winrt::to_hstring(generation_text));
    {
      std::lock_guard<std::mutex> lock(g_stage_mutex);
      g_stage_sessions.erase(key);
    }
    if (hash.sha256 != expected) throw std::runtime_error("staging hash mismatch");
    if (IsAlive(alive)) {
      result->Success(EncodableMap{
          {EncodableValue("status"), EncodableValue("ok")},
          {EncodableValue("key"), EncodableValue(key)},
          {EncodableValue("sha256"), EncodableValue(hash.sha256)},
          {EncodableValue("length"), EncodableValue(static_cast<int64_t>(hash.length))}});
    }
  } catch (const winrt::hresult_error& error) {
    if (IsAlive(alive)) result->Error("broker_error", winrt::to_string(error.message()));
  } catch (const std::exception& error) {
    if (IsAlive(alive)) result->Error("broker_error", error.what());
  }
}

winrt::fire_and_forget OpenStagedChunkAsync(
    flutter::EncodableValue arguments, SharedResult result,
    std::shared_ptr<std::atomic_bool> alive) {
  BusyLease lease;
  if (!lease.acquired()) {
    if (IsAlive(alive)) result->Error("busy", "Another broker operation is in progress.");
    co_return;
  }
  try {
    const auto token_text = BrokerToken(arguments);
    const auto generation_text = ArgumentString(&arguments, "generation");
    const auto key = ArgumentString(&arguments, "key");
    const auto offset = ArgumentInt64(&arguments, "offset", 0);
    const auto max_bytes = ArgumentInt64(&arguments, "maxBytes", 64 * 1024);
    if (token_text.empty() || generation_text.empty() || key.empty() || offset < 0 ||
        max_bytes < 1 || max_bytes > 1024 * 1024) {
      throw std::invalid_argument("invalid staged read request");
    }
    auto root = co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                               winrt::to_hstring(generation_text));
    auto file = co_await StageFileAsync(root, key);
    auto stream = co_await file.OpenAsync(FileAccessMode::Read);
    const auto stream_size = stream.Size();
    if (static_cast<uint64_t>(offset) > stream_size) {
      throw std::runtime_error("staged read offset exceeds file length");
    }
    const auto requested_total = std::min<uint64_t>(
        static_cast<uint64_t>(max_bytes), stream_size - static_cast<uint64_t>(offset));
    DataReader reader(stream.GetInputStreamAt(static_cast<uint64_t>(offset)));
    std::vector<uint8_t> bytes;
    while (bytes.size() < requested_total) {
      const auto requested = static_cast<uint32_t>(
          std::min<uint64_t>(64 * 1024, requested_total - bytes.size()));
      const auto loaded = co_await reader.LoadAsync(requested);
      if (loaded == 0) break;
      std::vector<uint8_t> chunk(loaded);
      reader.ReadBytes(chunk);
      bytes.insert(bytes.end(), chunk.begin(), chunk.end());
    }
    reader.Close();
    stream.Close();
    co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                   winrt::to_hstring(generation_text));
    if (IsAlive(alive)) {
      const auto bytes_read = bytes.size();
      result->Success(EncodableMap{
          {EncodableValue("status"), EncodableValue("ok")},
          {EncodableValue("bytes"), EncodableValue(std::move(bytes))},
          {EncodableValue("offset"), EncodableValue(offset)},
          {EncodableValue("nextOffset"),
           EncodableValue(offset + static_cast<int64_t>(bytes_read))},
          {EncodableValue("eof"),
           EncodableValue(bytes_read < static_cast<size_t>(max_bytes))}});
    }
  } catch (const winrt::hresult_error& error) {
    if (IsAlive(alive)) result->Error("broker_error", winrt::to_string(error.message()));
  } catch (const std::exception& error) {
    if (IsAlive(alive)) result->Error("broker_error", error.what());
  }
}

winrt::fire_and_forget VerifyStagedAsync(
    flutter::EncodableValue arguments, SharedResult result,
    std::shared_ptr<std::atomic_bool> alive) {
  BusyLease lease;
  if (!lease.acquired()) {
    if (IsAlive(alive)) result->Error("busy", "Another broker operation is in progress.");
    co_return;
  }
  try {
    const auto token_text = BrokerToken(arguments);
    const auto generation_text = ArgumentString(&arguments, "generation");
    const auto key = ArgumentString(&arguments, "key");
    const auto expected = ArgumentString(&arguments, "expectedSha256");
    const auto expected_length = ArgumentInt64(&arguments, "expectedLength", -1);
    if (token_text.empty() || generation_text.empty() || key.empty() ||
        !IsSha256Text(expected) ||
        expected_length < 0) {
      throw std::invalid_argument("invalid staged verification request");
    }
    auto root = co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                               winrt::to_hstring(generation_text));
    auto file = co_await StageFileAsync(root, key);
    const auto hash = ParseHashedFile(co_await HashFileAsync(file));
    co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                   winrt::to_hstring(generation_text));
    if (IsAlive(alive)) {
      result->Success(EncodableMap{
          {EncodableValue("status"), EncodableValue("ok")},
          {EncodableValue("valid"), EncodableValue(hash.sha256 == expected &&
                                                     hash.length == static_cast<uint64_t>(expected_length))},
          {EncodableValue("sha256"), EncodableValue(hash.sha256)},
          {EncodableValue("length"), EncodableValue(static_cast<int64_t>(hash.length))}});
    }
  } catch (const winrt::hresult_error& error) {
    if (IsAlive(alive)) result->Error("broker_error", winrt::to_string(error.message()));
  } catch (const std::exception& error) {
    if (IsAlive(alive)) result->Error("broker_error", error.what());
  }
}

winrt::fire_and_forget CommitStagedAsync(
    flutter::EncodableValue arguments, SharedResult result,
    std::shared_ptr<std::atomic_bool> alive) {
  BusyLease lease;
  if (!lease.acquired()) {
    if (IsAlive(alive)) result->Error("busy", "Another broker operation is in progress.");
    co_return;
  }
  try {
    const auto token_text = BrokerToken(arguments);
    const auto generation_text = ArgumentString(&arguments, "generation");
    const auto path = ArgumentString(&arguments, "path");
    const auto key = ArgumentString(&arguments, "key");
    const auto* condition = ArgumentMap(&arguments, "condition");
    const auto* entry = ArgumentMap(&arguments, "entry");
    const auto expected = MapString(entry, "sha256");
    const auto expected_length = MapInt64(entry, "size", -1);
    if (token_text.empty() || generation_text.empty() || path.empty() || key.empty() ||
        condition == nullptr || entry == nullptr || !IsSha256Text(expected) ||
        expected_length < 0) {
      throw std::invalid_argument("invalid staged commit request");
    }
    auto root = co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                               winrt::to_hstring(generation_text));
    auto stage = co_await StageFileAsync(root, key);
    const auto staged_hash = ParseHashedFile(co_await HashFileAsync(stage));
    co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                   winrt::to_hstring(generation_text));
    if (staged_hash.sha256 != expected ||
        staged_hash.length != static_cast<uint64_t>(expected_length)) {
      throw std::runtime_error("staging bytes do not match source metadata");
    }
    const auto condition_type = MapString(condition, "type");
    StorageFile existing{nullptr};
    bool has_existing = false;
    try {
      existing = co_await ResolveFileAsync(root, path);
      has_existing = true;
    } catch (const winrt::hresult_error& error) {
      if (error.code() != HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)) throw;
    }
    if (condition_type == "createOnly") {
      if (has_existing) throw std::runtime_error("local create-only precondition failed");
    } else if (condition_type == "matchSha256") {
      const auto match = MapString(condition, "sha256");
      if (!has_existing || !IsSha256Text(match)) {
        throw std::runtime_error("local hash precondition failed");
      }
      const auto existing_hash = ParseHashedFile(co_await HashFileAsync(existing));
      co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                     winrt::to_hstring(generation_text));
      if (existing_hash.sha256 != match) throw std::runtime_error("local hash precondition failed");
      throw std::runtime_error("atomic conditional replace is unsupported by AppContainer broker");
    } else {
      throw std::invalid_argument("unsupported local condition");
    }
    auto parent = co_await ResolveParentAsync(root, path);
    const auto parts = RelativeSegments(path);
    co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                   winrt::to_hstring(generation_text));
    if (!IsAlive(alive)) co_return;
    auto published = co_await stage.CopyAsync(parent, parts.back(),
                                              NameCollisionOption::FailIfExists);
    if (!co_await IsSafeFileAsync(published)) {
      throw std::runtime_error("published file is a reparse point");
    }
    const auto published_hash = ParseHashedFile(co_await HashFileAsync(published));
    co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                   winrt::to_hstring(generation_text));
    if (published_hash.sha256 != expected ||
        published_hash.length != static_cast<uint64_t>(expected_length)) {
      throw std::runtime_error("published content verification failed; staging retained");
    }
    co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                   winrt::to_hstring(generation_text));
    if (!IsAlive(alive)) co_return;
    try {
      co_await stage.DeleteAsync();
    } catch (...) {
      // An orphaned stage is recoverable evidence after verified publication.
    }
    co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                   winrt::to_hstring(generation_text));
    if (IsAlive(alive)) {
      result->Success(EncodableMap{
          {EncodableValue("status"), EncodableValue("ok")},
          {EncodableValue("path"), EncodableValue(path)},
          {EncodableValue("sha256"), EncodableValue(published_hash.sha256)},
          {EncodableValue("length"), EncodableValue(static_cast<int64_t>(published_hash.length))}});
    }
  } catch (const winrt::hresult_error& error) {
    if (IsAlive(alive)) result->Error("broker_error", winrt::to_string(error.message()));
  } catch (const std::exception& error) {
    if (IsAlive(alive)) result->Error("broker_error", error.what());
  }
}

winrt::fire_and_forget DeleteLocalAsync(
    flutter::EncodableValue arguments, SharedResult result,
    std::shared_ptr<std::atomic_bool> alive) {
  BusyLease lease;
  if (!lease.acquired()) {
    if (IsAlive(alive)) result->Error("busy", "Another broker operation is in progress.");
    co_return;
  }
  try {
    const auto token_text = BrokerToken(arguments);
    const auto generation_text = ArgumentString(&arguments, "generation");
    const auto path = ArgumentString(&arguments, "path");
    const auto* condition = ArgumentMap(&arguments, "condition");
    const auto expected = MapString(condition, "sha256");
    if (token_text.empty() || generation_text.empty() || path.empty() || condition == nullptr ||
         MapString(condition, "type") != "matchSha256" ||
         !IsSha256Text(expected)) {
      throw std::invalid_argument("invalid local delete request");
    }
    auto root = co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                               winrt::to_hstring(generation_text));
    const auto file = co_await ResolveFileAsync(root, path);
    const auto hash = ParseHashedFile(co_await HashFileAsync(file));
    co_await AuthorizedFolderAsync(winrt::to_hstring(token_text),
                                   winrt::to_hstring(generation_text));
    if (hash.sha256 != expected) throw std::runtime_error("local delete precondition failed");
    throw std::runtime_error("atomic conditional delete is unsupported by AppContainer broker");
  } catch (const winrt::hresult_error& error) {
    if (IsAlive(alive)) result->Error("broker_error", winrt::to_string(error.message()));
  } catch (const std::exception& error) {
    if (IsAlive(alive)) result->Error("broker_error", error.what());
  }
}

using ScanItems = std::vector<EncodableValue>;

winrt::Windows::Foundation::IAsyncOperation<bool> IsSafeFolderAsync(
    const StorageFolder& folder) {
  auto properties = co_await folder.Properties().RetrievePropertiesAsync(
      std::vector<winrt::hstring>{L"System.FileAttributes"});
  const auto value = properties.Lookup(L"System.FileAttributes");
  if (value == nullptr) co_return false;
  const auto attributes = winrt::unbox_value<uint32_t>(value);
  co_return (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
}

winrt::Windows::Foundation::IAsyncOperation<bool> IsSafeFileAsync(
    const StorageFile& file) {
  auto properties = co_await file.Properties().RetrievePropertiesAsync(
      std::vector<winrt::hstring>{L"System.FileAttributes"});
  const auto value = properties.Lookup(L"System.FileAttributes");
  if (value == nullptr) co_return false;
  const auto attributes = winrt::unbox_value<uint32_t>(value);
  co_return (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
}

winrt::Windows::Foundation::IAsyncAction EnsureScanGenerationAsync(
    const winrt::hstring& expected_token,
    const winrt::hstring& expected_generation,
    const std::shared_ptr<std::atomic_bool>& alive) {
  if (!IsAlive(alive)) co_return;
  const auto active_record = co_await ReadActiveRootAsync();
  const auto active = ParseActiveRoot(active_record);
  if (!active.has_value() || active->token != expected_token ||
      active->generation != expected_generation) {
    throw std::runtime_error("authorized root generation changed during scan");
  }
}

winrt::Windows::Foundation::IAsyncAction ScanMusicFolderAsync(
    const StorageFolder& folder, const std::wstring& root_path,
    ScanItems& items, bool& complete, size_t depth,
    const winrt::hstring& expected_token,
    const winrt::hstring& expected_generation,
    const std::shared_ptr<std::atomic_bool>& alive) {
  constexpr size_t kMaximumItems = 10000;
  constexpr size_t kMaximumDepth = 64;
  constexpr uint32_t kPageSize = 256;
  if (depth > kMaximumDepth || items.size() >= kMaximumItems) {
    complete = false;
    co_return;
  }
  uint32_t offset = 0;
  while (true) {
    co_await EnsureScanGenerationAsync(expected_token, expected_generation, alive);
    auto children = co_await folder.GetItemsAsync(offset, kPageSize);
    co_await EnsureScanGenerationAsync(expected_token, expected_generation, alive);
    if (children.Size() == 0) co_return;
    for (const auto& item : children) {
      if (!IsAlive(alive)) co_return;
      co_await EnsureScanGenerationAsync(expected_token, expected_generation, alive);
      if (items.size() >= kMaximumItems) {
        complete = false;
        co_return;
      }
      if (item.IsOfType(StorageItemTypes::Folder)) {
        auto child_folder = item.as<StorageFolder>();
        if (_wcsicmp(child_folder.Name().c_str(), L".synctune") == 0 ||
            _wcsicmp(child_folder.Name().c_str(), L".synctune-local") == 0) {
          continue;
        }
        if (!co_await IsSafeFolderAsync(child_folder)) {
          complete = false;
          continue;
        }
        co_await EnsureScanGenerationAsync(expected_token, expected_generation, alive);
        co_await ScanMusicFolderAsync(child_folder, root_path, items, complete,
                                      depth + 1, expected_token,
                                      expected_generation, alive);
        continue;
      }
      if (!item.IsOfType(StorageItemTypes::File)) continue;
      const auto file = item.as<StorageFile>();
      if (!co_await IsSafeFileAsync(file)) {
        complete = false;
        continue;
      }
      co_await EnsureScanGenerationAsync(expected_token, expected_generation, alive);
      const auto file_properties = co_await file.GetBasicPropertiesAsync();
      co_await EnsureScanGenerationAsync(expected_token, expected_generation, alive);
      const auto name = std::wstring(file.Name());
      const auto dot = name.find_last_of(L'.');
      if (dot == std::wstring::npos || dot + 1 >= name.size() ||
          !IsMusicExtension(name.substr(dot + 1))) {
        continue;
      }
      const auto relative = RelativePath(root_path, std::wstring(file.Path()));
      if (!relative.has_value()) {
        complete = false;
        continue;
      }
      auto extension = name.substr(dot + 1);
      std::transform(extension.begin(), extension.end(), extension.begin(),
                     [](wchar_t value) { return std::towlower(value); });
      items.emplace_back(EncodableMap{
          {EncodableValue("relativePath"),
           EncodableValue(winrt::to_string(*relative))},
          {EncodableValue("size"),
           EncodableValue(static_cast<int64_t>(file_properties.Size()))},
          {EncodableValue("extension"),
           EncodableValue(winrt::to_string(extension))}});
    }
    offset += children.Size();
    if (children.Size() < kPageSize) co_return;
  }
}

winrt::fire_and_forget ScanMusicAsync(
    flutter::EncodableValue arguments, SharedResult result,
    std::shared_ptr<std::atomic_bool> alive) {
  try {
    const auto token_text = ArgumentString(&arguments, "token");
    const auto generation_text = ArgumentString(&arguments, "generation");
    if (token_text.empty() || generation_text.empty()) {
      throw std::runtime_error("missing authorized root identity");
    }
    const auto active_record = co_await ReadActiveRootAsync();
    const auto active = ParseActiveRoot(active_record);
    if (!active.has_value() ||
        winrt::to_string(active->token) != token_text ||
        winrt::to_string(active->generation) != generation_text) {
      throw std::runtime_error("authorized root generation changed");
    }
    auto folder = co_await StorageApplicationPermissions::FutureAccessList()
                      .GetFolderAsync(active->token);
    if (_wcsicmp(active->path.c_str(), folder.Path().c_str()) != 0) {
      throw std::runtime_error("authorized root path changed during scan");
    }
    co_await EnsureScanGenerationAsync(active->token, active->generation, alive);
    if (!co_await IsSafeFolderAsync(folder)) {
      throw std::runtime_error("authorized root is a reparse point");
    }
    co_await ReadFolderMetadataAsync(folder);
    co_await EnsureScanGenerationAsync(active->token, active->generation, alive);
    ScanItems items;
    bool complete = true;
    co_await ScanMusicFolderAsync(folder, std::wstring(folder.Path()), items,
                                  complete, 0, active->token,
                                  active->generation, alive);
    const auto after_record = co_await ReadActiveRootAsync();
    const auto after = ParseActiveRoot(after_record);
    if (!after.has_value() || after->token != active->token ||
        after->generation != active->generation) {
      throw std::runtime_error("authorized root generation changed during scan");
    }
    if (!IsAlive(alive)) co_return;
    result->Success(EncodableMap{
        {EncodableValue("status"), EncodableValue("ok")},
        {EncodableValue("generation"),
         EncodableValue(generation_text)},
        {EncodableValue("complete"), EncodableValue(complete)},
        {EncodableValue("items"), EncodableValue(std::move(items))}});
  } catch (const winrt::hresult_error& error) {
    if (IsAlive(alive)) result->Error("winrt_error", winrt::to_string(error.message()));
  } catch (const std::exception& error) {
    if (IsAlive(alive)) result->Error("native_error", error.what());
  }
}

winrt::fire_and_forget PickFolderAsync(
    HWND window,
    SharedResult result,
    std::shared_ptr<std::atomic_bool> alive) {
  BusyLease lease;
  if (!lease.acquired()) {
    if (IsAlive(alive)) result->Error("busy", "Another broker operation is in progress.");
    co_return;
  }
  try {
    FolderPicker picker;
    picker.SuggestedStartLocation(PickerLocationId::DocumentsLibrary);
    picker.FileTypeFilter().Append(L"*");
    picker.as<::IInitializeWithWindow>()->Initialize(window);
    auto folder = co_await picker.PickSingleFolderAsync();
    if (!folder) {
      if (IsAlive(alive)) {
        result->Success(EncodableMap{{EncodableValue("status"),
                                     EncodableValue("cancelled")}});
      }
      co_return;
    }

    // Diagnostics may inspect the selected product root, but may not create a
    // second FutureAccessList entry. This keeps the one-root invariant even
    // when an older settings surface still calls pickFolder.
    const auto active_record = co_await ReadActiveRootAsync();
    const auto active = ParseActiveRoot(active_record);
    if (!active.has_value() ||
        _wcsicmp(active->path.c_str(), folder.Path().c_str()) != 0) {
      throw std::runtime_error("diagnostic picker is limited to the active root");
    }
    const auto token = active->token;
    auto local_folder = ApplicationData::Current().LocalFolder();
    auto reopened = co_await StorageApplicationPermissions::FutureAccessList()
                        .GetFolderAsync(token);
    if (!co_await IsSafeFolderAsync(reopened) ||
        !ReconcileRootAccessList(token)) {
      throw std::runtime_error("active root authorization could not be verified");
    }
    co_await AuthorizedFolderAsync(active->token, active->generation);
    const auto marker_name = NewMarkerName();
    const auto marker_text = MarkerText();
    const auto marker = co_await reopened.CreateFileAsync(
        marker_name, CreationCollisionOption::FailIfExists);
    co_await AuthorizedFolderAsync(active->token, active->generation);
    co_await FileIO::WriteTextAsync(marker, marker_text);
    co_await AuthorizedFolderAsync(active->token, active->generation);
    const auto written_marker_text = co_await FileIO::ReadTextAsync(marker);
    const bool marker_round_trip = written_marker_text == marker_text;
    // This private record only describes files created by this probe. It is
    // replaced in LocalState, never in the user-selected folder.
    const auto record = token + L"\n" + marker_name + L"\n" + marker_text;
    co_await WriteTextAsync(local_folder, kTokenFileName, record);
    co_await AuthorizedFolderAsync(active->token, active->generation);

    if (!IsAlive(alive)) co_return;

    result->Success(EncodableMap{
        {EncodableValue("status"), EncodableValue("ok")},
        {EncodableValue("token"), EncodableValue(winrt::to_string(token))},
        {EncodableValue("reopen"), EncodableValue(
                                      reopened.Path() == folder.Path() ? "ok" : "failed")},
        {EncodableValue("fileIo"), EncodableValue(marker_round_trip ? "ok" : "failed")},
        {EncodableValue("marker"), EncodableValue(winrt::to_string(marker_name))},
        {EncodableValue("markerContent"), EncodableValue(winrt::to_string(marker_text))},
        {EncodableValue("createdPid"),
         EncodableValue(static_cast<int64_t>(GetCurrentProcessId()))},
        {EncodableValue("path"), EncodableValue(winrt::to_string(folder.Path()))}});
  } catch (const winrt::hresult_error& error) {
    if (IsAlive(alive)) result->Error("winrt_error", winrt::to_string(error.message()));
  } catch (const std::exception& error) {
    if (IsAlive(alive)) result->Error("native_error", error.what());
  }
}

winrt::fire_and_forget RestoreFolderAsync(
    SharedResult result,
    std::shared_ptr<std::atomic_bool> alive) {
  BusyLease lease;
  if (!lease.acquired()) {
    if (IsAlive(alive)) result->Error("busy", "Another broker operation is in progress.");
    co_return;
  }
  try {
    const auto record = co_await ReadTokenAsync();
    if (record.empty()) {
      if (IsAlive(alive)) result->Success(EncodableMap{{EncodableValue("status"),
                                   EncodableValue("none")}});
      co_return;
    }

    const auto text = winrt::to_string(record);
    const auto first = text.find('\n');
    const auto second = first == std::string::npos ? std::string::npos
                                                   : text.find('\n', first + 1);
    if (first == std::string::npos || second == std::string::npos) {
      throw std::runtime_error("invalid private folder record");
    }
    const auto token = winrt::to_hstring(text.substr(0, first));
    const auto marker_name = winrt::to_hstring(
        text.substr(first + 1, second - first - 1));
    const auto expected_text = winrt::to_hstring(text.substr(second + 1));

    // A diagnostic record is usable only while it describes the current
    // product root. Never revive an old marker token or retain another FAL
    // entry after a root switch.
    const auto active_record = co_await ReadActiveRootAsync();
    const auto active = ParseActiveRoot(active_record);
    if (!active.has_value() || active->token != token) {
      throw std::runtime_error("diagnostic record is not the active root");
    }
    if (!ReconcileRootAccessList(token)) {
      throw std::runtime_error("active root authorization could not be verified");
    }

    auto folder = co_await AuthorizedFolderAsync(active->token,
                                                 active->generation);
    const auto marker = co_await folder.GetFileAsync(marker_name);
    co_await AuthorizedFolderAsync(active->token, active->generation);
    const auto actual_text = co_await FileIO::ReadTextAsync(marker);
    co_await AuthorizedFolderAsync(active->token, active->generation);
    const bool content_matches = actual_text == expected_text;
    if (!IsAlive(alive)) co_return;
    result->Success(EncodableMap{
        {EncodableValue("status"), EncodableValue(content_matches ? "ok" : "failed")},
        {EncodableValue("path"), EncodableValue(winrt::to_string(folder.Path()))},
        {EncodableValue("fileIo"), EncodableValue(content_matches ? "ok" : "failed")},
        {EncodableValue("marker"), EncodableValue(winrt::to_string(marker_name))},
        {EncodableValue("restoredContent"), EncodableValue(winrt::to_string(actual_text))},
        {EncodableValue("restoredPid"),
         EncodableValue(static_cast<int64_t>(GetCurrentProcessId()))}});
  } catch (const winrt::hresult_error& error) {
    if (IsAlive(alive)) result->Error("winrt_error", winrt::to_string(error.message()));
  } catch (const std::exception& error) {
    if (IsAlive(alive)) result->Error("native_error", error.what());
  }
}

// Product root selection deliberately has no probe marker side effect. The
// caller receives only the opaque FutureAccessList token and display path;
// diagnostics use pickFolder separately so their evidence cannot become
// application data.
winrt::fire_and_forget PickRootAsync(
    HWND window,
    SharedResult result,
    std::shared_ptr<std::atomic_bool> alive) {
  BusyLease lease;
  if (!lease.acquired()) {
    if (IsAlive(alive)) result->Error("busy", "Another broker operation is in progress.");
    co_return;
  }
  try {
    FolderPicker picker;
    picker.SuggestedStartLocation(PickerLocationId::DocumentsLibrary);
    picker.FileTypeFilter().Append(L"*");
    picker.as<::IInitializeWithWindow>()->Initialize(window);
    auto folder = co_await picker.PickSingleFolderAsync();
    if (!folder) {
      if (IsAlive(alive)) {
        result->Success(EncodableMap{{EncodableValue("status"),
                                     EncodableValue("cancelled")}});
      }
      co_return;
    }
    if (!co_await IsSafeFolderAsync(folder)) {
      throw std::runtime_error("selected root is a reparse point");
    }
    const auto token =
        StorageApplicationPermissions::FutureAccessList().Add(folder);
    bool active_saved = false;
    try {
      if (!co_await ValidateFolderAsync(folder)) {
        throw std::runtime_error("selected root is not read/write accessible");
      }
    const auto generation = NewGeneration();
    const winrt::hstring generation_text(generation);
    const auto record = token + winrt::hstring(L"\n") + folder.Path() +
                        winrt::hstring(L"\n") + generation_text;
    auto local_folder = ApplicationData::Current().LocalFolder();
      co_await WriteTextAtomicAsync(local_folder, kActiveRootFileName, record);
    active_saved = true;
    if (!ReconcileRootAccessList(token)) {
      throw std::runtime_error("FutureAccessList still contains an unauthorized root");
    }
    if (!IsAlive(alive)) co_return;
    result->Success(EncodableMap{
        {EncodableValue("status"), EncodableValue("ok")},
        {EncodableValue("token"), EncodableValue(winrt::to_string(token))},
        {EncodableValue("path"),
         EncodableValue(winrt::to_string(folder.Path()))},
        {EncodableValue("generation"),
         EncodableValue(winrt::to_string(generation_text))}});
    } catch (...) {
      if (!active_saved) {
        try {
          StorageApplicationPermissions::FutureAccessList().Remove(token);
        } catch (...) {
        }
      }
      throw;
    }
  } catch (const winrt::hresult_error& error) {
    if (IsAlive(alive)) result->Error("winrt_error", winrt::to_string(error.message()));
  } catch (const std::exception& error) {
    if (IsAlive(alive)) result->Error("native_error", error.what());
  }
}

winrt::fire_and_forget RestoreRootAsync(
    SharedResult result,
    std::shared_ptr<std::atomic_bool> alive) {
  BusyLease lease;
  if (!lease.acquired()) {
    if (IsAlive(alive)) result->Error("busy", "Another broker operation is in progress.");
    co_return;
  }
  try {
    const auto record = co_await ReadActiveRootAsync();
    if (record.empty()) {
      if (IsAlive(alive)) {
        result->Success(EncodableMap{{EncodableValue("status"),
                                     EncodableValue("none")}});
      }
      co_return;
    }
    const auto text = winrt::to_string(record);
    const auto first = text.find('\n');
    const auto second = first == std::string::npos
                            ? std::string::npos
                            : text.find('\n', first + 1);
    if (first == std::string::npos || second == std::string::npos) {
      if (!ReconcileRootAccessList(L"")) {
        throw std::runtime_error("FutureAccessList cleanup could not be verified");
      }
      throw std::runtime_error("invalid active root record");
    }
    const auto token = winrt::to_hstring(text.substr(0, first));
    const auto path = text.substr(first + 1, second - first - 1);
    const auto generation = text.substr(second + 1);
    auto folder = co_await StorageApplicationPermissions::FutureAccessList()
                      .GetFolderAsync(token);
    if (_wcsicmp(winrt::to_hstring(path).c_str(), folder.Path().c_str()) != 0) {
      throw std::runtime_error("authorized root path changed during restore");
    }
    if (!co_await IsSafeFolderAsync(folder)) {
      throw std::runtime_error("authorized root is a reparse point");
    }
    co_await ReadFolderMetadataAsync(folder);
    const auto after_record = co_await ReadActiveRootAsync();
    const auto after = ParseActiveRoot(after_record);
    if (!after.has_value() || after->token != token ||
        after->generation != winrt::to_hstring(generation)) {
      throw std::runtime_error("authorized root generation changed during restore");
    }
    if (!ReconcileRootAccessList(token)) {
      throw std::runtime_error("FutureAccessList still contains an unauthorized root");
    }
    if (!IsAlive(alive)) co_return;
    result->Success(EncodableMap{
        {EncodableValue("status"), EncodableValue("ok")},
        {EncodableValue("token"), EncodableValue(winrt::to_string(token))},
        {EncodableValue("path"), EncodableValue(path)},
        {EncodableValue("generation"), EncodableValue(generation)}});
  } catch (const winrt::hresult_error& error) {
    if (IsAlive(alive)) result->Error("winrt_error", winrt::to_string(error.message()));
  } catch (const std::exception& error) {
    if (IsAlive(alive)) result->Error("native_error", error.what());
  }
}

winrt::fire_and_forget RevokeRootAsync(
    flutter::EncodableValue arguments, SharedResult result,
    std::shared_ptr<std::atomic_bool> alive) {
  BusyLease lease;
  if (!lease.acquired()) {
    if (IsAlive(alive)) result->Error("busy", "Another broker operation is in progress.");
    co_return;
  }
  try {
    const auto token_text = ArgumentString(&arguments, "token");
    const auto generation_text = ArgumentString(&arguments, "generation");
    if (token_text.empty() || generation_text.empty()) {
      throw std::runtime_error("missing authorized root identity");
    }
    const auto record = co_await ReadActiveRootAsync();
    const auto active = ParseActiveRoot(record);
    if (!active.has_value() || winrt::to_string(active->token) != token_text ||
        winrt::to_string(active->generation) != generation_text) {
      if (IsAlive(alive)) {
        result->Success(EncodableMap{
            {EncodableValue("status"), EncodableValue("stale")},
            {EncodableValue("persisted"), EncodableValue("unchanged")},
            {EncodableValue("temporary"), EncodableValue("not_applicable")}});
      }
      co_return;
    }
    // Clear the active record first. All subsequent broker operations fail
    // their generation check even if a provider refuses FAL removal.
    co_await ClearActiveRootAsync();
    {
      std::lock_guard<std::mutex> lock(g_stage_mutex);
      for (auto it = g_stage_sessions.begin(); it != g_stage_sessions.end();) {
        if (it->second.token == winrt::to_hstring(token_text) &&
            it->second.generation == winrt::to_hstring(generation_text)) {
          it = g_stage_sessions.erase(it);
        } else {
          ++it;
        }
      }
    }
    const bool reconciled = ReconcileRootAccessList(L"");
    if (!IsAlive(alive)) co_return;
    result->Success(EncodableMap{
        {EncodableValue("status"),
         EncodableValue(reconciled ? "ok" : "needs_rescan")},
        {EncodableValue("persisted"),
         EncodableValue(reconciled ? "revoked" : "unknown")},
        {EncodableValue("temporary"), EncodableValue("not_applicable")},
        {EncodableValue("generation"), EncodableValue(generation_text)}});
  } catch (const winrt::hresult_error& error) {
    if (IsAlive(alive)) result->Error("revoke_failed", winrt::to_string(error.message()));
  } catch (const std::exception& error) {
    if (IsAlive(alive)) result->Error("revoke_failed", error.what());
  }
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<>> RegisterProbeChannel(
    flutter::FlutterEngine* engine,
    HWND window,
    std::shared_ptr<std::atomic_bool> alive) {
  auto channel = std::make_unique<flutter::MethodChannel<>>(
      engine->messenger(), "synctune/probe",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([window, alive](const auto& call, auto result) {
    try {
      // The broker's storage, FutureAccessList, and PasswordVault operations
      // are authorized only for the packaged AppContainer process. A desktop
      // runner (including an unpackaged debug launch) must fail closed rather
      // than accidentally turning this channel into a broad file broker.
      if (call.method_name() != "processInfo" && !IsAppContainer()) {
        result->Error("appcontainer_required",
                     "This broker requires a packaged AppContainer process.");
        return;
      }
      if (call.method_name() == "credentialRoundTrip") {
        result->Success(CredentialRoundTrip());
      } else if (call.method_name() == "credentialSave") {
        auto arguments = call.arguments() == nullptr
                             ? EncodableValue()
                             : *call.arguments();
        result->Success(CredentialSave(arguments));
      } else if (call.method_name() == "credentialRead") {
        auto arguments = call.arguments() == nullptr
                             ? EncodableValue()
                             : *call.arguments();
        result->Success(CredentialRead(arguments));
      } else if (call.method_name() == "credentialDelete") {
        auto arguments = call.arguments() == nullptr
                             ? EncodableValue()
                             : *call.arguments();
        result->Success(CredentialDelete(arguments));
      } else if (call.method_name() == "brokerCapabilities") {
        result->Success(BrokerCapabilities());
      } else if (call.method_name() == "privateDatabasePath") {
        result->Success(PrivateDatabasePath());
      } else if (call.method_name() == "processInfo") {
        result->Success(ProcessInfo());
      } else if (call.method_name() == "pickFolder") {
        auto shared_result = std::shared_ptr<MethodResult>(result.release());
        PickFolderAsync(window, std::move(shared_result), alive);
      } else if (call.method_name() == "pickRoot") {
        auto shared_result = std::shared_ptr<MethodResult>(result.release());
        PickRootAsync(window, std::move(shared_result), alive);
      } else if (call.method_name() == "restoreRoot") {
        auto shared_result = std::shared_ptr<MethodResult>(result.release());
        RestoreRootAsync(std::move(shared_result), alive);
      } else if (call.method_name() == "revokeRoot") {
        auto shared_result = std::shared_ptr<MethodResult>(result.release());
        auto arguments = call.arguments() == nullptr
                             ? EncodableValue()
                             : *call.arguments();
        RevokeRootAsync(std::move(arguments), std::move(shared_result), alive);
      } else if (call.method_name() == "scanMusic") {
        auto shared_result = std::shared_ptr<MethodResult>(result.release());
        auto arguments = call.arguments() == nullptr
                             ? EncodableValue()
                             : *call.arguments();
        ScanMusicAsync(std::move(arguments), std::move(shared_result), alive);
      } else if (call.method_name() == "localReadChunk") {
        auto shared_result = std::shared_ptr<MethodResult>(result.release());
        auto arguments = call.arguments() == nullptr
                             ? EncodableValue()
                             : *call.arguments();
        ReadChunkAsync(std::move(arguments), std::move(shared_result), alive);
      } else if (call.method_name() == "localStageBegin") {
        auto shared_result = std::shared_ptr<MethodResult>(result.release());
        auto arguments = call.arguments() == nullptr
                             ? EncodableValue()
                             : *call.arguments();
        StageBeginAsync(std::move(arguments), std::move(shared_result), alive);
      } else if (call.method_name() == "localStageWrite") {
        auto shared_result = std::shared_ptr<MethodResult>(result.release());
        auto arguments = call.arguments() == nullptr
                             ? EncodableValue()
                             : *call.arguments();
        StageWriteAsync(std::move(arguments), std::move(shared_result), alive);
      } else if (call.method_name() == "localStageFinish") {
        auto shared_result = std::shared_ptr<MethodResult>(result.release());
        auto arguments = call.arguments() == nullptr
                             ? EncodableValue()
                             : *call.arguments();
        StageFinishAsync(std::move(arguments), std::move(shared_result), alive);
      } else if (call.method_name() == "localOpenStagedChunk") {
        auto shared_result = std::shared_ptr<MethodResult>(result.release());
        auto arguments = call.arguments() == nullptr
                             ? EncodableValue()
                             : *call.arguments();
        OpenStagedChunkAsync(std::move(arguments), std::move(shared_result), alive);
      } else if (call.method_name() == "localVerifyStaged") {
        auto shared_result = std::shared_ptr<MethodResult>(result.release());
        auto arguments = call.arguments() == nullptr
                             ? EncodableValue()
                             : *call.arguments();
        VerifyStagedAsync(std::move(arguments), std::move(shared_result), alive);
      } else if (call.method_name() == "localCommitStaged") {
        auto shared_result = std::shared_ptr<MethodResult>(result.release());
        auto arguments = call.arguments() == nullptr
                             ? EncodableValue()
                             : *call.arguments();
        CommitStagedAsync(std::move(arguments), std::move(shared_result), alive);
      } else if (call.method_name() == "localDelete") {
        auto shared_result = std::shared_ptr<MethodResult>(result.release());
        auto arguments = call.arguments() == nullptr
                             ? EncodableValue()
                             : *call.arguments();
        DeleteLocalAsync(std::move(arguments), std::move(shared_result), alive);
      } else if (call.method_name() == "restoreFolder") {
        auto shared_result = std::shared_ptr<MethodResult>(result.release());
        RestoreFolderAsync(std::move(shared_result), alive);
      } else {
        result->NotImplemented();
      }
    } catch (const winrt::hresult_error& error) {
      result->Error("winrt_error", winrt::to_string(error.message()));
    } catch (const std::exception& error) {
      result->Error("native_error", error.what());
    }
  });
  return channel;
}
