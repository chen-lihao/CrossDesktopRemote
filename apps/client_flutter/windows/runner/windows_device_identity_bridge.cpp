#include "windows_device_identity_bridge.h"

#include <windows.h>
#include <bcrypt.h>
#include <ncrypt.h>
#include <wincrypt.h>

#include <flutter/standard_method_codec.h>

#include <array>
#include <cstring>
#include <cstdint>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr char kChannelName[] =
    "com.crossdesktopremote.cross_desktop_remote/device_identity";
constexpr wchar_t kRootKeyName[] = L"CrossDesktopRemote.DeviceRoot.v1";
constexpr wchar_t kAuthenticationKeyPrefix[] =
    L"CrossDesktopRemote.Authentication.v2.";
constexpr wchar_t kRegistryPath[] = L"Software\\CrossDesktopRemote\\Identity";
constexpr wchar_t kRootFingerprintValue[] = L"RootFingerprintV2";
constexpr wchar_t kAuthenticationKeyIdValue[] = L"AuthenticationKeyIdV2";
constexpr wchar_t kNotBeforeValue[] = L"AuthenticationNotBeforeUnixMs";
constexpr wchar_t kExpiresAtValue[] = L"AuthenticationExpiresAtUnixMs";
constexpr uint64_t kAuthenticationLifetimeMs = 30ULL * 24 * 60 * 60 * 1000;
constexpr uint64_t kRotationWindowMs = 7ULL * 24 * 60 * 60 * 1000;

using EncodableValue = flutter::EncodableValue;
using EncodableMap = flutter::EncodableMap;

class NcryptHandle {
 public:
  NcryptHandle() = default;
  explicit NcryptHandle(NCRYPT_HANDLE value) : value_(value) {}
  ~NcryptHandle() {
    if (value_ != 0) NCryptFreeObject(value_);
  }
  NcryptHandle(const NcryptHandle&) = delete;
  NcryptHandle& operator=(const NcryptHandle&) = delete;
  NcryptHandle(NcryptHandle&& other) noexcept : value_(other.value_) {
    other.value_ = 0;
  }
  NcryptHandle& operator=(NcryptHandle&& other) noexcept {
    if (this != &other) {
      if (value_ != 0) NCryptFreeObject(value_);
      value_ = other.value_;
      other.value_ = 0;
    }
    return *this;
  }
  NCRYPT_HANDLE get() const { return value_; }
  NCRYPT_HANDLE* put() { return &value_; }
  NCRYPT_HANDLE release() {
    const auto value = value_;
    value_ = 0;
    return value;
  }

 private:
  NCRYPT_HANDLE value_ = 0;
};

struct ProtectedKey {
  NcryptHandle provider;
  NcryptHandle key;
  bool hardware_backed = false;
};

void CheckSecurityStatus(SECURITY_STATUS status, const char* operation) {
  if (status != ERROR_SUCCESS) {
    throw std::runtime_error(std::string(operation) + " failed: " +
                             std::to_string(static_cast<unsigned long>(status)));
  }
}

uint64_t NowUnixMilliseconds() {
  FILETIME file_time{};
  GetSystemTimePreciseAsFileTime(&file_time);
  ULARGE_INTEGER value{};
  value.LowPart = file_time.dwLowDateTime;
  value.HighPart = file_time.dwHighDateTime;
  constexpr uint64_t kWindowsToUnixEpoch100ns = 116444736000000000ULL;
  return (value.QuadPart - kWindowsToUnixEpoch100ns) / 10000ULL;
}

bool OpenProvider(const wchar_t* name, NcryptHandle* provider) {
  return NCryptOpenStorageProvider(provider->put(), name, 0) == ERROR_SUCCESS;
}

bool TryOpenKey(const wchar_t* provider_name, const wchar_t* key_name,
                ProtectedKey* output, bool hardware_backed) {
  NcryptHandle provider;
  if (!OpenProvider(provider_name, &provider)) return false;
  NcryptHandle key;
  if (NCryptOpenKey(provider.get(), key.put(), key_name, 0, 0) !=
      ERROR_SUCCESS) {
    return false;
  }
  output->provider = std::move(provider);
  output->key = std::move(key);
  output->hardware_backed = hardware_backed;
  return true;
}

