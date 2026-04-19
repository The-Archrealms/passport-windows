using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Windows.Security.Cryptography;
using Windows.Security.Credentials;

namespace ArchrealmsPassport.Windows.Services
{
    internal static class PassportDeviceKeyStore
    {
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true,
            PropertyNameCaseInsensitive = true
        };

        public static PassportDeviceKeyMaterial CreatePersistedKey(string deviceId, bool preferWindowsHello)
        {
            if (preferWindowsHello)
            {
                var helloKey = TryCreateWindowsHelloKey(deviceId);
                if (helloKey != null)
                {
                    return helloKey;
                }
            }

            var keyName = "archrealms-passport-" + deviceId + "-" + Guid.NewGuid().ToString("N");
            Exception? lastError = null;

            foreach (var providerCandidate in GetProviderCandidates())
            {
                try
                {
                    using (var key = CreatePersistedKey(providerCandidate.Provider, keyName))
                    using (var rsa = new RSACng(key))
                    {
                        var publicKeyBytes = rsa.ExportSubjectPublicKeyInfo();
                        var keyReference = new PassportDeviceKeyReference
                        {
                            SchemaVersion = 1,
                            ReferenceType = "cng-persisted",
                            KeyName = keyName,
                            Provider = providerCandidate.ProviderName,
                            Algorithm = "RSA",
                            KeySizeBits = key.KeySize,
                            StorageBackend = providerCandidate.StorageBackend
                        };

                        var keyReferencePath = Path.Combine(PassportEnvironment.GetKeysRoot(), deviceId + ".keyref.json");
                        File.WriteAllText(keyReferencePath, JsonSerializer.Serialize(keyReference, JsonOptions));

                        return new PassportDeviceKeyMaterial
                        {
                            PublicKeyBytes = publicKeyBytes,
                            KeyReferencePath = keyReferencePath,
                            StorageBackend = providerCandidate.StorageBackend
                        };
                    }
                }
                catch (Exception ex) when (ex is CryptographicException || ex is PlatformNotSupportedException || ex is UnauthorizedAccessException)
                {
                    lastError = ex;
                    TryDeletePersistedKey(providerCandidate.Provider, keyName);
                }
            }

            throw new CryptographicException("Unable to create a persisted Windows device key.", lastError);
        }

        public static bool IsWindowsHelloSupported()
        {
            try
            {
                return KeyCredentialManager.IsSupportedAsync().AsTask().GetAwaiter().GetResult();
            }
            catch
            {
                return false;
            }
        }

