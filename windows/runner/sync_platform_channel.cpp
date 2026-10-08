#include "sync_platform_channel.h"

#include <flutter/standard_method_codec.h>
#include <flutter/method_result_functions.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wincred.h>

#include <filesystem>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                       value.data(), static_cast<int>(value.size()),
                                       nullptr, 0);
  if (size <= 0) throw std::runtime_error("Input is not valid UTF-8.");
  std::wstring output(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), output.data(), size);
  return output;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                       value.data(), static_cast<int>(value.size()),
                                       nullptr, 0, nullptr, nullptr);
  if (size <= 0) throw std::runtime_error("Windows returned an invalid path.");
  std::string output(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), output.data(), size,
                      nullptr, nullptr);
  return output;
}

const EncodableValue* Argument(const EncodableValue* value, const char* key) {
  if (value == nullptr) return nullptr;
  const auto* map = std::get_if<EncodableMap>(value);
  if (map == nullptr) return nullptr;
  const auto it = map->find(EncodableValue(key));
  return it == map->end() ? nullptr : &it->second;
}

std::string StringArgument(const EncodableValue* value, const char* key) {
  const auto* item = Argument(value, key);
  const auto* string = item == nullptr ? nullptr : std::get_if<std::string>(item);
  if (string == nullptr) throw std::runtime_error(std::string("Missing ") + key + ".");
  return *string;
}

EncodableValue FolderSelection(HWND owner) {
  IFileOpenDialog* dialog = nullptr;
  HRESULT status = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                    CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(&dialog));
  if (FAILED(status)) throw std::runtime_error("Could not open the folder picker.");
  const auto release_dialog = [&] { dialog->Release(); };
  FILEOPENDIALOGOPTIONS options{};
  status = dialog->GetOptions(&options);
  if (SUCCEEDED(status)) status = dialog->SetOptions(options | FOS_PICKFOLDERS |
                                                      FOS_FORCEFILESYSTEM |
                                                      FOS_PATHMUSTEXIST);
  if (SUCCEEDED(status)) status = dialog->Show(owner);
  if (status == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    release_dialog();
    return EncodableValue();
  }
  if (FAILED(status)) {
    release_dialog();
    throw std::runtime_error("The folder picker could not complete.");
  }
  IShellItem* item = nullptr;
  status = dialog->GetResult(&item);
  release_dialog();
  if (FAILED(status) || item == nullptr) throw std::runtime_error("No folder was selected.");
  PWSTR path = nullptr;
  status = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
  item->Release();
  if (FAILED(status) || path == nullptr) throw std::runtime_error("The selected folder has no filesystem path.");
  std::wstring wide_path(path);
  CoTaskMemFree(path);
  const auto utf8_path = WideToUtf8(wide_path);
  EncodableMap result;
  result.emplace(EncodableValue("locator"), EncodableValue(utf8_path));
  result.emplace(EncodableValue("stableId"), EncodableValue(utf8_path));
  result.emplace(EncodableValue("generation"), EncodableValue("windows-folder-v2"));
  return EncodableValue(std::move(result));
}

std::wstring CredentialTarget(const std::string& identity) {
  if (identity.size() != 64 || identity.find_first_not_of("0123456789abcdef") != std::string::npos) {
    throw std::runtime_error("The WebDAV credential key is invalid.");
  }
  return L"SyncTune.WebDAV.v2." + Utf8ToWide(identity);
}

EncodableValue ReadCredential(const std::string& identity) {
  PCREDENTIALW credential = nullptr;
  const auto target = CredentialTarget(identity);
  if (!CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
    if (GetLastError() == ERROR_NOT_FOUND) return EncodableValue(std::string());
    throw std::runtime_error("Windows Credential Manager could not read the password.");
  }
  const std::string secret(reinterpret_cast<const char*>(credential->CredentialBlob),
                           credential->CredentialBlobSize);
  CredFree(credential);
  return EncodableValue(secret);
}

bool CredentialExists(const std::string& identity) {
  PCREDENTIALW credential = nullptr;
  const auto target = CredentialTarget(identity);
  if (!CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
    if (GetLastError() == ERROR_NOT_FOUND) return false;
    throw std::runtime_error("Windows Credential Manager could not inspect the saved password.");
  }
  CredFree(credential);
  return true;
}