bool TryLoadKey(const wchar_t* key_name, ProtectedKey* output) {
  return TryOpenKey(MS_PLATFORM_CRYPTO_PROVIDER, key_name, output, true) ||
         TryOpenKey(MS_KEY_STORAGE_PROVIDER, key_name, output, false);
}

ProtectedKey LoadRequiredKey(const wchar_t* key_name) {
  ProtectedKey key;
  if (!TryLoadKey(key_name, &key)) {
    throw std::runtime_error("Protected device key is missing");
  }
  return key;
}

ProtectedKey LoadOrCreateKey(const wchar_t* key_name) {
  ProtectedKey key;
  if (TryLoadKey(key_name, &key)) {
    return key;
  }

  for (const auto& candidate :
       std::array<std::pair<const wchar_t*, bool>, 2>{{
           {MS_PLATFORM_CRYPTO_PROVIDER, true},
           {MS_KEY_STORAGE_PROVIDER, false},
       }}) {
    NcryptHandle provider;
    if (!OpenProvider(candidate.first, &provider)) continue;
    NcryptHandle created;
    const auto status = NCryptCreatePersistedKey(
        provider.get(), created.put(), NCRYPT_ECDSA_P256_ALGORITHM, key_name, 0,
        0);
    if (status != ERROR_SUCCESS) continue;
    if (NCryptFinalizeKey(created.get(), 0) != ERROR_SUCCESS) continue;
    key.provider = std::move(provider);
    key.key = std::move(created);
    key.hardware_backed = candidate.second;
    return key;
  }
  throw std::runtime_error("Unable to create a Windows protected P-256 key");
}

std::vector<uint8_t> ExportPublicKey(NCRYPT_KEY_HANDLE key) {
  DWORD size = 0;
  CheckSecurityStatus(
      NCryptExportKey(key, 0, BCRYPT_ECCPUBLIC_BLOB, nullptr, nullptr, 0, &size,
                      0),
      "NCryptExportKey(size)");
  std::vector<uint8_t> blob(size);
  CheckSecurityStatus(NCryptExportKey(key, 0, BCRYPT_ECCPUBLIC_BLOB, nullptr,
                                     blob.data(), size, &size, 0),
                      "NCryptExportKey");
  if (blob.size() < sizeof(BCRYPT_ECCKEY_BLOB)) {
    throw std::runtime_error("Invalid Windows ECC public key blob");
  }
  const auto* header =
      reinterpret_cast<const BCRYPT_ECCKEY_BLOB*>(blob.data());
  if (header->cbKey != 32 ||
      blob.size() != sizeof(BCRYPT_ECCKEY_BLOB) + 2ULL * header->cbKey) {
    throw std::runtime_error("Unexpected Windows P-256 public key size");
  }
  std::vector<uint8_t> sec1(65);
  sec1[0] = 0x04;
  memcpy(sec1.data() + 1, blob.data() + sizeof(BCRYPT_ECCKEY_BLOB), 64);
  return sec1;
}

std::vector<uint8_t> Sha256(const std::vector<uint8_t>& input) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr,
                                  0) != 0) {
    throw std::runtime_error("Unable to open SHA-256 provider");
  }
  std::array<uint8_t, 32> digest{};
  const auto status = BCryptHash(algorithm, nullptr, 0,
                                 const_cast<PUCHAR>(input.data()),
                                 static_cast<ULONG>(input.size()),
                                 digest.data(),
                                 static_cast<ULONG>(digest.size()));
  BCryptCloseAlgorithmProvider(algorithm, 0);
  if (status != 0) throw std::runtime_error("Unable to calculate SHA-256");
  return {digest.begin(), digest.end()};
}