        public static byte[] SignData(string keyReferencePath, byte[] data)
        {
            if (IsLegacyProtectedPkcs8Path(keyReferencePath))
            {
                using (var rsa = LoadLegacyPrivateKey(keyReferencePath))
                {
                    return rsa.SignData(data, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                }
            }

            if (IsWindowsHelloReference(keyReferencePath))
            {
                return SignDataWithWindowsHello(keyReferencePath, data);
            }

            using (var rsa = OpenPersistedKey(keyReferencePath))
            {
                return rsa.SignData(data, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            }
        }

        public static byte[] ExportPublicKey(string keyReferencePath)
        {
            if (IsLegacyProtectedPkcs8Path(keyReferencePath))
            {
                using (var rsa = LoadLegacyPrivateKey(keyReferencePath))
                {
                    return rsa.ExportSubjectPublicKeyInfo();
                }
            }

            if (IsWindowsHelloReference(keyReferencePath))
            {
                return ExportWindowsHelloPublicKey(keyReferencePath);
            }

            using (var rsa = OpenPersistedKey(keyReferencePath))
            {
                return rsa.ExportSubjectPublicKeyInfo();
            }
        }

        public static bool ReferenceExists(string keyReferencePath)
        {
            if (string.IsNullOrWhiteSpace(keyReferencePath) || !File.Exists(keyReferencePath))
            {
                return false;
            }

            if (IsLegacyProtectedPkcs8Path(keyReferencePath))
            {
                return true;
            }

            try
            {
                var keyReference = LoadKeyReference(keyReferencePath);
                if (string.Equals(keyReference.ReferenceType, "windows-hello-keycredential", StringComparison.Ordinal))
                {
                    var openResult = KeyCredentialManager.OpenAsync(keyReference.KeyName).AsTask().GetAwaiter().GetResult();
                    return openResult.Status == KeyCredentialStatus.Success;
                }

                return CngKey.Exists(keyReference.KeyName, new CngProvider(keyReference.Provider));
            }
            catch
            {
                return false;
            }
        }

        public static string DescribeReference(string keyReferencePath)
        {
            if (string.IsNullOrWhiteSpace(keyReferencePath))
            {
                return "missing";
            }

            if (IsLegacyProtectedPkcs8Path(keyReferencePath))
            {
                return "legacy-dpapi-file";
            }

            try
            {
                var keyReference = LoadKeyReference(keyReferencePath);
                return keyReference.StorageBackend + " via " + keyReference.Provider;
            }
            catch
            {
                return "unreadable";
            }
        }

        private static RSACng OpenPersistedKey(string keyReferencePath)
        {
            var keyReference = LoadKeyReference(keyReferencePath);
            var provider = new CngProvider(keyReference.Provider);
            if (!CngKey.Exists(keyReference.KeyName, provider))
            {
                throw new FileNotFoundException("The Windows device key could not be found in the configured provider.", keyReferencePath);
            }

            return new RSACng(CngKey.Open(keyReference.KeyName, provider));
        }

        private static PassportDeviceKeyMaterial? TryCreateWindowsHelloKey(string deviceId)
        {
            try
            {
                if (!KeyCredentialManager.IsSupportedAsync().AsTask().GetAwaiter().GetResult())
                {
                    return null;
                }

                var keyName = "archrealms-passport-" + deviceId;
                var createResult = KeyCredentialManager.RequestCreateAsync(
                    keyName,
                    KeyCredentialCreationOption.ReplaceExisting).AsTask().GetAwaiter().GetResult();

                if (createResult.Status != KeyCredentialStatus.Success || createResult.Credential == null)
                {
                    return null;
                }

                CryptographicBuffer.CopyToByteArray(createResult.Credential.RetrievePublicKey(), out byte[]? publicKeyBytes);
                if (publicKeyBytes == null)
                {
                    return null;
                }
                var keyReference = new PassportDeviceKeyReference
                {
                    SchemaVersion = 1,
                    ReferenceType = "windows-hello-keycredential",
                    KeyName = keyName,
                    Provider = "KeyCredentialManager",
                    Algorithm = "RSA",
                    KeySizeBits = 2048,
                    StorageBackend = "windows-hello"
                };

                var keyReferencePath = Path.Combine(PassportEnvironment.GetKeysRoot(), deviceId + ".keyref.json");
                File.WriteAllText(keyReferencePath, JsonSerializer.Serialize(keyReference, JsonOptions));

                return new PassportDeviceKeyMaterial
                {
                    PublicKeyBytes = publicKeyBytes,
                    KeyReferencePath = keyReferencePath,
                    StorageBackend = "windows-hello"
                };
            }
            catch
            {
                return null;
            }
        }

        private static PassportDeviceKeyReference LoadKeyReference(string keyReferencePath)
        {
            if (string.IsNullOrWhiteSpace(keyReferencePath) || !File.Exists(keyReferencePath))
            {
                throw new FileNotFoundException("The device key reference file could not be found.", keyReferencePath);
            }

            var keyReference = JsonSerializer.Deserialize<PassportDeviceKeyReference>(File.ReadAllText(keyReferencePath), JsonOptions);
            if (keyReference == null)
            {
                throw new InvalidOperationException("The device key reference file could not be parsed.");
            }

            return keyReference;
        }

        private static byte[] SignDataWithWindowsHello(string keyReferencePath, byte[] data)
        {
            var keyReference = LoadKeyReference(keyReferencePath);
            var openResult = KeyCredentialManager.OpenAsync(keyReference.KeyName).AsTask().GetAwaiter().GetResult();
            if (openResult.Status != KeyCredentialStatus.Success || openResult.Credential == null)
            {
                throw new CryptographicException("The Windows Hello credential could not be opened. Status: " + openResult.Status);
            }

            var message = CryptographicBuffer.CreateFromByteArray(data);
            var signResult = openResult.Credential.RequestSignAsync(message).AsTask().GetAwaiter().GetResult();
            if (signResult.Status != KeyCredentialStatus.Success)
            {
                throw new CryptographicException("Windows Hello signing failed. Status: " + signResult.Status);
            }

            CryptographicBuffer.CopyToByteArray(signResult.Result, out byte[]? signatureBytes);
            if (signatureBytes == null)
            {
                throw new CryptographicException("Windows Hello signing returned no signature bytes.");
            }
            return signatureBytes;
        }

        private static byte[] ExportWindowsHelloPublicKey(string keyReferencePath)
        {
            var keyReference = LoadKeyReference(keyReferencePath);
            var openResult = KeyCredentialManager.OpenAsync(keyReference.KeyName).AsTask().GetAwaiter().GetResult();
            if (openResult.Status != KeyCredentialStatus.Success || openResult.Credential == null)
            {
                throw new CryptographicException("The Windows Hello credential could not be opened. Status: " + openResult.Status);
            }

            CryptographicBuffer.CopyToByteArray(openResult.Credential.RetrievePublicKey(), out byte[]? publicKeyBytes);
            if (publicKeyBytes == null)
            {
                throw new CryptographicException("Windows Hello returned no public key bytes.");
            }
            return publicKeyBytes;
        }

        private static CngKey CreatePersistedKey(CngProvider provider, string keyName)
        {
            var creationParameters = new CngKeyCreationParameters
            {
                Provider = provider,
                KeyUsage = CngKeyUsages.Signing,
                ExportPolicy = CngExportPolicies.None
            };

            creationParameters.Parameters.Add(
                new CngProperty(
                    "Length",
                    BitConverter.GetBytes(3072),
                    CngPropertyOptions.None));

            return CngKey.Create(CngAlgorithm.Rsa, keyName, creationParameters);
        }

        private static void TryDeletePersistedKey(CngProvider provider, string keyName)
        {
            try
            {
                if (CngKey.Exists(keyName, provider))
                {
                    using (var key = CngKey.Open(keyName, provider))
                    {
                        key.Delete();
                    }
                }
            }
            catch
            {
            }
        }

        private static RSA LoadLegacyPrivateKey(string privateKeyPath)
        {
            var protectedPrivateKey = File.ReadAllBytes(privateKeyPath);
            var privateKeyBytes = ProtectedData.Unprotect(
                protectedPrivateKey,
                Encoding.UTF8.GetBytes("ArchrealmsPassportWindows"),
                DataProtectionScope.CurrentUser);

            var rsa = RSA.Create();
            rsa.ImportPkcs8PrivateKey(privateKeyBytes, out _);
            return rsa;
        }

        private static bool IsLegacyProtectedPkcs8Path(string keyReferencePath)
        {
            return keyReferencePath.EndsWith(".pkcs8.protected", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsWindowsHelloReference(string keyReferencePath)
        {
            try
            {
                var keyReference = LoadKeyReference(keyReferencePath);
                return string.Equals(keyReference.ReferenceType, "windows-hello-keycredential", StringComparison.Ordinal);
            }
            catch
            {
                return false;
            }
        }

        private static ProviderCandidate[] GetProviderCandidates()
        {
            return new[]
            {
                new ProviderCandidate(new CngProvider("Microsoft Passport Key Storage Provider"), "Microsoft Passport Key Storage Provider", "windows-hello"),
                new ProviderCandidate(new CngProvider("Microsoft Platform Crypto Provider"), "Microsoft Platform Crypto Provider", "tpm-platform"),
                new ProviderCandidate(new CngProvider("Microsoft Software Key Storage Provider"), "Microsoft Software Key Storage Provider", "windows-software-ksp")
            };
        }

        internal sealed class PassportDeviceKeyMaterial
        {
            public byte[] PublicKeyBytes { get; set; } = Array.Empty<byte>();

            public string KeyReferencePath { get; set; } = string.Empty;

            public string StorageBackend { get; set; } = string.Empty;
        }

        private sealed class PassportDeviceKeyReference
        {
            public int SchemaVersion { get; set; }

            public string ReferenceType { get; set; } = string.Empty;

            public string KeyName { get; set; } = string.Empty;

            public string Provider { get; set; } = string.Empty;

            public string Algorithm { get; set; } = string.Empty;

            public int KeySizeBits { get; set; }

            public string StorageBackend { get; set; } = string.Empty;
        }

        private sealed class ProviderCandidate
        {
            public ProviderCandidate(CngProvider provider, string providerName, string storageBackend)
            {
                Provider = provider;
                ProviderName = providerName;
                StorageBackend = storageBackend;
            }

            public CngProvider Provider { get; }

            public string ProviderName { get; }

            public string StorageBackend { get; }
        }
    }
}