void WriteCredential(const std::string& identity, const std::string& value) {
  if (value.empty()) throw std::runtime_error("Enter the WebDAV password.");
  if (value.size() > CRED_MAX_CREDENTIAL_BLOB_SIZE) {
    throw std::runtime_error("The password exceeds the Windows secure-store limit.");
  }
  const auto target = CredentialTarget(identity);
  std::string secret = value;
  CREDENTIALW credential{};
  credential.Type = CRED_TYPE_GENERIC;
  credential.TargetName = const_cast<LPWSTR>(target.c_str());
  credential.UserName = const_cast<LPWSTR>(L"SyncTune");
  credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
  credential.CredentialBlobSize = static_cast<DWORD>(secret.size());
  credential.CredentialBlob = reinterpret_cast<LPBYTE>(secret.data());
  const BOOL written = CredWriteW(&credential, 0);
  SecureZeroMemory(secret.data(), secret.size());
  if (!written) throw std::runtime_error("Windows Credential Manager could not save the password.");
}

void DeleteCredential(const std::string& identity) {
  const auto target = CredentialTarget(identity);
  if (!CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0) &&
      GetLastError() != ERROR_NOT_FOUND) {
    throw std::runtime_error("Windows Credential Manager could not remove the saved password.");
  }
}

std::string DatabasePath() {
  PWSTR known_folder = nullptr;
  const HRESULT status = SHGetKnownFolderPath(FOLDERID_LocalAppData,
                                               KF_FLAG_CREATE, nullptr,
                                               &known_folder);
  if (FAILED(status) || known_folder == nullptr) {
    throw std::runtime_error("Windows did not provide the application data folder.");
  }
  std::filesystem::path directory(known_folder);
  CoTaskMemFree(known_folder);
  directory /= L"SyncTune";
  std::error_code error;
  std::filesystem::create_directories(directory, error);
  if (error) throw std::runtime_error("Could not create SyncTune's private data folder.");
  return WideToUtf8((directory / L"synctune-state-v2.sqlite").wstring());
}

bool IsReparsePoint(const std::string& path) {
  const auto wide_path = Utf8ToWide(path);
  const DWORD attributes = GetFileAttributesW(wide_path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES) {
    const DWORD error = GetLastError();
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) return false;
    throw std::runtime_error("Windows could not inspect a selected path.");
  }
  return (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
}

}  // namespace

SyncPlatformChannel::SyncPlatformChannel(flutter::FlutterEngine* engine,
                                         HWND window,
                                         std::function<void()> allow_close)
    : window_(window), allow_close_(std::move(allow_close)) {
  channel_ = std::make_unique<flutter::MethodChannel<>>(
      engine->messenger(), "synctune/sync_platform",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

SyncPlatformChannel::~SyncPlatformChannel() {
  if (channel_) channel_->SetMethodCallHandler(nullptr);
}

void SyncPlatformChannel::RequestWindowClose() {
  if (!channel_) return;
  auto reply = std::make_unique<flutter::MethodResultFunctions<EncodableValue>>(
      [](const EncodableValue*) {},
      [](const std::string&, const std::string&, const EncodableValue*) {},
      [this]() { allow_close_(); });
  channel_->InvokeMethod("windowCloseRequested",
                         std::make_unique<EncodableValue>(), std::move(reply));
}

void SyncPlatformChannel::HandleMethodCall(
    const flutter::MethodCall<>& call,
    std::unique_ptr<flutter::MethodResult<>> result) {
  try {
    if (call.method_name() == "stateDatabasePath") {
      result->Success(EncodableValue(DatabasePath()));
    } else if (call.method_name() == "pickFolder") {
      result->Success(FolderSelection(window_));
    } else if (call.method_name() == "credentialRead") {
      result->Success(ReadCredential(StringArgument(call.arguments(), "identity")));
    } else if (call.method_name() == "credentialExists") {
      result->Success(EncodableValue(CredentialExists(StringArgument(call.arguments(), "identity"))));
    } else if (call.method_name() == "credentialWrite") {
      WriteCredential(StringArgument(call.arguments(), "identity"),
                      StringArgument(call.arguments(), "secret"));
      result->Success(EncodableValue());
    } else if (call.method_name() == "credentialDelete") {
      DeleteCredential(StringArgument(call.arguments(), "identity"));
      result->Success(EncodableValue());
    } else if (call.method_name() == "isReparsePoint") {
      result->Success(EncodableValue(IsReparsePoint(
          StringArgument(call.arguments(), "path"))));
    } else if (call.method_name() == "allowWindowClose") {
      result->Success(EncodableValue());
      allow_close_();
    } else {
      result->NotImplemented();
    }
  } catch (const std::exception& error) {
    result->Error("platform_error", error.what());
  }
}