std::vector<uint8_t> DerEncodeSignature(const std::vector<uint8_t>& raw) {
  if (raw.size() != 64) throw std::runtime_error("Invalid ECDSA signature");
  const auto integer = [](const uint8_t* value) {
    size_t first = 0;
    while (first < 31 && value[first] == 0) ++first;
    const bool needs_zero = (value[first] & 0x80) != 0;
    std::vector<uint8_t> output;
    output.reserve(35);
    output.push_back(0x02);
    output.push_back(static_cast<uint8_t>(32 - first + (needs_zero ? 1 : 0)));
    if (needs_zero) output.push_back(0);
    output.insert(output.end(), value + first, value + 32);
    return output;
  };
  const auto r = integer(raw.data());
  const auto s = integer(raw.data() + 32);
  std::vector<uint8_t> der;
  der.reserve(2 + r.size() + s.size());
  der.push_back(0x30);
  der.push_back(static_cast<uint8_t>(r.size() + s.size()));
  der.insert(der.end(), r.begin(), r.end());
  der.insert(der.end(), s.begin(), s.end());
  return der;
}

std::vector<uint8_t> DerDecodeSignature(const std::vector<uint8_t>& der) {
  if (der.size() < 8 || der[0] != 0x30 || der[1] != der.size() - 2) {
    throw std::runtime_error("Invalid DER ECDSA signature");
  }
  size_t offset = 2;
  std::vector<uint8_t> raw(64);
  for (size_t component = 0; component < 2; ++component) {
    if (offset + 2 > der.size() || der[offset++] != 0x02) {
      throw std::runtime_error("Invalid DER ECDSA integer");
    }
    const size_t length = der[offset++];
    if (length == 0 || offset + length > der.size()) {
      throw std::runtime_error("Invalid DER ECDSA length");
    }
    size_t start = offset;
    size_t value_length = length;
    if ((der[start] & 0x80) != 0) {
      throw std::runtime_error("Negative DER ECDSA integer");
    }
    if (value_length == 33 && der[start] == 0) {
      if ((der[start + 1] & 0x80) == 0) {
        throw std::runtime_error("Non-minimal DER ECDSA integer");
      }
      ++start;
      --value_length;
    } else if (value_length > 1 && der[start] == 0) {
      throw std::runtime_error("Non-minimal DER ECDSA integer");
    }
    if (value_length > 32) throw std::runtime_error("Oversized ECDSA integer");
    memcpy(raw.data() + component * 32 + (32 - value_length),
           der.data() + start, value_length);
    offset += length;
  }
  if (offset != der.size()) throw std::runtime_error("Trailing DER data");
  return raw;
}

std::vector<uint8_t> Sign(NCRYPT_KEY_HANDLE key,
                          const std::vector<uint8_t>& message) {
  const auto hash = Sha256(message);
  DWORD size = 0;
  CheckSecurityStatus(NCryptSignHash(key, nullptr,
                                    const_cast<PBYTE>(hash.data()),
                                    static_cast<DWORD>(hash.size()), nullptr, 0,
                                    &size, 0),
                      "NCryptSignHash(size)");
  std::vector<uint8_t> raw(size);
  CheckSecurityStatus(NCryptSignHash(
                          key, nullptr, const_cast<PBYTE>(hash.data()),
                          static_cast<DWORD>(hash.size()), raw.data(), size,
                          &size, 0),
                      "NCryptSignHash");
  raw.resize(size);
  return DerEncodeSignature(raw);
}

std::string Base64Encode(const std::vector<uint8_t>& value) {
  DWORD size = 0;
  if (!CryptBinaryToStringA(value.data(), static_cast<DWORD>(value.size()),
                            CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, nullptr,
                            &size)) {
    throw std::runtime_error("Unable to size Base64 value");
  }
  std::string output(size, '\0');
  if (!CryptBinaryToStringA(value.data(), static_cast<DWORD>(value.size()),
                            CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF,
                            output.data(), &size)) {
    throw std::runtime_error("Unable to encode Base64 value");
  }
  if (!output.empty() && output.back() == '\0') output.pop_back();
  return output;
}

std::vector<uint8_t> Base64Decode(const std::string& value) {
  DWORD size = 0;
  if (!CryptStringToBinaryA(value.c_str(), static_cast<DWORD>(value.size()),
                            CRYPT_STRING_BASE64, nullptr, &size, nullptr,
                            nullptr)) {
    throw std::runtime_error("Invalid Base64 value");
  }
  std::vector<uint8_t> output(size);
  if (!CryptStringToBinaryA(value.c_str(), static_cast<DWORD>(value.size()),
                            CRYPT_STRING_BASE64, output.data(), &size, nullptr,
                            nullptr)) {
    throw std::runtime_error("Unable to decode Base64 value");
  }
  output.resize(size);
  return output;
}

void AppendUint32(std::vector<uint8_t>* output, uint32_t value) {
  output->push_back(static_cast<uint8_t>(value >> 24));
  output->push_back(static_cast<uint8_t>(value >> 16));
  output->push_back(static_cast<uint8_t>(value >> 8));
  output->push_back(static_cast<uint8_t>(value));
}

void AppendUint64(std::vector<uint8_t>* output, uint64_t value) {
  for (int shift = 56; shift >= 0; shift -= 8) {
    output->push_back(static_cast<uint8_t>(value >> shift));
  }
}

void AppendLengthPrefixed(std::vector<uint8_t>* output,
                          const std::vector<uint8_t>& value) {
  AppendUint32(output, static_cast<uint32_t>(value.size()));
  output->insert(output->end(), value.begin(), value.end());
}

std::vector<uint8_t> AuthenticationCertificateBody(
    const std::vector<uint8_t>& fingerprint,
    const std::vector<uint8_t>& authentication_public_key,
    uint64_t not_before, uint64_t expires_at) {
  const std::string domain = "CrossDesktopRemote/AuthKeyCertificate/v1";
  std::vector<uint8_t> output;
  AppendLengthPrefixed(
      &output, std::vector<uint8_t>(domain.begin(), domain.end()));
  AppendLengthPrefixed(&output, fingerprint);
  AppendLengthPrefixed(&output, authentication_public_key);
  AppendUint64(&output, not_before);
  AppendUint64(&output, expires_at);
  return output;
}

uint64_t ReadRegistryUint64(const wchar_t* name) {
  DWORD type = 0;
  uint64_t value = 0;
  DWORD size = sizeof(value);
  if (RegGetValueW(HKEY_CURRENT_USER, kRegistryPath, name, RRF_RT_REG_QWORD,
                   &type, &value, &size) != ERROR_SUCCESS) {
    return 0;
  }
  return value;
}

std::wstring ReadRegistryString(const wchar_t* name) {
  DWORD type = 0;
  DWORD size = 0;
  if (RegGetValueW(HKEY_CURRENT_USER, kRegistryPath, name, RRF_RT_REG_SZ,
                   &type, nullptr, &size) != ERROR_SUCCESS ||
      size < sizeof(wchar_t)) {
    return {};
  }
  std::wstring value(size / sizeof(wchar_t), L'\0');
  if (RegGetValueW(HKEY_CURRENT_USER, kRegistryPath, name, RRF_RT_REG_SZ,
                   &type, value.data(), &size) != ERROR_SUCCESS) {
    return {};
  }
  while (!value.empty() && value.back() == L'\0') value.pop_back();
  return value;
}

HKEY OpenIdentityRegistryForWrite() {
  HKEY key = nullptr;
  const auto status = RegCreateKeyExW(
      HKEY_CURRENT_USER, kRegistryPath, 0, nullptr, REG_OPTION_NON_VOLATILE,
      KEY_SET_VALUE, nullptr, &key, nullptr);
  if (status != ERROR_SUCCESS) {
    throw std::runtime_error("Unable to open device identity metadata");
  }
  return key;
}

void WriteRegistryUint64(const wchar_t* name, uint64_t value) {
  const auto key = OpenIdentityRegistryForWrite();
  const auto status = RegSetValueExW(
      key, name, 0, REG_QWORD, reinterpret_cast<const BYTE*>(&value),
      static_cast<DWORD>(sizeof(value)));
  RegCloseKey(key);
  if (status != ERROR_SUCCESS) {
    throw std::runtime_error("Unable to persist authentication key lifetime");
  }
}

void WriteRegistryString(const wchar_t* name, const std::wstring& value) {
  const auto key = OpenIdentityRegistryForWrite();
  const size_t byte_size = (value.size() + 1) * sizeof(wchar_t);
  if (byte_size > std::numeric_limits<DWORD>::max()) {
    RegCloseKey(key);
    throw std::runtime_error("Device identity metadata is too large");
  }
  const auto status = RegSetValueExW(
      key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()),
      static_cast<DWORD>(byte_size));
  RegCloseKey(key);
  if (status != ERROR_SUCCESS) {
    throw std::runtime_error("Unable to persist device identity metadata");
  }
}

std::wstring HexWide(const std::vector<uint8_t>& value) {
  constexpr wchar_t kHex[] = L"0123456789abcdef";
  std::wstring output;
  output.reserve(value.size() * 2);
  for (const auto byte : value) {
    output.push_back(kHex[byte >> 4]);
    output.push_back(kHex[byte & 0x0f]);
  }
  return output;
}

std::wstring NewAuthenticationKeyId() {
  std::array<uint8_t, 16> random{};
  CheckSecurityStatus(
      BCryptGenRandom(nullptr, random.data(),
                      static_cast<ULONG>(random.size()),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG),
      "BCryptGenRandom");
  return HexWide(std::vector<uint8_t>(random.begin(), random.end()));
}

std::wstring AuthenticationKeyName(const std::wstring& key_id) {
  if (key_id.empty() || key_id.size() > 64) {
    throw std::runtime_error("Invalid authentication key identifier");
  }
  return std::wstring(kAuthenticationKeyPrefix) + key_id;
}

EncodableMap BuildIdentity(bool force_rotation) {
  const auto bound_fingerprint = ReadRegistryString(kRootFingerprintValue);
  auto root = bound_fingerprint.empty() ? LoadOrCreateKey(kRootKeyName)
                                        : LoadRequiredKey(kRootKeyName);
  const auto root_public = ExportPublicKey(root.key.get());
  const auto fingerprint = Sha256(root_public);
  const auto encoded_fingerprint = HexWide(fingerprint);
  if (!bound_fingerprint.empty() && bound_fingerprint != encoded_fingerprint) {
    throw std::runtime_error(
        "Protected root identity no longer matches this installation");
  }
  if (bound_fingerprint.empty()) {
    WriteRegistryString(kRootFingerprintValue, encoded_fingerprint);
  }
  const uint64_t now = NowUnixMilliseconds();
  auto authentication_key_id = ReadRegistryString(kAuthenticationKeyIdValue);
  uint64_t not_before = ReadRegistryUint64(kNotBeforeValue);
  uint64_t expires_at = ReadRegistryUint64(kExpiresAtValue);
  ProtectedKey authentication;
  if (!authentication_key_id.empty()) {
    const auto existing_key_name = AuthenticationKeyName(authentication_key_id);
    TryLoadKey(existing_key_name.c_str(), &authentication);
  }
  if (force_rotation || authentication_key_id.empty() || not_before == 0 ||
      expires_at <= now + kRotationWindowMs || authentication.key.get() == 0) {
    authentication_key_id = NewAuthenticationKeyId();
    const auto next_key_name = AuthenticationKeyName(authentication_key_id);
    authentication = LoadOrCreateKey(next_key_name.c_str());
    not_before = now;
    expires_at = now + kAuthenticationLifetimeMs;
    // Publish the new key identifier only after key creation succeeds. The
    // previous persisted key remains available for in-flight signatures.
    WriteRegistryString(kAuthenticationKeyIdValue, authentication_key_id);
    WriteRegistryUint64(kNotBeforeValue, not_before);
    WriteRegistryUint64(kExpiresAtValue, expires_at);
  }
  const auto authentication_key_name =
      AuthenticationKeyName(authentication_key_id);
  if (authentication.key.get() == 0) {
    authentication = LoadRequiredKey(authentication_key_name.c_str());
  }
  const auto authentication_public = ExportPublicKey(authentication.key.get());
  const auto certificate = Sign(
      root.key.get(), AuthenticationCertificateBody(
                          fingerprint, authentication_public, not_before,
                          expires_at));

  EncodableMap value;
  value[EncodableValue("rootKeyHandle")] =
      EncodableValue("windows-cng:root:v1");
  value[EncodableValue("rootPublicKey")] =
      EncodableValue(Base64Encode(root_public));
  value[EncodableValue("authenticationKeyHandle")] =
      EncodableValue("windows-cng:authentication:v2");
  value[EncodableValue("authenticationPublicKey")] =
      EncodableValue(Base64Encode(authentication_public));
  value[EncodableValue("authenticationNotBeforeUnixMs")] =
      EncodableValue(static_cast<int64_t>(not_before));
  value[EncodableValue("authenticationExpiresAtUnixMs")] =
      EncodableValue(static_cast<int64_t>(expires_at));
  value[EncodableValue("authenticationCertificate")] =
      EncodableValue(Base64Encode(certificate));
  value[EncodableValue("hardwareBacked")] =
      EncodableValue(root.hardware_backed && authentication.hardware_backed);
  return value;
}

const EncodableMap& Arguments(const flutter::MethodCall<EncodableValue>& call) {
  const auto* arguments = std::get_if<EncodableMap>(call.arguments());
  if (arguments == nullptr) throw std::runtime_error("Expected argument map");
  return *arguments;
}

std::string StringArgument(const EncodableMap& arguments, const char* name) {
  const auto entry = arguments.find(EncodableValue(name));
  if (entry == arguments.end()) throw std::runtime_error("Missing argument");
  const auto* value = std::get_if<std::string>(&entry->second);
  if (value == nullptr) throw std::runtime_error("Invalid string argument");
  return *value;
}

bool Verify(const std::vector<uint8_t>& public_key,
            const std::vector<uint8_t>& message,
            const std::vector<uint8_t>& signature_der) {
  if (public_key.size() != 65 || public_key[0] != 0x04) return false;
  std::vector<uint8_t> raw;
  try {
    raw = DerDecodeSignature(signature_der);
  } catch (const std::exception&) {
    return false;
  }
  const auto hash = Sha256(message);
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_KEY_HANDLE key = nullptr;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_ECDSA_P256_ALGORITHM,
                                  nullptr, 0) != 0) {
    return false;
  }
  BCRYPT_ECCKEY_BLOB header{};
  header.dwMagic = BCRYPT_ECDSA_PUBLIC_P256_MAGIC;
  header.cbKey = 32;
  std::vector<uint8_t> blob(sizeof(header) + 64);
  memcpy(blob.data(), &header, sizeof(header));
  memcpy(blob.data() + sizeof(header), public_key.data() + 1, 64);
  auto status = BCryptImportKeyPair(
      algorithm, nullptr, BCRYPT_ECCPUBLIC_BLOB, &key, blob.data(),
      static_cast<ULONG>(blob.size()), 0);
  if (status == 0) {
    status = BCryptVerifySignature(
        key, nullptr, const_cast<PUCHAR>(hash.data()),
        static_cast<ULONG>(hash.size()), const_cast<PUCHAR>(raw.data()),
        static_cast<ULONG>(raw.size()), 0);
  }
  if (key != nullptr) BCryptDestroyKey(key);
  BCryptCloseAlgorithmProvider(algorithm, 0);
  return status == 0;
}

}  // namespace

WindowsDeviceIdentityBridge::WindowsDeviceIdentityBridge(
    flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        try {
          if (call.method_name() == "loadOrCreateIdentity") {
            result->Success(EncodableValue(BuildIdentity(false)));
            return;
          }
          if (call.method_name() == "rotateAuthenticationKey") {
            result->Success(EncodableValue(BuildIdentity(true)));
            return;
          }
          const auto& arguments = Arguments(call);
          if (call.method_name() == "signWithRoot" ||
              call.method_name() == "signWithAuthenticationKey") {
            const auto message =
                Base64Decode(StringArgument(arguments, "message"));
            std::wstring key_name = kRootKeyName;
            if (call.method_name() == "signWithAuthenticationKey") {
              key_name = AuthenticationKeyName(
                  ReadRegistryString(kAuthenticationKeyIdValue));
            }
            auto key = LoadRequiredKey(key_name.c_str());
            result->Success(
                EncodableValue(Base64Encode(Sign(key.key.get(), message))));
            return;
          }
          if (call.method_name() == "verifyP256Signature") {
            result->Success(EncodableValue(Verify(
                Base64Decode(StringArgument(arguments, "publicKey")),
                Base64Decode(StringArgument(arguments, "message")),
                Base64Decode(StringArgument(arguments, "signature")))));
            return;
          }
          result->NotImplemented();
        } catch (const std::exception& error) {
          result->Error("device_identity_failed", error.what());
        }
      });
}

WindowsDeviceIdentityBridge::~WindowsDeviceIdentityBridge() = default;
