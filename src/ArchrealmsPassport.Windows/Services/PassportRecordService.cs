using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ArchrealmsPassport.Windows.Models;

namespace ArchrealmsPassport.Windows.Services
{
    public sealed class PassportRecordService
    {
        private static readonly JsonSerializerOptions JsonOptions = new JsonSerializerOptions
        {
            WriteIndented = true
        };

        public PassportProvisioningResult CreateNewIdentity(
            string workspaceRoot,
            string displayName,
            string identityMode,
            string deviceLabel,
            bool preferWindowsHello)
        {
            var identityId = CreateIdentityId(displayName);

            try
            {
                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var normalizedDisplayName = NormalizeDisplayName(displayName, identityMode, identityId);
                var normalizedDeviceLabel = NormalizeDeviceLabel(deviceLabel);
                EnsureRegistryFolders(resolvedWorkspaceRoot);

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var deviceId = CreateDeviceId(normalizedDeviceLabel);
                var deviceKeyPair = PassportDeviceKeyStore.CreatePersistedKey(deviceId, preferWindowsHello);
                var publicKeyPath = WritePublicKey(resolvedWorkspaceRoot, deviceId, deviceKeyPair.PublicKeyBytes);

                var identityRecordPath = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "registry",
                    "identities",
                    timestamp + "-" + identityId + ".json");

                var identityRecord = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_identity_record",
                    ["record_id"] = timestamp + "-" + identityId,
                    ["created_utc"] = createdUtc,
                    ["effective_utc"] = createdUtc,
                    ["status"] = "active",
                    ["archrealms_identity_id"] = identityId,
                    ["display_name"] = normalizedDisplayName,
                    ["identity_mode"] = identityMode,
                    ["citizenship_class"] = "citizen",
                    ["declared_scope"] = "personal",
                    ["public_biography"] = string.Empty,
                    ["recovery_authority"] = new Dictionary<string, object?>
                    {
                        ["method"] = "device-recovery-to-be-defined",
                        ["reference"] = deviceId
                    },
                    ["attestation_refs"] = Array.Empty<string>(),
                    ["supersedes_record_id"] = string.Empty,
                    ["summary"] = "Passport identity established through Windows Passport onboarding."
                };

                File.WriteAllText(identityRecordPath, JsonSerializer.Serialize(identityRecord, JsonOptions));

                var deviceRecordPath = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "registry",
                    "device-credentials",
                    timestamp + "-" + deviceId + ".json");

                var deviceRecord = CreateDeviceCredentialRecord(
                    resolvedWorkspaceRoot,
                    timestamp,
                    createdUtc,
                    identityId,
                    deviceId,
                    normalizedDeviceLabel,
                    publicKeyPath,
                    deviceKeyPair.PublicKeyBytes,
                    "active",
                    "genesis",
                    string.Empty,
                    string.Empty,
                    string.Empty);

                File.WriteAllText(deviceRecordPath, JsonSerializer.Serialize(deviceRecord, JsonOptions));

                return new PassportProvisioningResult
                {
                    Succeeded = true,
                    Message = "Created a new Passport identity and authorized this device.",
                    IdentityId = identityId,
                    DeviceId = deviceId,
                    PrivateKeyPath = deviceKeyPair.KeyReferencePath,
                    PublicKeyPath = publicKeyPath,
                    IdentityRecordPath = identityRecordPath,
                    DeviceRecordPath = deviceRecordPath
                };
            }
            catch (Exception ex)
            {
                return FailedProvisioning("Passport provisioning failed: " + ex.Message);
            }
        }

        public PassportJoinRequestResult CreateJoinRequest(
            string workspaceRoot,
            string identityId,
            string deviceLabel,
            bool preferWindowsHello)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(identityId))
                {
                    return FailedJoinRequest("An existing Passport ID is required.");
                }

                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var normalizedDeviceLabel = NormalizeDeviceLabel(deviceLabel);
                EnsureRegistryFolders(resolvedWorkspaceRoot);

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var deviceId = CreateDeviceId(normalizedDeviceLabel);
                var deviceKeyPair = PassportDeviceKeyStore.CreatePersistedKey(deviceId, preferWindowsHello);
                var publicKeyPath = WritePublicKey(resolvedWorkspaceRoot, deviceId, deviceKeyPair.PublicKeyBytes);

                var pendingRecordPath = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "registry",
                    "device-credentials",
                    timestamp + "-" + deviceId + ".pending.json");

                var pendingRecord = CreateDeviceCredentialRecord(
                    resolvedWorkspaceRoot,
                    timestamp,
                    createdUtc,
                    identityId,
                    deviceId,
                    normalizedDeviceLabel,
                    publicKeyPath,
                    deviceKeyPair.PublicKeyBytes,
                    "pending_authorization",
                    "pending",
                    string.Empty,
                    string.Empty,
                    string.Empty);

                File.WriteAllText(pendingRecordPath, JsonSerializer.Serialize(pendingRecord, JsonOptions));

                var joinRequestRoot = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "registry",
                    "join-requests",
                    timestamp + "-" + identityId + "-" + deviceId);
                Directory.CreateDirectory(joinRequestRoot);

                var packagedPublicKeyPath = Path.Combine(joinRequestRoot, "candidate-device-public-key.spki.der");
                File.WriteAllBytes(packagedPublicKeyPath, deviceKeyPair.PublicKeyBytes);

                var requestPath = Path.Combine(joinRequestRoot, "device-join-request.json");
                var requestRecord = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "device_join_request",
                    ["record_id"] = timestamp + "-" + deviceId,
                    ["created_utc"] = createdUtc,
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["device_label"] = normalizedDeviceLabel,
                    ["client_platform"] = "windows",
                    ["public_key_path"] = "candidate-device-public-key.spki.der",
                    ["public_key_sha256"] = ComputeSha256(deviceKeyPair.PublicKeyBytes),
                    ["requested_scopes"] = new[]
                    {
                        "authenticate",
                        "submit_registry_record",
                        "publish_archive"
                    },
                    ["summary"] = "Join request generated by a new Passport device seeking approval from an existing authorized device."
                };

                File.WriteAllText(requestPath, JsonSerializer.Serialize(requestRecord, JsonOptions));

                var requestBytes = File.ReadAllBytes(requestPath);
                byte[] signatureBytes;
                signatureBytes = PassportDeviceKeyStore.SignData(deviceKeyPair.KeyReferencePath, requestBytes);

                bool verified;
                using (var rsa = RSA.Create())
                {
                    rsa.ImportSubjectPublicKeyInfo(deviceKeyPair.PublicKeyBytes, out _);
                    verified = rsa.VerifyData(requestBytes, signatureBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                }

                var signaturePath = Path.Combine(joinRequestRoot, "device-join-request-signature.json");
                var signatureRecord = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "device_join_request_signature",
                    ["record_id"] = timestamp + "-" + deviceId + "-signature",
                    ["created_utc"] = createdUtc,
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["request_sha256"] = ComputeSha256(requestBytes),
                    ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                    ["signature_base64"] = Convert.ToBase64String(signatureBytes),
                    ["public_key_path"] = "candidate-device-public-key.spki.der",
                    ["verified_with_public_key"] = verified,
                    ["summary"] = "Join request signed by the candidate device key."
                };

                File.WriteAllText(signaturePath, JsonSerializer.Serialize(signatureRecord, JsonOptions));

                return new PassportJoinRequestResult
                {
                    Succeeded = true,
                    Message = "Prepared a join request for approval by an existing authorized device.",
                    IdentityId = identityId,
                    DeviceId = deviceId,
                    PrivateKeyPath = deviceKeyPair.KeyReferencePath,
                    PublicKeyPath = publicKeyPath,
                    PendingDeviceRecordPath = pendingRecordPath,
                    JoinRequestPath = requestPath,
                    RequestSignaturePath = signaturePath
                };
            }
            catch (Exception ex)
            {
                return FailedJoinRequest("Join request generation failed: " + ex.Message);
            }
        }

        public PassportMeteringRecordResult CreateNodeCapacitySnapshot(
            string workspaceRoot,
            string identityId,
            string deviceId,
            string deviceKeyReferencePath,
            string nodeId,
            double storageAllocationGb,
            string nodeParticipationMode,
            string nodeCachePolicy,
            int storageGcWatermark,
            string provideStrategy,
            bool preferWifiOnly,
            string ipfsRepoPath)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(identityId))
                {
                    return FailedMeteringRecord("An active Passport identity is required before recording node capacity.");
                }

                if (string.IsNullOrWhiteSpace(deviceId) || string.IsNullOrWhiteSpace(deviceKeyReferencePath))
                {
                    return FailedMeteringRecord("An active Passport device credential is required before recording node capacity.");
                }

                if (!PassportDeviceKeyStore.ReferenceExists(deviceKeyReferencePath))
                {
                    return FailedMeteringRecord("The active Passport device key reference is not available.");
                }

                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                EnsureRegistryFolders(resolvedWorkspaceRoot);
                EnsureMeteringFolders(resolvedWorkspaceRoot);

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var normalizedNodeId = NormalizeNodeId(nodeId, deviceId);
                var recordId = timestamp + "-" + normalizedNodeId + "-capacity";
                var recordRoot = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "passport",
                    "node-activity",
                    timestamp + "-" + normalizedNodeId);
                Directory.CreateDirectory(recordRoot);

                var recordPath = Path.Combine(recordRoot, "node-capacity-snapshot.json");
                var payloadPath = Path.Combine(recordRoot, "node-capacity-snapshot.payload.json");
                var signaturePath = Path.Combine(recordRoot, "node-capacity-snapshot.sig");
                var relativePayloadPath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, payloadPath);
                var relativeSignaturePath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, signaturePath);
                var storageLimitBytes = (long)Math.Max(0, Math.Round(storageAllocationGb * 1024d * 1024d * 1024d));
                var availableBytes = TryGetAvailableBytes(resolvedWorkspaceRoot);
                var pinnedBytes = TryGetDirectorySize(ipfsRepoPath);
                var normalizedParticipationMode = NormalizeNodeParticipationMode(nodeParticipationMode);
                var normalizedCachePolicy = NormalizeNodeCachePolicy(nodeCachePolicy);
                var normalizedStorageGcWatermark = Math.Max(1, Math.Min(99, storageGcWatermark));
                var normalizedProvideStrategy = string.IsNullOrWhiteSpace(provideStrategy) ? "pinned" : provideStrategy.Trim();

                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "node_capacity_snapshot_record",
                    ["record_id"] = recordId,
                    ["created_utc"] = createdUtc,
                    ["effective_utc"] = createdUtc,
                    ["status"] = "active",
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["node_id"] = normalizedNodeId,
                    ["client_platform"] = "windows",
                    ["passport_client"] = "passport-windows",
                    ["storage_mode"] = string.Equals(normalizedParticipationMode, "Read-only cache", StringComparison.Ordinal)
                        ? "read_only"
                        : "participation",
                    ["participation_mode"] = normalizedParticipationMode,
                    ["participation_mode_code"] = Slugify(normalizedParticipationMode).Replace('-', '_'),
                    ["cache_policy"] = normalizedCachePolicy,
                    ["cache_policy_code"] = Slugify(normalizedCachePolicy).Replace('-', '_'),
                    ["storage_gc_watermark"] = normalizedStorageGcWatermark,
                    ["provide_strategy"] = normalizedProvideStrategy,
                    ["network_preference"] = preferWifiOnly ? "unmetered_preferred" : "standard",
                    ["storage_limit_bytes"] = storageLimitBytes,
                    ["local_repo_path_hash"] = string.IsNullOrWhiteSpace(ipfsRepoPath)
                        ? string.Empty
                        : ComputeSha256(Encoding.UTF8.GetBytes(Path.GetFullPath(ipfsRepoPath))),
                    ["ipfs_peer_id"] = string.Empty,
                    ["participation_scopes"] = BuildParticipationScopes(normalizedParticipationMode),
                    ["measurement_epoch"] = new Dictionary<string, object?>
                    {
                        ["epoch_id"] = "local-" + timestamp,
                        ["starts_utc"] = createdUtc,
                        ["ends_utc"] = createdUtc
                    },
                    ["observed_capacity"] = new Dictionary<string, object?>
                    {
                        ["available_bytes"] = availableBytes,
                        ["allocated_bytes"] = storageLimitBytes,
                        ["pinned_bytes"] = pinnedBytes
                    },
                    ["summary"] = "Local Passport node capacity snapshot. This is a metering input record, not money or settlement."
                };

                var unsignedPayloadBytes = JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions);
                var signatureBytes = PassportDeviceKeyStore.SignData(deviceKeyReferencePath, unsignedPayloadBytes);
                File.WriteAllBytes(payloadPath, unsignedPayloadBytes);
                File.WriteAllBytes(signaturePath, signatureBytes);

                record["signature"] = new Dictionary<string, object?>
                {
                    ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                    ["signing_device_record_id"] = deviceId,
                    ["signed_payload_path"] = relativePayloadPath,
                    ["signature_path"] = relativeSignaturePath,
                    ["signed_payload_sha256"] = ComputeSha256(unsignedPayloadBytes)
                };

                File.WriteAllText(recordPath, JsonSerializer.Serialize(record, JsonOptions));

                return new PassportMeteringRecordResult
                {
                    Succeeded = true,
                    Message = "Recorded a signed node capacity snapshot for Passport metering.",
                    RecordType = "node_capacity_snapshot_record",
                    RecordId = recordId,
                    RecordPath = recordPath,
                    SignaturePath = signaturePath
                };
            }
            catch (Exception ex)
            {
                return FailedMeteringRecord("Node capacity snapshot failed: " + ex.Message);
            }
        }

        public PassportMeteringRecordResult CreateStorageAssignmentAcknowledgment(
            string workspaceRoot,
            string identityId,
            string deviceId,
            string deviceKeyReferencePath,
            string nodeId,
            string assignmentId,
            string contentCid,
            string manifestSha256,
            string serviceClass,
            long assignedBytes,
            bool accepted)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(identityId))
                {
                    return FailedMeteringRecord("An active Passport identity is required before acknowledging a storage assignment.");
                }

                if (string.IsNullOrWhiteSpace(deviceId) || string.IsNullOrWhiteSpace(deviceKeyReferencePath))
                {
                    return FailedMeteringRecord("An active Passport device credential is required before acknowledging a storage assignment.");
                }

                if (!PassportDeviceKeyStore.ReferenceExists(deviceKeyReferencePath))
                {
                    return FailedMeteringRecord("The active Passport device key reference is not available.");
                }

                if (string.IsNullOrWhiteSpace(contentCid))
                {
                    return FailedMeteringRecord("A content CID is required before acknowledging a storage assignment.");
                }

                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                EnsureRegistryFolders(resolvedWorkspaceRoot);
                EnsureMeteringFolders(resolvedWorkspaceRoot);

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var normalizedNodeId = NormalizeNodeId(nodeId, deviceId);
                var normalizedAssignmentId = string.IsNullOrWhiteSpace(assignmentId)
                    ? "assignment-" + timestamp + "-" + normalizedNodeId
                    : assignmentId.Trim();
                var normalizedServiceClass = string.IsNullOrWhiteSpace(serviceClass)
                    ? "stewarded_archive_storage"
                    : serviceClass.Trim();
                var safeAssignmentId = Slugify(normalizedAssignmentId);
                if (string.IsNullOrWhiteSpace(safeAssignmentId))
                {
                    safeAssignmentId = "assignment";
                }

                var recordId = timestamp + "-" + safeAssignmentId + "-ack";
                var recordRoot = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "passport",
                    "metering",
                    "submissions",
                    timestamp + "-" + safeAssignmentId);
                Directory.CreateDirectory(recordRoot);

                var recordPath = Path.Combine(recordRoot, "storage-assignment-acknowledgment.json");
                var payloadPath = Path.Combine(recordRoot, "storage-assignment-acknowledgment.payload.json");
                var signaturePath = Path.Combine(recordRoot, "storage-assignment-acknowledgment.sig");
                var relativePayloadPath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, payloadPath);
                var relativeSignaturePath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, signaturePath);
                var epochId = "local-" + timestamp;

                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "storage_assignment_acknowledgment_record",
                    ["record_id"] = recordId,
                    ["created_utc"] = createdUtc,
                    ["effective_utc"] = createdUtc,
                    ["status"] = accepted ? "active" : "declined",
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["node_id"] = normalizedNodeId,
                    ["assignment_id"] = normalizedAssignmentId,
                    ["assignment_issuer"] = "local-passport-draft",
                    ["service_class"] = normalizedServiceClass,
                    ["content_ref"] = new Dictionary<string, object?>
                    {
                        ["cid"] = contentCid.Trim(),
                        ["manifest_sha256"] = string.IsNullOrWhiteSpace(manifestSha256) ? string.Empty : manifestSha256.Trim(),
                        ["relative_path"] = string.Empty
                    },
                    ["assigned_replica"] = new Dictionary<string, object?>
                    {
                        ["replica_index"] = 0,
                        ["replication_target"] = 0,
                        ["assigned_bytes"] = Math.Max(0, assignedBytes)
                    },
                    ["measurement_epoch"] = new Dictionary<string, object?>
                    {
                        ["epoch_id"] = epochId,
                        ["starts_utc"] = createdUtc,
                        ["ends_utc"] = createdUtc
                    },
                    ["acknowledgment"] = new Dictionary<string, object?>
                    {
                        ["accepted"] = accepted,
                        ["accepted_utc"] = accepted ? createdUtc : string.Empty,
                        ["decline_reason"] = accepted ? string.Empty : "declined_by_local_node"
                    },
                    ["summary"] = "Local Passport storage assignment acknowledgment. This establishes assigned responsibility only; it is not proof of storage or settlement."
                };

                var unsignedPayloadBytes = JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions);
                var signatureBytes = PassportDeviceKeyStore.SignData(deviceKeyReferencePath, unsignedPayloadBytes);
                File.WriteAllBytes(payloadPath, unsignedPayloadBytes);
                File.WriteAllBytes(signaturePath, signatureBytes);

                record["signature"] = new Dictionary<string, object?>
                {
                    ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                    ["signing_device_record_id"] = deviceId,
                    ["signed_payload_path"] = relativePayloadPath,
                    ["signature_path"] = relativeSignaturePath,
                    ["signed_payload_sha256"] = ComputeSha256(unsignedPayloadBytes)
                };

                File.WriteAllText(recordPath, JsonSerializer.Serialize(record, JsonOptions));

                return new PassportMeteringRecordResult
                {
                    Succeeded = true,
                    Message = "Recorded a signed storage assignment acknowledgment for Passport metering.",
                    RecordType = "storage_assignment_acknowledgment_record",
                    RecordId = recordId,
                    RecordPath = recordPath,
                    SignaturePath = signaturePath
                };
            }
            catch (Exception ex)
            {
                return FailedMeteringRecord("Storage assignment acknowledgment failed: " + ex.Message);
            }
        }

        public PassportMeteringRecordResult CreateStorageEpochProof(
            string workspaceRoot,
            string identityId,
            string deviceId,
            string deviceKeyReferencePath,
            string nodeId,
            string assignmentId,
            string contentCid,
            string manifestSha256,
            string serviceClass,
            string proofSourceFilePath)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(identityId))
                {
                    return FailedMeteringRecord("An active Passport identity is required before creating a storage epoch proof.");
                }

                if (string.IsNullOrWhiteSpace(deviceId) || string.IsNullOrWhiteSpace(deviceKeyReferencePath))
                {
                    return FailedMeteringRecord("An active Passport device credential is required before creating a storage epoch proof.");
                }

                if (!PassportDeviceKeyStore.ReferenceExists(deviceKeyReferencePath))
                {
                    return FailedMeteringRecord("The active Passport device key reference is not available.");
                }

                if (string.IsNullOrWhiteSpace(contentCid))
                {
                    return FailedMeteringRecord("A content CID is required before creating a storage epoch proof.");
                }

                if (string.IsNullOrWhiteSpace(proofSourceFilePath) || !File.Exists(proofSourceFilePath))
                {
                    return FailedMeteringRecord("A readable local proof source file is required before creating a storage epoch proof.");
                }

                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                EnsureRegistryFolders(resolvedWorkspaceRoot);
                EnsureMeteringFolders(resolvedWorkspaceRoot);

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var normalizedNodeId = NormalizeNodeId(nodeId, deviceId);
                var normalizedAssignmentId = string.IsNullOrWhiteSpace(assignmentId)
                    ? "assignment-" + timestamp + "-" + normalizedNodeId
                    : assignmentId.Trim();
                var normalizedServiceClass = string.IsNullOrWhiteSpace(serviceClass)
                    ? "stewarded_archive_storage"
                    : serviceClass.Trim();
                var safeAssignmentId = Slugify(normalizedAssignmentId);
                if (string.IsNullOrWhiteSpace(safeAssignmentId))
                {
                    safeAssignmentId = "assignment";
                }

                var fileInfo = new FileInfo(proofSourceFilePath);
                var sourceFileSha256 = ComputeFileSha256(proofSourceFilePath);
                var epochId = "local-" + timestamp;
                var challengeSeed = ComputeSha256(Encoding.UTF8.GetBytes(epochId + "|" + contentCid.Trim() + "|" + fileInfo.Length));
                var segmentOffsets = SelectSegmentOffsets(challengeSeed, fileInfo.Length);
                var response = ComputeSegmentProofResponse(proofSourceFilePath, segmentOffsets);
                var manifestHash = string.IsNullOrWhiteSpace(manifestSha256) ? sourceFileSha256 : manifestSha256.Trim();
                var verifiedGbDays = Math.Max(1, (fileInfo.Length + 1024L * 1024L * 1024L - 1) / (1024L * 1024L * 1024L));
                var recordId = timestamp + "-" + safeAssignmentId + "-proof";
                var retrievalVerifierSignature = "local-verifier-sha256:"
                    + ComputeSha256(Encoding.UTF8.GetBytes(recordId + "|" + response.ResponseSha256 + "|" + sourceFileSha256));
                var recordRoot = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "passport",
                    "metering",
                    "proofs",
                    timestamp + "-" + safeAssignmentId);
                Directory.CreateDirectory(recordRoot);

                var recordPath = Path.Combine(recordRoot, "storage-epoch-proof.json");
                var payloadPath = Path.Combine(recordRoot, "storage-epoch-proof.payload.json");
                var signaturePath = Path.Combine(recordRoot, "storage-epoch-proof.sig");
                var relativePayloadPath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, payloadPath);
                var relativeSignaturePath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, signaturePath);

                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "storage_epoch_proof_record",
                    ["record_id"] = recordId,
                    ["created_utc"] = createdUtc,
                    ["effective_utc"] = createdUtc,
                    ["status"] = "submitted",
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["node_id"] = normalizedNodeId,
                    ["assignment_id"] = normalizedAssignmentId,
                    ["service_class"] = normalizedServiceClass,
                    ["content_ref"] = new Dictionary<string, object?>
                    {
                        ["cid"] = contentCid.Trim(),
                        ["manifest_sha256"] = manifestHash,
                        ["relative_path"] = string.Empty
                    },
                    ["object_manifest"] = new Dictionary<string, object?>
                    {
                        ["manifest_version"] = 1,
                        ["manifest_sha256"] = manifestHash,
                        ["privacy_preserving_object_id_sha256"] = ComputeSha256(Encoding.UTF8.GetBytes(contentCid.Trim() + "|" + manifestHash)),
                        ["total_size_bytes"] = fileInfo.Length,
                        ["redundancy_target"] = 1,
                        ["chunks"] = new[]
                        {
                            new Dictionary<string, object?>
                            {
                                ["chunk_index"] = 0,
                                ["offset"] = 0,
                                ["size_bytes"] = fileInfo.Length,
                                ["sha256"] = sourceFileSha256
                            }
                        }
                    },
                    ["measurement_epoch"] = new Dictionary<string, object?>
                    {
                        ["epoch_id"] = epochId,
                        ["starts_utc"] = createdUtc,
                        ["ends_utc"] = createdUtc
                    },
                    ["challenge"] = new Dictionary<string, object?>
                    {
                        ["challenge_id"] = "challenge-" + timestamp + "-" + safeAssignmentId,
                        ["challenge_method"] = "local_deterministic_epoch_cid_segment_hash_v1",
                        ["challenge_seed_sha256"] = challengeSeed,
                        ["segment_offsets"] = segmentOffsets
                    },
                    ["proof_response"] = new Dictionary<string, object?>
                    {
                        ["response_method"] = "segment_hash_v1",
                        ["response_sha256"] = response.ResponseSha256,
                        ["proved_bytes"] = response.ProvedBytes,
                        ["observed_utc"] = createdUtc
                    },
                    ["retrieval_challenge"] = new Dictionary<string, object?>
                    {
                        ["challenge_id"] = "retrieval-" + timestamp + "-" + safeAssignmentId,
                        ["challenge_method"] = "local_sample_retrieval_v1",
                        ["latency_threshold_ms"] = 5000,
                        ["verifier_id"] = "local-passport-storage-verifier-v1"
                    },
                    ["retrieval_response"] = new Dictionary<string, object?>
                    {
                        ["succeeded"] = true,
                        ["retrieved_bytes"] = fileInfo.Length,
                        ["latency_ms"] = 0,
                        ["response_sha256"] = sourceFileSha256,
                        ["verifier_signature_algorithm"] = "LOCAL_SHA256_ATTESTATION_V1",
                        ["verifier_signature"] = retrievalVerifierSignature
                    },
                    ["metering_claim"] = new Dictionary<string, object?>
                    {
                        ["claimed_replicated_byte_seconds"] = fileInfo.Length,
                        ["claimed_storage_bytes"] = fileInfo.Length
                    },
                    ["delivery_metering"] = new Dictionary<string, object?>
                    {
                        ["metering_formula"] = "verified_gb_days=max(1,ceil(claimed_storage_bytes/1GiB)) for local MVP proof records",
                        ["verified_gb_days"] = verifiedGbDays,
                        ["claimed_storage_bytes"] = fileInfo.Length,
                        ["claimed_replicated_byte_seconds"] = fileInfo.Length
                    },
                    ["repair_status"] = new Dictionary<string, object?>
                    {
                        ["node_failed"] = false,
                        ["repair_required"] = false,
                        ["redundancy_status"] = "healthy",
                        ["repair_action"] = "none"
                    },
                    ["failure_remedy"] = new Dictionary<string, object?>
                    {
                        ["failed_epoch_remedy"] = "automatic_cc_recredit_or_service_extension",
                        ["refund_reason_code"] = "unused_or_failed_epochs",
                        ["service_extension_allowed"] = true
                    },
                    ["local_evidence"] = new Dictionary<string, object?>
                    {
                        ["source_file_name"] = fileInfo.Name,
                        ["source_file_length"] = fileInfo.Length,
                        ["source_file_sha256"] = sourceFileSha256
                    },
                    ["summary"] = "Local Passport storage epoch proof. This is submitted proof evidence only; it is not accepted metering or settlement."
                };

                var unsignedPayloadBytes = JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions);
                var signatureBytes = PassportDeviceKeyStore.SignData(deviceKeyReferencePath, unsignedPayloadBytes);
                File.WriteAllBytes(payloadPath, unsignedPayloadBytes);
                File.WriteAllBytes(signaturePath, signatureBytes);

                record["signature"] = new Dictionary<string, object?>
                {
                    ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                    ["signing_device_record_id"] = deviceId,
                    ["signed_payload_path"] = relativePayloadPath,
                    ["signature_path"] = relativeSignaturePath,
                    ["signed_payload_sha256"] = ComputeSha256(unsignedPayloadBytes)
                };

                File.WriteAllText(recordPath, JsonSerializer.Serialize(record, JsonOptions));

                return new PassportMeteringRecordResult
                {
                    Succeeded = true,
                    Message = "Recorded a signed local storage epoch proof for Passport metering.",
                    RecordType = "storage_epoch_proof_record",
                    RecordId = recordId,
                    RecordPath = recordPath,
                    SignaturePath = signaturePath
                };
            }
            catch (Exception ex)
            {
                return FailedMeteringRecord("Storage epoch proof failed: " + ex.Message);
            }
        }

        public PassportMeteringRecordResult CreateLocalMeteringStatus(
            string workspaceRoot,
            string identityId,
            string deviceId,
            string nodeId)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(identityId))
                {
                    return FailedMeteringRecord("An active Passport identity is required before creating local metering status.");
                }

                if (string.IsNullOrWhiteSpace(deviceId))
                {
                    return FailedMeteringRecord("An active Passport device is required before creating local metering status.");
                }

                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                EnsureMeteringFolders(resolvedWorkspaceRoot);

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var normalizedNodeId = NormalizeNodeId(nodeId, deviceId);
                var proofRoot = Path.Combine(resolvedWorkspaceRoot, "records", "passport", "metering", "proofs");
                var submittedProofCount = 0;
                long claimedReplicatedByteSeconds = 0;
                long claimedStorageBytes = 0;

                if (Directory.Exists(proofRoot))
                {
                    foreach (var proofPath in Directory.EnumerateFiles(proofRoot, "storage-epoch-proof.json", SearchOption.AllDirectories))
                    {
                        try
                        {
                            using var document = JsonDocument.Parse(File.ReadAllText(proofPath));
                            var root = document.RootElement;
                            if (!root.TryGetProperty("record_type", out var recordTypeElement)
                                || !string.Equals(recordTypeElement.GetString(), "storage_epoch_proof_record", StringComparison.Ordinal))
                            {
                                continue;
                            }

                            if (root.TryGetProperty("archrealms_identity_id", out var identityElement)
                                && !string.Equals(identityElement.GetString(), identityId, StringComparison.OrdinalIgnoreCase))
                            {
                                continue;
                            }

                            if (root.TryGetProperty("device_id", out var deviceElement)
                                && !string.Equals(deviceElement.GetString(), deviceId, StringComparison.OrdinalIgnoreCase))
                            {
                                continue;
                            }

                            submittedProofCount++;
                            if (root.TryGetProperty("metering_claim", out var claimElement))
                            {
                                claimedReplicatedByteSeconds += TryReadInt64(claimElement, "claimed_replicated_byte_seconds");
                                claimedStorageBytes += TryReadInt64(claimElement, "claimed_storage_bytes");
                            }
                        }
                        catch
                        {
                        }
                    }
                }

                var recordId = timestamp + "-" + normalizedNodeId + "-local-metering-status";
                var recordRoot = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "passport",
                    "metering",
                    "status",
                    timestamp + "-" + normalizedNodeId);
                Directory.CreateDirectory(recordRoot);

                var recordPath = Path.Combine(recordRoot, "local-metering-status.json");
                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "metering_status_record",
                    ["record_id"] = recordId,
                    ["created_utc"] = createdUtc,
                    ["effective_utc"] = createdUtc,
                    ["status"] = "reported",
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["node_id"] = normalizedNodeId,
                    ["measurement_epoch"] = new Dictionary<string, object?>
                    {
                        ["epoch_id"] = "local-summary-" + timestamp,
                        ["starts_utc"] = createdUtc,
                        ["ends_utc"] = createdUtc
                    },
                    ["source"] = new Dictionary<string, object?>
                    {
                        ["metering_authority"] = "local-passport-read-only-summary",
                        ["source_record_id"] = string.Empty,
                        ["source_manifest_sha256"] = string.Empty
                    },
                    ["verified_service"] = new Dictionary<string, object?>
                    {
                        ["submitted_proof_count"] = submittedProofCount,
                        ["accepted_proof_count"] = 0,
                        ["rejected_proof_count"] = 0,
                        ["verified_replicated_byte_seconds"] = 0,
                        ["verified_retrieval_bytes"] = 0,
                        ["verified_repair_bytes"] = 0,
                        ["claimed_replicated_byte_seconds"] = claimedReplicatedByteSeconds,
                        ["claimed_storage_bytes"] = claimedStorageBytes
                    },
                    ["reliability"] = new Dictionary<string, object?>
                    {
                        ["proof_success_rate"] = 0.0,
                        ["retrieval_success_rate"] = 0.0,
                        ["node_availability_score"] = 0.0
                    },
                    ["settlement_preview"] = new Dictionary<string, object?>
                    {
                        ["settlement_status"] = "not_settled",
                        ["settlement_record_id"] = string.Empty
                    },
                    ["summary"] = "Local read-only metering status. Submitted proof claims are summarized, but no proof has been accepted, rejected, paid, or settled by this record."
                };

                File.WriteAllText(recordPath, JsonSerializer.Serialize(record, JsonOptions));

                return new PassportMeteringRecordResult
                {
                    Succeeded = true,
                    Message = "Created local read-only metering status from submitted Passport proof records.",
                    RecordType = "metering_status_record",
                    RecordId = recordId,
                    RecordPath = recordPath,
                    SignaturePath = string.Empty
                };
            }
            catch (Exception ex)
            {
                return FailedMeteringRecord("Local metering status failed: " + ex.Message);
            }
        }

        public PassportMeteringRecordResult VerifyLocalMeteringRecords(
            string workspaceRoot,
            string identityId,
            string deviceId,
            string deviceKeyReferencePath)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(identityId))
                {
                    return FailedMeteringRecord("An active Passport identity is required before verifying local metering records.");
                }

                if (string.IsNullOrWhiteSpace(deviceId) || string.IsNullOrWhiteSpace(deviceKeyReferencePath))
                {
                    return FailedMeteringRecord("An active Passport device credential is required before verifying local metering records.");
                }

                if (!PassportDeviceKeyStore.ReferenceExists(deviceKeyReferencePath))
                {
                    return FailedMeteringRecord("The active Passport device key reference is not available.");
                }

                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                EnsureMeteringFolders(resolvedWorkspaceRoot);

                var publicKeyBytes = PassportDeviceKeyStore.ExportPublicKey(deviceKeyReferencePath);
                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var verifiedCount = 0;
                var failedCount = 0;
                var skippedCount = 0;
                var checkedRecords = new List<Dictionary<string, object?>>();

                foreach (var candidate in EnumerateLocalSignedMeteringRecords(resolvedWorkspaceRoot))
                {
                    var result = VerifyLocalSignedMeteringRecord(
                        resolvedWorkspaceRoot,
                        candidate,
                        identityId,
                        deviceId,
                        publicKeyBytes);

                    if (string.Equals(result["verification_status"] as string, "verified", StringComparison.Ordinal))
                    {
                        verifiedCount++;
                    }
                    else if (string.Equals(result["verification_status"] as string, "skipped", StringComparison.Ordinal))
                    {
                        skippedCount++;
                    }
                    else
                    {
                        failedCount++;
                    }

                    checkedRecords.Add(result);
                }

                var reportRoot = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "passport",
                    "metering",
                    "status",
                    timestamp + "-local-verification");
                Directory.CreateDirectory(reportRoot);

                var reportPath = Path.Combine(reportRoot, "local-metering-verification-report.json");
                var reportId = timestamp + "-local-metering-verification";
                var report = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "local_metering_verification_report",
                    ["record_id"] = reportId,
                    ["created_utc"] = createdUtc,
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["verified_record_count"] = verifiedCount,
                    ["failed_record_count"] = failedCount,
                    ["skipped_record_count"] = skippedCount,
                    ["checked_records"] = checkedRecords,
                    ["settlement_status"] = "not_settled",
                    ["summary"] = "Local integrity verification for Passport metering records. This report verifies payload hashes and signatures only; it does not accept proofs or settle value."
                };

                File.WriteAllText(reportPath, JsonSerializer.Serialize(report, JsonOptions));

                return new PassportMeteringRecordResult
                {
                    Succeeded = failedCount == 0,
                    Message = failedCount == 0
                        ? "Verified local metering record integrity."
                        : "Local metering verification completed with failures.",
                    RecordType = "local_metering_verification_report",
                    RecordId = reportId,
                    RecordPath = reportPath,
                    SignaturePath = string.Empty
                };
            }
            catch (Exception ex)
            {
                return FailedMeteringRecord("Local metering verification failed: " + ex.Message);
            }
        }

        public PassportMeteringRecordResult CreateMeteringPackageAdmission(
            string workspaceRoot,
            string identityId,
            string deviceId,
            string deviceKeyReferencePath,
            string packageRoot,
            string packageVerificationReportPath)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(identityId))
                {
                    return FailedMeteringRecord("An active Passport identity is required before admitting a metering package.");
                }

                if (string.IsNullOrWhiteSpace(deviceId) || string.IsNullOrWhiteSpace(deviceKeyReferencePath))
                {
                    return FailedMeteringRecord("An active Passport device credential is required before admitting a metering package.");
                }

                if (!PassportDeviceKeyStore.ReferenceExists(deviceKeyReferencePath))
                {
                    return FailedMeteringRecord("The active Passport device key reference is not available.");
                }

                if (string.IsNullOrWhiteSpace(packageRoot))
                {
                    return FailedMeteringRecord("A metering package root is required before admission.");
                }

                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                var resolvedPackageRoot = Path.GetFullPath(packageRoot);
                var resolvedVerificationReportPath = string.IsNullOrWhiteSpace(packageVerificationReportPath)
                    ? Path.Combine(resolvedPackageRoot, "metering-package-verification-report.json")
                    : Path.GetFullPath(packageVerificationReportPath);
                var manifestPath = Path.Combine(resolvedPackageRoot, "manifest.json");
                var meteringReportPath = Path.Combine(resolvedPackageRoot, "package", "metering-report.json");

                if (!Directory.Exists(resolvedPackageRoot))
                {
                    return FailedMeteringRecord("Metering package root was not found.");
                }

                if (!File.Exists(resolvedVerificationReportPath))
                {
                    return FailedMeteringRecord("Metering package verification report was not found.");
                }

                if (!File.Exists(manifestPath))
                {
                    return FailedMeteringRecord("Metering package manifest was not found.");
                }

                if (!File.Exists(meteringReportPath))
                {
                    return FailedMeteringRecord("Packaged authoritative metering report was not found.");
                }

                using var verificationDocument = JsonDocument.Parse(File.ReadAllText(resolvedVerificationReportPath));
                var verificationRoot = verificationDocument.RootElement;
                var packageVerified = TryReadBoolean(verificationRoot, "verified");
                var documentHashesValid = TryReadBoolean(verificationRoot, "document_hashes_valid");
                if (!packageVerified || !documentHashesValid)
                {
                    return FailedMeteringRecord("Metering package verification has not passed; admission was not created.");
                }

                using var manifestDocument = JsonDocument.Parse(File.ReadAllText(manifestPath));
                var manifestRoot = manifestDocument.RootElement;
                using var meteringReportDocument = JsonDocument.Parse(File.ReadAllText(meteringReportPath));
                var meteringReportRoot = meteringReportDocument.RootElement;

                EnsureRegistryFolders(resolvedWorkspaceRoot);
                EnsureMeteringFolders(resolvedWorkspaceRoot);

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var packageId = TryReadString(manifestRoot, "package_id");
                if (string.IsNullOrWhiteSpace(packageId))
                {
                    packageId = Path.GetFileName(resolvedPackageRoot.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
                }

                var safePackageId = Slugify(packageId);
                if (string.IsNullOrWhiteSpace(safePackageId))
                {
                    safePackageId = "metering-package";
                }

                var admissionId = timestamp + "-" + safePackageId + "-admission";
                var admissionRoot = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "passport",
                    "metering",
                    "admissions",
                    timestamp + "-" + safePackageId);
                Directory.CreateDirectory(admissionRoot);

                var admissionPath = Path.Combine(admissionRoot, "metering-admission.json");
                var payloadPath = Path.Combine(admissionRoot, "metering-admission.payload.json");
                var signaturePath = Path.Combine(admissionRoot, "metering-admission.sig");
                var relativePayloadPath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, payloadPath);
                var relativeSignaturePath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, signaturePath);

                var acceptedProofCount = TryReadInt64(verificationRoot, "accepted_proof_count");
                var rejectedProofCount = TryReadInt64(verificationRoot, "rejected_proof_count");
                var verifiedReplicatedByteSeconds = TryReadInt64(meteringReportRoot, "verified_replicated_byte_seconds");
                var sourceReportId = TryReadString(meteringReportRoot, "report_id");
                if (string.IsNullOrWhiteSpace(sourceReportId))
                {
                    sourceReportId = TryReadString(meteringReportRoot, "record_id");
                }

                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_metering_admission_record",
                    ["record_id"] = admissionId,
                    ["created_utc"] = createdUtc,
                    ["effective_utc"] = createdUtc,
                    ["status"] = "admitted",
                    ["admission_scope"] = "metering_report_package",
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["package_id"] = packageId,
                    ["package_root"] = resolvedPackageRoot,
                    ["package_root_sha256"] = ComputeSha256(Encoding.UTF8.GetBytes(resolvedPackageRoot)),
                    ["manifest_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, manifestPath),
                    ["manifest_sha256"] = ComputeFileSha256(manifestPath),
                    ["package_verification_report_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, resolvedVerificationReportPath),
                    ["package_verification_report_sha256"] = ComputeFileSha256(resolvedVerificationReportPath),
                    ["source_metering_report_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, meteringReportPath),
                    ["source_metering_report_sha256"] = ComputeFileSha256(meteringReportPath),
                    ["source_metering_report_id"] = sourceReportId,
                    ["package_verification"] = new Dictionary<string, object?>
                    {
                        ["verified"] = packageVerified,
                        ["document_hashes_valid"] = documentHashesValid,
                        ["accepted_proof_count"] = acceptedProofCount,
                        ["rejected_proof_count"] = rejectedProofCount
                    },
                    ["admitted_metering"] = new Dictionary<string, object?>
                    {
                        ["accepted_proof_count"] = acceptedProofCount,
                        ["rejected_proof_count"] = rejectedProofCount,
                        ["verified_replicated_byte_seconds"] = verifiedReplicatedByteSeconds
                    },
                    ["settlement_status"] = "not_settled",
                    ["settlement_record_id"] = string.Empty,
                    ["summary"] = "Registrar-style Passport metering package admission. This admits verified metering evidence for later policy review; it does not create payment, wallet balance, token entitlement, or settlement."
                };

                var unsignedPayloadBytes = JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions);
                var signatureBytes = PassportDeviceKeyStore.SignData(deviceKeyReferencePath, unsignedPayloadBytes);
                File.WriteAllBytes(payloadPath, unsignedPayloadBytes);
                File.WriteAllBytes(signaturePath, signatureBytes);

                record["signature"] = new Dictionary<string, object?>
                {
                    ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                    ["signing_device_record_id"] = deviceId,
                    ["signed_payload_path"] = relativePayloadPath,
                    ["signature_path"] = relativeSignaturePath,
                    ["signed_payload_sha256"] = ComputeSha256(unsignedPayloadBytes)
                };

                File.WriteAllText(admissionPath, JsonSerializer.Serialize(record, JsonOptions));

                return new PassportMeteringRecordResult
                {
                    Succeeded = true,
                    Message = "Created a signed Passport metering package admission record.",
                    RecordType = "passport_metering_admission_record",
                    RecordId = admissionId,
                    RecordPath = admissionPath,
                    SignaturePath = signaturePath
                };
            }
            catch (Exception ex)
            {
                return FailedMeteringRecord("Metering package admission failed: " + ex.Message);
            }
        }

        public PassportMeteringRecordResult CreateMeteringAuditChallenge(
            string workspaceRoot,
            string identityId,
            string deviceId,
            string deviceKeyReferencePath,
            string admissionRecordPath,
            string registrarId,
            string challengeReason)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(identityId))
                {
                    return FailedMeteringRecord("An active Passport identity is required before creating a metering audit challenge.");
                }

                if (string.IsNullOrWhiteSpace(deviceId) || string.IsNullOrWhiteSpace(deviceKeyReferencePath))
                {
                    return FailedMeteringRecord("An active Passport device credential is required before creating a metering audit challenge.");
                }

                if (!PassportDeviceKeyStore.ReferenceExists(deviceKeyReferencePath))
                {
                    return FailedMeteringRecord("The active Passport device key reference is not available.");
                }

                if (string.IsNullOrWhiteSpace(admissionRecordPath) || !File.Exists(admissionRecordPath))
                {
                    return FailedMeteringRecord("A metering admission record is required before creating an audit challenge.");
                }

                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                EnsureRegistryFolders(resolvedWorkspaceRoot);
                EnsureMeteringFolders(resolvedWorkspaceRoot);

                using var admissionDocument = JsonDocument.Parse(File.ReadAllText(admissionRecordPath));
                var admissionRootElement = admissionDocument.RootElement;
                var admissionRecordType = TryReadString(admissionRootElement, "record_type");
                if (!string.Equals(admissionRecordType, "passport_metering_admission_record", StringComparison.Ordinal))
                {
                    return FailedMeteringRecord("The supplied record is not a Passport metering admission record.");
                }

                if (!string.Equals(TryReadString(admissionRootElement, "status"), "admitted", StringComparison.Ordinal))
                {
                    return FailedMeteringRecord("The metering admission record is not admitted.");
                }

                if (!string.Equals(TryReadString(admissionRootElement, "settlement_status"), "not_settled", StringComparison.Ordinal))
                {
                    return FailedMeteringRecord("The metering admission record is already marked with a settlement status other than not_settled.");
                }

                var packageId = TryReadString(admissionRootElement, "package_id");
                var admissionRecordId = TryReadString(admissionRootElement, "record_id");
                var packageRoot = TryReadString(admissionRootElement, "package_root");
                if (string.IsNullOrWhiteSpace(packageRoot))
                {
                    return FailedMeteringRecord("The admission record does not include a package root.");
                }

                var resolvedPackageRoot = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, packageRoot);
                var manifestPath = Path.Combine(resolvedPackageRoot, "manifest.json");
                if (!File.Exists(manifestPath))
                {
                    return FailedMeteringRecord("The admitted package manifest was not found.");
                }

                var challengedRecords = SelectAuditChallengeRecords(resolvedPackageRoot, manifestPath);
                if (challengedRecords.Count == 0)
                {
                    return FailedMeteringRecord("No storage proof source records were found in the admitted metering package.");
                }

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var safePackageId = Slugify(packageId);
                if (string.IsNullOrWhiteSpace(safePackageId))
                {
                    safePackageId = "metering-package";
                }

                var recordId = timestamp + "-" + safePackageId + "-audit-challenge";
                var recordRoot = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "passport",
                    "metering",
                    "review",
                    "audit-challenges",
                    timestamp + "-" + safePackageId);
                Directory.CreateDirectory(recordRoot);

                var recordPath = Path.Combine(recordRoot, "metering-audit-challenge.json");
                var payloadPath = Path.Combine(recordRoot, "metering-audit-challenge.payload.json");
                var signaturePath = Path.Combine(recordRoot, "metering-audit-challenge.sig");
                var relativePayloadPath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, payloadPath);
                var relativeSignaturePath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, signaturePath);
                var normalizedRegistrarId = string.IsNullOrWhiteSpace(registrarId) ? deviceId : registrarId.Trim();
                var normalizedChallengeReason = string.IsNullOrWhiteSpace(challengeReason) ? "routine_sample" : challengeReason.Trim();
                var challengeSeed = ComputeSha256(Encoding.UTF8.GetBytes(recordId + "|" + admissionRecordId + "|" + packageId));

                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_metering_audit_challenge_record",
                    ["record_id"] = recordId,
                    ["created_utc"] = createdUtc,
                    ["effective_utc"] = createdUtc,
                    ["status"] = "audit_pending",
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["registrar_id"] = normalizedRegistrarId,
                    ["admission_record_id"] = admissionRecordId,
                    ["admission_record_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, admissionRecordPath),
                    ["package_id"] = packageId,
                    ["challenge_scope"] = "sampled_storage_epoch_proofs",
                    ["challenge_reason"] = normalizedChallengeReason,
                    ["challenge_seed_sha256"] = challengeSeed,
                    ["sample_policy"] = new Dictionary<string, object?>
                    {
                        ["policy_version"] = "metering-admission-policy-2026-04-27",
                        ["minimum_sample_count"] = 1,
                        ["sampling_method"] = "deterministic_seeded_sample"
                    },
                    ["challenged_records"] = challengedRecords,
                    ["response_due_utc"] = DateTime.UtcNow.AddDays(1).ToString("yyyy-MM-ddTHH:mm:ssZ"),
                    ["audit_result"] = new Dictionary<string, object?>
                    {
                        ["result_status"] = "pending",
                        ["accepted_record_count"] = 0,
                        ["rejected_record_count"] = 0,
                        ["result_record_id"] = string.Empty
                    },
                    ["settlement_status"] = "not_settled",
                    ["summary"] = "Signed Passport metering audit challenge for an admitted package. This requests review evidence only and does not settle value."
                };

                var unsignedPayloadBytes = JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions);
                var signatureBytes = PassportDeviceKeyStore.SignData(deviceKeyReferencePath, unsignedPayloadBytes);
                File.WriteAllBytes(payloadPath, unsignedPayloadBytes);
                File.WriteAllBytes(signaturePath, signatureBytes);

                record["signature"] = new Dictionary<string, object?>
                {
                    ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                    ["signing_device_record_id"] = deviceId,
                    ["signed_payload_path"] = relativePayloadPath,
                    ["signature_path"] = relativeSignaturePath,
                    ["signed_payload_sha256"] = ComputeSha256(unsignedPayloadBytes)
                };

                File.WriteAllText(recordPath, JsonSerializer.Serialize(record, JsonOptions));

                return new PassportMeteringRecordResult
                {
                    Succeeded = true,
                    Message = "Created a signed Passport metering audit challenge record.",
                    RecordType = "passport_metering_audit_challenge_record",
                    RecordId = recordId,
                    RecordPath = recordPath,
                    SignaturePath = signaturePath
                };
            }
            catch (Exception ex)
            {
                return FailedMeteringRecord("Metering audit challenge failed: " + ex.Message);
            }
        }

        public PassportMeteringRecordResult CreateMeteringDispute(
            string workspaceRoot,
            string identityId,
            string deviceId,
            string deviceKeyReferencePath,
            string admissionRecordPath,
            string auditChallengeRecordPath,
            string openedByRole,
            string openedById,
            string disputeScope,
            string challengeReason,
            string requestedRemedy)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(identityId))
                {
                    return FailedMeteringRecord("An active Passport identity is required before creating a metering dispute.");
                }

                if (string.IsNullOrWhiteSpace(deviceId) || string.IsNullOrWhiteSpace(deviceKeyReferencePath))
                {
                    return FailedMeteringRecord("An active Passport device credential is required before creating a metering dispute.");
                }

                if (!PassportDeviceKeyStore.ReferenceExists(deviceKeyReferencePath))
                {
                    return FailedMeteringRecord("The active Passport device key reference is not available.");
                }

                if (string.IsNullOrWhiteSpace(admissionRecordPath) || !File.Exists(admissionRecordPath))
                {
                    return FailedMeteringRecord("A metering admission record is required before creating a dispute.");
                }

                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                EnsureRegistryFolders(resolvedWorkspaceRoot);
                EnsureMeteringFolders(resolvedWorkspaceRoot);

                using var admissionDocument = JsonDocument.Parse(File.ReadAllText(admissionRecordPath));
                var admissionRootElement = admissionDocument.RootElement;
                if (!string.Equals(TryReadString(admissionRootElement, "record_type"), "passport_metering_admission_record", StringComparison.Ordinal))
                {
                    return FailedMeteringRecord("The supplied record is not a Passport metering admission record.");
                }

                if (!string.Equals(TryReadString(admissionRootElement, "status"), "admitted", StringComparison.Ordinal))
                {
                    return FailedMeteringRecord("The metering admission record is not admitted.");
                }

                if (!string.Equals(TryReadString(admissionRootElement, "settlement_status"), "not_settled", StringComparison.Ordinal))
                {
                    return FailedMeteringRecord("The metering admission record is already marked with a settlement status other than not_settled.");
                }

                var packageId = TryReadString(admissionRootElement, "package_id");
                var admissionRecordId = TryReadString(admissionRootElement, "record_id");
                var packageRoot = TryReadString(admissionRootElement, "package_root");
                var normalizedChallengeReason = string.IsNullOrWhiteSpace(challengeReason) ? "audit_review" : challengeReason.Trim();
                var challengedRecords = new List<Dictionary<string, object?>>();
                var auditChallengeRecordId = string.Empty;

                if (!string.IsNullOrWhiteSpace(auditChallengeRecordPath) && File.Exists(auditChallengeRecordPath))
                {
                    using var auditDocument = JsonDocument.Parse(File.ReadAllText(auditChallengeRecordPath));
                    var auditRoot = auditDocument.RootElement;
                    if (!string.Equals(TryReadString(auditRoot, "record_type"), "passport_metering_audit_challenge_record", StringComparison.Ordinal))
                    {
                        return FailedMeteringRecord("The supplied audit challenge path is not a Passport metering audit challenge record.");
                    }

                    auditChallengeRecordId = TryReadString(auditRoot, "record_id");
                    challengedRecords = ReadChallengedRecords(auditRoot, normalizedChallengeReason);
                }

                if (challengedRecords.Count == 0)
                {
                    if (string.IsNullOrWhiteSpace(packageRoot))
                    {
                        return FailedMeteringRecord("The admission record does not include a package root.");
                    }

                    var resolvedPackageRoot = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, packageRoot);
                    var manifestPath = Path.Combine(resolvedPackageRoot, "manifest.json");
                    if (!File.Exists(manifestPath))
                    {
                        return FailedMeteringRecord("The admitted package manifest was not found.");
                    }

                    challengedRecords = SelectAuditChallengeRecords(resolvedPackageRoot, manifestPath);
                    foreach (var challengedRecord in challengedRecords)
                    {
                        challengedRecord["challenge_reason"] = normalizedChallengeReason;
                    }
                }

                if (challengedRecords.Count == 0)
                {
                    return FailedMeteringRecord("No challenged records were available for the dispute.");
                }

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var safePackageId = Slugify(packageId);
                if (string.IsNullOrWhiteSpace(safePackageId))
                {
                    safePackageId = "metering-package";
                }

                var recordId = timestamp + "-" + safePackageId + "-dispute";
                var recordRoot = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "passport",
                    "metering",
                    "review",
                    "disputes",
                    timestamp + "-" + safePackageId);
                Directory.CreateDirectory(recordRoot);

                var recordPath = Path.Combine(recordRoot, "metering-dispute.json");
                var payloadPath = Path.Combine(recordRoot, "metering-dispute.payload.json");
                var signaturePath = Path.Combine(recordRoot, "metering-dispute.sig");
                var relativePayloadPath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, payloadPath);
                var relativeSignaturePath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, signaturePath);
                var normalizedOpenedByRole = string.IsNullOrWhiteSpace(openedByRole) ? "registrar" : openedByRole.Trim();
                var normalizedOpenedById = string.IsNullOrWhiteSpace(openedById) ? deviceId : openedById.Trim();
                var normalizedDisputeScope = string.IsNullOrWhiteSpace(disputeScope) ? "proof_count_or_service_units" : disputeScope.Trim();
                var normalizedRequestedRemedy = string.IsNullOrWhiteSpace(requestedRemedy) ? "exclude_or_correct_challenged_units" : requestedRemedy.Trim();

                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_metering_dispute_record",
                    ["record_id"] = recordId,
                    ["created_utc"] = createdUtc,
                    ["effective_utc"] = createdUtc,
                    ["status"] = "opened",
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["opened_by_role"] = normalizedOpenedByRole,
                    ["opened_by_id"] = normalizedOpenedById,
                    ["admission_record_id"] = admissionRecordId,
                    ["admission_record_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, admissionRecordPath),
                    ["audit_challenge_record_id"] = auditChallengeRecordId,
                    ["audit_challenge_record_path"] = string.IsNullOrWhiteSpace(auditChallengeRecordPath)
                        ? string.Empty
                        : ToWorkspaceRelativePath(resolvedWorkspaceRoot, auditChallengeRecordPath),
                    ["package_id"] = packageId,
                    ["dispute_scope"] = normalizedDisputeScope,
                    ["challenged_records"] = challengedRecords,
                    ["requested_remedy"] = normalizedRequestedRemedy,
                    ["evidence_refs"] = Array.Empty<string>(),
                    ["response_due_utc"] = DateTime.UtcNow.AddDays(1).ToString("yyyy-MM-ddTHH:mm:ssZ"),
                    ["disposition"] = new Dictionary<string, object?>
                    {
                        ["status"] = "opened",
                        ["resolved_utc"] = string.Empty,
                        ["resolution_record_id"] = string.Empty,
                        ["summary"] = string.Empty
                    },
                    ["settlement_status"] = "not_settled",
                    ["summary"] = "Signed Passport metering dispute for admitted evidence. This opens review only and does not create payment, token, redemption, transfer, or blockchain settlement."
                };

                var unsignedPayloadBytes = JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions);
                var signatureBytes = PassportDeviceKeyStore.SignData(deviceKeyReferencePath, unsignedPayloadBytes);
                File.WriteAllBytes(payloadPath, unsignedPayloadBytes);
                File.WriteAllBytes(signaturePath, signatureBytes);

                record["signature"] = new Dictionary<string, object?>
                {
                    ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                    ["signing_device_record_id"] = deviceId,
                    ["signed_payload_path"] = relativePayloadPath,
                    ["signature_path"] = relativeSignaturePath,
                    ["signed_payload_sha256"] = ComputeSha256(unsignedPayloadBytes)
                };

                File.WriteAllText(recordPath, JsonSerializer.Serialize(record, JsonOptions));

                return new PassportMeteringRecordResult
                {
                    Succeeded = true,
                    Message = "Created a signed Passport metering dispute record.",
                    RecordType = "passport_metering_dispute_record",
                    RecordId = recordId,
                    RecordPath = recordPath,
                    SignaturePath = signaturePath
                };
            }
            catch (Exception ex)
            {
                return FailedMeteringRecord("Metering dispute failed: " + ex.Message);
            }
        }

        public PassportMeteringRecordResult CreateMeteringCorrection(
            string workspaceRoot,
            string identityId,
            string deviceId,
            string deviceKeyReferencePath,
            string admissionRecordPath,
            string auditChallengeRecordPath,
            string disputeRecordPath,
            string registrarId,
            string correctionReason,
            long correctedAcceptedProofCount,
            long correctedRejectedProofCount,
            long correctedVerifiedReplicatedByteSeconds)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(identityId))
                {
                    return FailedMeteringRecord("An active Passport identity is required before creating a metering correction.");
                }

                if (string.IsNullOrWhiteSpace(deviceId) || string.IsNullOrWhiteSpace(deviceKeyReferencePath))
                {
                    return FailedMeteringRecord("An active Passport device credential is required before creating a metering correction.");
                }

                if (!PassportDeviceKeyStore.ReferenceExists(deviceKeyReferencePath))
                {
                    return FailedMeteringRecord("The active Passport device key reference is not available.");
                }

                if (string.IsNullOrWhiteSpace(admissionRecordPath) || !File.Exists(admissionRecordPath))
                {
                    return FailedMeteringRecord("A metering admission record is required before creating a correction.");
                }

                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                EnsureRegistryFolders(resolvedWorkspaceRoot);
                EnsureMeteringFolders(resolvedWorkspaceRoot);

                using var admissionDocument = JsonDocument.Parse(File.ReadAllText(admissionRecordPath));
                var admissionRootElement = admissionDocument.RootElement;
                if (!string.Equals(TryReadString(admissionRootElement, "record_type"), "passport_metering_admission_record", StringComparison.Ordinal))
                {
                    return FailedMeteringRecord("The supplied record is not a Passport metering admission record.");
                }

                if (!string.Equals(TryReadString(admissionRootElement, "status"), "admitted", StringComparison.Ordinal))
                {
                    return FailedMeteringRecord("The metering admission record is not admitted.");
                }

                if (!string.Equals(TryReadString(admissionRootElement, "settlement_status"), "not_settled", StringComparison.Ordinal))
                {
                    return FailedMeteringRecord("The metering admission record is already marked with a settlement status other than not_settled.");
                }

                var packageId = TryReadString(admissionRootElement, "package_id");
                var admissionRecordId = TryReadString(admissionRootElement, "record_id");
                var packageRoot = TryReadString(admissionRootElement, "package_root");
                long priorAcceptedProofCount = 0;
                long priorRejectedProofCount = 0;
                long priorVerifiedReplicatedByteSeconds = 0;
                if (admissionRootElement.TryGetProperty("admitted_metering", out var admittedMeteringElement))
                {
                    priorAcceptedProofCount = TryReadInt64(admittedMeteringElement, "accepted_proof_count");
                    priorRejectedProofCount = TryReadInt64(admittedMeteringElement, "rejected_proof_count");
                    priorVerifiedReplicatedByteSeconds = TryReadInt64(admittedMeteringElement, "verified_replicated_byte_seconds");
                }

                var supersedesRecordIds = new List<string> { admissionRecordId };
                var affectedRecords = new List<Dictionary<string, object?>>();
                var auditChallengeRecordId = string.Empty;
                var disputeRecordId = string.Empty;

                if (!string.IsNullOrWhiteSpace(auditChallengeRecordPath) && File.Exists(auditChallengeRecordPath))
                {
                    using var auditDocument = JsonDocument.Parse(File.ReadAllText(auditChallengeRecordPath));
                    var auditRoot = auditDocument.RootElement;
                    if (!string.Equals(TryReadString(auditRoot, "record_type"), "passport_metering_audit_challenge_record", StringComparison.Ordinal))
                    {
                        return FailedMeteringRecord("The supplied audit challenge path is not a Passport metering audit challenge record.");
                    }

                    auditChallengeRecordId = TryReadString(auditRoot, "record_id");
                    supersedesRecordIds.Add(auditChallengeRecordId);
                    affectedRecords = ToAffectedRecords(ReadChallengedRecords(auditRoot, "audit_review"));
                }

                if (!string.IsNullOrWhiteSpace(disputeRecordPath) && File.Exists(disputeRecordPath))
                {
                    using var disputeDocument = JsonDocument.Parse(File.ReadAllText(disputeRecordPath));
                    var disputeRoot = disputeDocument.RootElement;
                    if (!string.Equals(TryReadString(disputeRoot, "record_type"), "passport_metering_dispute_record", StringComparison.Ordinal))
                    {
                        return FailedMeteringRecord("The supplied dispute path is not a Passport metering dispute record.");
                    }

                    if (!string.Equals(TryReadString(disputeRoot, "settlement_status"), "not_settled", StringComparison.Ordinal))
                    {
                        return FailedMeteringRecord("The metering dispute record is already marked with a settlement status other than not_settled.");
                    }

                    disputeRecordId = TryReadString(disputeRoot, "record_id");
                    supersedesRecordIds.Add(disputeRecordId);
                    var disputedRecords = ToAffectedRecords(ReadChallengedRecords(disputeRoot, "dispute_resolution"));
                    if (disputedRecords.Count > 0)
                    {
                        affectedRecords = disputedRecords;
                    }
                }

                if (affectedRecords.Count == 0)
                {
                    if (string.IsNullOrWhiteSpace(packageRoot))
                    {
                        return FailedMeteringRecord("The admission record does not include a package root.");
                    }

                    var resolvedPackageRoot = ResolveWorkspaceRelativePath(resolvedWorkspaceRoot, packageRoot);
                    var manifestPath = Path.Combine(resolvedPackageRoot, "manifest.json");
                    if (!File.Exists(manifestPath))
                    {
                        return FailedMeteringRecord("The admitted package manifest was not found.");
                    }

                    affectedRecords = ToAffectedRecords(SelectAuditChallengeRecords(resolvedPackageRoot, manifestPath));
                }

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var safePackageId = Slugify(packageId);
                if (string.IsNullOrWhiteSpace(safePackageId))
                {
                    safePackageId = "metering-package";
                }

                var recordId = timestamp + "-" + safePackageId + "-correction";
                var recordRoot = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "passport",
                    "metering",
                    "review",
                    "corrections",
                    timestamp + "-" + safePackageId);
                Directory.CreateDirectory(recordRoot);

                var recordPath = Path.Combine(recordRoot, "metering-correction.json");
                var payloadPath = Path.Combine(recordRoot, "metering-correction.payload.json");
                var signaturePath = Path.Combine(recordRoot, "metering-correction.sig");
                var relativePayloadPath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, payloadPath);
                var relativeSignaturePath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, signaturePath);
                var normalizedRegistrarId = string.IsNullOrWhiteSpace(registrarId) ? deviceId : registrarId.Trim();
                var normalizedCorrectionReason = string.IsNullOrWhiteSpace(correctionReason) ? "dispute_resolution" : correctionReason.Trim();

                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_metering_correction_record",
                    ["record_id"] = recordId,
                    ["created_utc"] = createdUtc,
                    ["effective_utc"] = createdUtc,
                    ["status"] = "corrected",
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["registrar_id"] = normalizedRegistrarId,
                    ["admission_record_id"] = admissionRecordId,
                    ["admission_record_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, admissionRecordPath),
                    ["package_id"] = packageId,
                    ["correction_reason"] = normalizedCorrectionReason,
                    ["supersedes_record_ids"] = supersedesRecordIds,
                    ["affected_records"] = affectedRecords,
                    ["prior_metering"] = new Dictionary<string, object?>
                    {
                        ["accepted_proof_count"] = priorAcceptedProofCount,
                        ["rejected_proof_count"] = priorRejectedProofCount,
                        ["verified_replicated_byte_seconds"] = priorVerifiedReplicatedByteSeconds
                    },
                    ["corrected_metering"] = new Dictionary<string, object?>
                    {
                        ["accepted_proof_count"] = Math.Max(0, correctedAcceptedProofCount),
                        ["rejected_proof_count"] = Math.Max(0, correctedRejectedProofCount),
                        ["verified_replicated_byte_seconds"] = Math.Max(0, correctedVerifiedReplicatedByteSeconds)
                    },
                    ["dispute_record_id"] = disputeRecordId,
                    ["dispute_record_path"] = string.IsNullOrWhiteSpace(disputeRecordPath)
                        ? string.Empty
                        : ToWorkspaceRelativePath(resolvedWorkspaceRoot, disputeRecordPath),
                    ["audit_challenge_record_id"] = auditChallengeRecordId,
                    ["audit_challenge_record_path"] = string.IsNullOrWhiteSpace(auditChallengeRecordPath)
                        ? string.Empty
                        : ToWorkspaceRelativePath(resolvedWorkspaceRoot, auditChallengeRecordPath),
                    ["settlement_status"] = "not_settled",
                    ["summary"] = "Signed Passport metering correction that supersedes admitted review totals by reference. This is not payout, wallet, token, redemption, transfer, or blockchain settlement."
                };

                var unsignedPayloadBytes = JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions);
                var signatureBytes = PassportDeviceKeyStore.SignData(deviceKeyReferencePath, unsignedPayloadBytes);
                File.WriteAllBytes(payloadPath, unsignedPayloadBytes);
                File.WriteAllBytes(signaturePath, signatureBytes);

                record["signature"] = new Dictionary<string, object?>
                {
                    ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                    ["signing_device_record_id"] = deviceId,
                    ["signed_payload_path"] = relativePayloadPath,
                    ["signature_path"] = relativeSignaturePath,
                    ["signed_payload_sha256"] = ComputeSha256(unsignedPayloadBytes)
                };

                File.WriteAllText(recordPath, JsonSerializer.Serialize(record, JsonOptions));

                return new PassportMeteringRecordResult
                {
                    Succeeded = true,
                    Message = "Created a signed Passport metering correction record.",
                    RecordType = "passport_metering_correction_record",
                    RecordId = recordId,
                    RecordPath = recordPath,
                    SignaturePath = signaturePath
                };
            }
            catch (Exception ex)
            {
                return FailedMeteringRecord("Metering correction failed: " + ex.Message);
            }
        }

        public PassportMeteringRecordResult CreateMeteringSettlementHandoff(
            string workspaceRoot,
            string identityId,
            string deviceId,
            string deviceKeyReferencePath,
            string admissionRecordPath,
            string auditChallengeRecordPath,
            string disputeRecordPath,
            string correctionRecordPath,
            string registrarId,
            string handoffStatus)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(identityId))
                {
                    return FailedMeteringRecord("An active Passport identity is required before creating a metering settlement handoff.");
                }

                if (string.IsNullOrWhiteSpace(deviceId) || string.IsNullOrWhiteSpace(deviceKeyReferencePath))
                {
                    return FailedMeteringRecord("An active Passport device credential is required before creating a metering settlement handoff.");
                }

                if (!PassportDeviceKeyStore.ReferenceExists(deviceKeyReferencePath))
                {
                    return FailedMeteringRecord("The active Passport device key reference is not available.");
                }

                if (string.IsNullOrWhiteSpace(admissionRecordPath) || !File.Exists(admissionRecordPath))
                {
                    return FailedMeteringRecord("A metering admission record is required before creating a settlement handoff.");
                }

                var resolvedWorkspaceRoot = PassportEnvironment.ResolveWorkspaceRoot(workspaceRoot);
                EnsureRegistryFolders(resolvedWorkspaceRoot);
                EnsureMeteringFolders(resolvedWorkspaceRoot);

                using var admissionDocument = JsonDocument.Parse(File.ReadAllText(admissionRecordPath));
                var admissionRootElement = admissionDocument.RootElement;
                if (!string.Equals(TryReadString(admissionRootElement, "record_type"), "passport_metering_admission_record", StringComparison.Ordinal))
                {
                    return FailedMeteringRecord("The supplied record is not a Passport metering admission record.");
                }

                if (!string.Equals(TryReadString(admissionRootElement, "status"), "admitted", StringComparison.Ordinal))
                {
                    return FailedMeteringRecord("The metering admission record is not admitted.");
                }

                if (!string.Equals(TryReadString(admissionRootElement, "settlement_status"), "not_settled", StringComparison.Ordinal))
                {
                    return FailedMeteringRecord("The metering admission record is already marked with a settlement status other than not_settled.");
                }

                var packageId = TryReadString(admissionRootElement, "package_id");
                var admissionRecordId = TryReadString(admissionRootElement, "record_id");
                long finalAcceptedProofCount = 0;
                long finalRejectedProofCount = 0;
                long finalVerifiedReplicatedByteSeconds = 0;
                if (admissionRootElement.TryGetProperty("admitted_metering", out var admittedMeteringElement))
                {
                    finalAcceptedProofCount = TryReadInt64(admittedMeteringElement, "accepted_proof_count");
                    finalRejectedProofCount = TryReadInt64(admittedMeteringElement, "rejected_proof_count");
                    finalVerifiedReplicatedByteSeconds = TryReadInt64(admittedMeteringElement, "verified_replicated_byte_seconds");
                }

                var auditStatus = string.IsNullOrWhiteSpace(auditChallengeRecordPath) ? "waived" : "complete_or_waived";
                var disputeStatus = string.IsNullOrWhiteSpace(disputeRecordPath) ? "none_open" : "held_for_dispute";
                var correctionRecordIds = new List<string>();
                var excludedRecordIds = new List<string>();

                if (!string.IsNullOrWhiteSpace(auditChallengeRecordPath) && File.Exists(auditChallengeRecordPath))
                {
                    using var auditDocument = JsonDocument.Parse(File.ReadAllText(auditChallengeRecordPath));
                    var auditRoot = auditDocument.RootElement;
                    if (!string.Equals(TryReadString(auditRoot, "record_type"), "passport_metering_audit_challenge_record", StringComparison.Ordinal))
                    {
                        return FailedMeteringRecord("The supplied audit challenge path is not a Passport metering audit challenge record.");
                    }

                    auditStatus = "complete_or_waived";
                }

                if (!string.IsNullOrWhiteSpace(disputeRecordPath) && File.Exists(disputeRecordPath))
                {
                    using var disputeDocument = JsonDocument.Parse(File.ReadAllText(disputeRecordPath));
                    var disputeRoot = disputeDocument.RootElement;
                    if (!string.Equals(TryReadString(disputeRoot, "record_type"), "passport_metering_dispute_record", StringComparison.Ordinal))
                    {
                        return FailedMeteringRecord("The supplied dispute path is not a Passport metering dispute record.");
                    }

                    if (!string.Equals(TryReadString(disputeRoot, "settlement_status"), "not_settled", StringComparison.Ordinal))
                    {
                        return FailedMeteringRecord("The metering dispute record is already marked with a settlement status other than not_settled.");
                    }

                    disputeStatus = "held_for_dispute";
                }

                if (!string.IsNullOrWhiteSpace(correctionRecordPath) && File.Exists(correctionRecordPath))
                {
                    using var correctionDocument = JsonDocument.Parse(File.ReadAllText(correctionRecordPath));
                    var correctionRoot = correctionDocument.RootElement;
                    if (!string.Equals(TryReadString(correctionRoot, "record_type"), "passport_metering_correction_record", StringComparison.Ordinal))
                    {
                        return FailedMeteringRecord("The supplied correction path is not a Passport metering correction record.");
                    }

                    if (!string.Equals(TryReadString(correctionRoot, "settlement_status"), "not_settled", StringComparison.Ordinal))
                    {
                        return FailedMeteringRecord("The metering correction record is already marked with a settlement status other than not_settled.");
                    }

                    var correctionRecordId = TryReadString(correctionRoot, "record_id");
                    if (!string.IsNullOrWhiteSpace(correctionRecordId))
                    {
                        correctionRecordIds.Add(correctionRecordId);
                    }

                    if (correctionRoot.TryGetProperty("corrected_metering", out var correctedMeteringElement))
                    {
                        finalAcceptedProofCount = TryReadInt64(correctedMeteringElement, "accepted_proof_count");
                        finalRejectedProofCount = TryReadInt64(correctedMeteringElement, "rejected_proof_count");
                        finalVerifiedReplicatedByteSeconds = TryReadInt64(correctedMeteringElement, "verified_replicated_byte_seconds");
                    }

                    if (correctionRoot.TryGetProperty("affected_records", out var affectedRecordsElement)
                        && affectedRecordsElement.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var affectedRecordElement in affectedRecordsElement.EnumerateArray())
                        {
                            var affectedRecordId = TryReadString(affectedRecordElement, "record_id");
                            if (!string.IsNullOrWhiteSpace(affectedRecordId))
                            {
                                excludedRecordIds.Add(affectedRecordId);
                            }
                        }
                    }

                    disputeStatus = string.IsNullOrWhiteSpace(disputeRecordPath) ? "none_open" : "resolved_by_correction";
                    auditStatus = string.IsNullOrWhiteSpace(auditChallengeRecordPath) ? "waived" : "complete_or_waived";
                }

                var normalizedHandoffStatus = string.IsNullOrWhiteSpace(handoffStatus)
                    ? "eligible_for_settlement_review"
                    : handoffStatus.Trim();
                if (string.Equals(disputeStatus, "held_for_dispute", StringComparison.Ordinal)
                    && string.Equals(normalizedHandoffStatus, "eligible_for_settlement_review", StringComparison.Ordinal))
                {
                    normalizedHandoffStatus = "held_for_dispute";
                }

                var timestamp = DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ");
                var createdUtc = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ");
                var safePackageId = Slugify(packageId);
                if (string.IsNullOrWhiteSpace(safePackageId))
                {
                    safePackageId = "metering-package";
                }

                var recordId = timestamp + "-" + safePackageId + "-settlement-handoff";
                var recordRoot = Path.Combine(
                    resolvedWorkspaceRoot,
                    "records",
                    "passport",
                    "metering",
                    "review",
                    "settlement-handoffs",
                    timestamp + "-" + safePackageId);
                Directory.CreateDirectory(recordRoot);

                var recordPath = Path.Combine(recordRoot, "metering-settlement-handoff.json");
                var payloadPath = Path.Combine(recordRoot, "metering-settlement-handoff.payload.json");
                var signaturePath = Path.Combine(recordRoot, "metering-settlement-handoff.sig");
                var relativePayloadPath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, payloadPath);
                var relativeSignaturePath = ToWorkspaceRelativePath(resolvedWorkspaceRoot, signaturePath);
                var normalizedRegistrarId = string.IsNullOrWhiteSpace(registrarId) ? deviceId : registrarId.Trim();

                var record = new Dictionary<string, object?>
                {
                    ["schema_version"] = 1,
                    ["record_type"] = "passport_metering_settlement_handoff_record",
                    ["record_id"] = recordId,
                    ["created_utc"] = createdUtc,
                    ["effective_utc"] = createdUtc,
                    ["status"] = normalizedHandoffStatus,
                    ["archrealms_identity_id"] = identityId,
                    ["device_id"] = deviceId,
                    ["registrar_id"] = normalizedRegistrarId,
                    ["policy_version"] = "metering-admission-policy-2026-04-27",
                    ["admission_record_id"] = admissionRecordId,
                    ["admission_record_path"] = ToWorkspaceRelativePath(resolvedWorkspaceRoot, admissionRecordPath),
                    ["package_id"] = packageId,
                    ["audit_status"] = auditStatus,
                    ["audit_challenge_record_path"] = string.IsNullOrWhiteSpace(auditChallengeRecordPath)
                        ? string.Empty
                        : ToWorkspaceRelativePath(resolvedWorkspaceRoot, auditChallengeRecordPath),
                    ["dispute_status"] = disputeStatus,
                    ["dispute_record_path"] = string.IsNullOrWhiteSpace(disputeRecordPath)
                        ? string.Empty
                        : ToWorkspaceRelativePath(resolvedWorkspaceRoot, disputeRecordPath),
                    ["correction_record_ids"] = correctionRecordIds,
                    ["correction_record_path"] = string.IsNullOrWhiteSpace(correctionRecordPath)
                        ? string.Empty
                        : ToWorkspaceRelativePath(resolvedWorkspaceRoot, correctionRecordPath),
                    ["excluded_record_ids"] = excludedRecordIds,
                    ["final_metering"] = new Dictionary<string, object?>
                    {
                        ["accepted_proof_count"] = Math.Max(0, finalAcceptedProofCount),
                        ["rejected_proof_count"] = Math.Max(0, finalRejectedProofCount),
                        ["verified_replicated_byte_seconds"] = Math.Max(0, finalVerifiedReplicatedByteSeconds),
                        ["verified_retrieval_bytes"] = 0,
                        ["verified_repair_bytes"] = 0
                    },
                    ["handoff_status"] = normalizedHandoffStatus,
                    ["target_settlement_layer"] = new Dictionary<string, object?>
                    {
                        ["settlement_rail"] = "blockchain",
                        ["chain_id"] = string.Empty,
                        ["settlement_contract"] = string.Empty,
                        ["settlement_method"] = string.Empty,
                        ["finality_rule"] = string.Empty
                    },
                    ["settlement_status"] = "not_settled",
                    ["settlement_record_id"] = string.Empty,
                    ["summary"] = "Signed Passport metering settlement handoff input for future blockchain settlement review. This is not payout, wallet, token, redemption, transfer, or final settlement."
                };

                var unsignedPayloadBytes = JsonSerializer.SerializeToUtf8Bytes(record, JsonOptions);
                var signatureBytes = PassportDeviceKeyStore.SignData(deviceKeyReferencePath, unsignedPayloadBytes);
                File.WriteAllBytes(payloadPath, unsignedPayloadBytes);
                File.WriteAllBytes(signaturePath, signatureBytes);

                record["signature"] = new Dictionary<string, object?>
                {
                    ["signature_algorithm"] = "RSA_PKCS1_SHA256",
                    ["signing_device_record_id"] = deviceId,
                    ["signed_payload_path"] = relativePayloadPath,
                    ["signature_path"] = relativeSignaturePath,
                    ["signed_payload_sha256"] = ComputeSha256(unsignedPayloadBytes)
                };

                File.WriteAllText(recordPath, JsonSerializer.Serialize(record, JsonOptions));

                return new PassportMeteringRecordResult
                {
                    Succeeded = true,
                    Message = "Created a signed Passport metering settlement handoff record.",
                    RecordType = "passport_metering_settlement_handoff_record",
                    RecordId = recordId,
                    RecordPath = recordPath,
                    SignaturePath = signaturePath
                };
            }
            catch (Exception ex)
            {
                return FailedMeteringRecord("Metering settlement handoff failed: " + ex.Message);
            }
        }

        private static void EnsureRegistryFolders(string workspaceRoot)
        {
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "registry", "identities"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "registry", "device-credentials"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "registry", "public-keys"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "registry", "join-requests"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "registry", "join-approvals"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "registry", "device-authorizations"));
        }

        private static void EnsureMeteringFolders(string workspaceRoot)
        {
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "passport", "node-activity"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "passport", "metering", "proofs"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "passport", "metering", "submissions"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "passport", "metering", "status"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "passport", "metering", "admissions"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "passport", "metering", "review", "audit-challenges"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "passport", "metering", "review", "disputes"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "passport", "metering", "review", "corrections"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "passport", "metering", "review", "settlement-handoffs"));
            Directory.CreateDirectory(Path.Combine(workspaceRoot, "records", "passport", "settlement", "read-only"));
        }

        private static Dictionary<string, object?> CreateDeviceCredentialRecord(
            string workspaceRoot,
            string timestamp,
            string createdUtc,
            string identityId,
            string deviceId,
            string normalizedDeviceLabel,
            string publicKeyPath,
            byte[] publicKeyBytes,
            string status,
            string authorizationMode,
            string authorizationPackagePath,
            string authorizationRecordPath,
            string authorizerDeviceId)
        {
            return new Dictionary<string, object?>
            {
                ["schema_version"] = 1,
                ["record_type"] = "device_credential_record",
                ["record_id"] = timestamp + "-" + deviceId,
                ["created_utc"] = createdUtc,
                ["effective_utc"] = createdUtc,
                ["status"] = status,
                ["archrealms_identity_id"] = identityId,
                ["device_id"] = deviceId,
                ["device_label"] = normalizedDeviceLabel,
                ["device_class"] = "desktop",
                ["client_platform"] = "windows",
                ["credential_origin"] = "passport-windows",
                ["public_key_algorithm"] = "RSA",
                ["public_key_format"] = "SPKI_DER",
                ["public_key_path"] = ToWorkspaceRelativePath(workspaceRoot, publicKeyPath),
                ["public_key_sha256"] = ComputeSha256(publicKeyBytes),
                ["authorized_scopes"] = new[]
                {
                    "authenticate",
                    "submit_registry_record",
                    "publish_archive"
                },
                ["authorization_mode"] = authorizationMode,
                ["authorization_package_path"] = authorizationPackagePath,
                ["authorization_record_path"] = authorizationRecordPath,
                ["authorizer_device_id"] = authorizerDeviceId,
                ["expires_utc"] = string.Empty,
                ["revocation_record_id"] = string.Empty,
                ["attestation_refs"] = Array.Empty<string>()
            };
        }

        private static string NormalizeDeviceLabel(string deviceLabel)
        {
            return string.IsNullOrWhiteSpace(deviceLabel)
                ? Environment.MachineName
                : deviceLabel.Trim();
        }

        private static string WritePublicKey(string workspaceRoot, string deviceId, byte[] publicKeyBytes)
        {
            var publicKeyPath = Path.Combine(workspaceRoot, "records", "registry", "public-keys", deviceId + ".spki.der");
            File.WriteAllBytes(publicKeyPath, publicKeyBytes);
            return publicKeyPath;
        }

        private static PassportProvisioningResult FailedProvisioning(string message)
        {
            return new PassportProvisioningResult
            {
                Succeeded = false,
                Message = message
            };
        }

        private static PassportJoinRequestResult FailedJoinRequest(string message)
        {
            return new PassportJoinRequestResult
            {
                Succeeded = false,
                Message = message
            };
        }

        private static PassportMeteringRecordResult FailedMeteringRecord(string message)
        {
            return new PassportMeteringRecordResult
            {
                Succeeded = false,
                Message = message
            };
        }

        private static string CreateIdentityId(string displayName)
        {
            return "passport-" + Guid.NewGuid().ToString("N").Substring(0, 10);
        }

        private static string CreateDeviceId(string deviceLabel)
        {
            return "device-" + Guid.NewGuid().ToString("N").Substring(0, 10);
        }

        private static string NormalizeNodeId(string nodeId, string deviceId)
        {
            if (!string.IsNullOrWhiteSpace(nodeId))
            {
                return nodeId.Trim();
            }

            return string.IsNullOrWhiteSpace(deviceId)
                ? "node-local-" + Guid.NewGuid().ToString("N").Substring(0, 10)
                : "node-" + deviceId;
        }

        private static string NormalizeNodeParticipationMode(string value)
        {
            if (string.Equals(value, "Read-only cache", StringComparison.Ordinal)
                || string.Equals(value, "Public archive contributor", StringComparison.Ordinal)
                || string.Equals(value, "Steward reserve", StringComparison.Ordinal))
            {
                return value;
            }

            return "Public archive contributor";
        }

        private static string NormalizeNodeCachePolicy(string value)
        {
            if (string.Equals(value, "Conservative cache", StringComparison.Ordinal)
                || string.Equals(value, "Balanced pinned archive", StringComparison.Ordinal)
                || string.Equals(value, "Archive-first reserve", StringComparison.Ordinal))
            {
                return value;
            }

            return "Balanced pinned archive";
        }

        private static string[] BuildParticipationScopes(string participationMode)
        {
            if (string.Equals(participationMode, "Read-only cache", StringComparison.Ordinal))
            {
                return new[] { "public_archive_read", "submission_publication" };
            }

            if (string.Equals(participationMode, "Steward reserve", StringComparison.Ordinal))
            {
                return new[] { "public_archive_read", "submission_publication", "storage_contributor", "continuity_reserve" };
            }

            return new[] { "public_archive_read", "submission_publication", "storage_contributor" };
        }

        private static string NormalizeDisplayName(string displayName, string identityMode, string identityId)
        {
            if (!string.IsNullOrWhiteSpace(displayName))
            {
                return displayName.Trim();
            }

            if (string.Equals(identityMode, "anonymous", StringComparison.OrdinalIgnoreCase))
            {
                return "Anonymous " + identityId.Substring(Math.Max(0, identityId.Length - 6));
            }

            return "Passport " + identityId.Substring(Math.Max(0, identityId.Length - 6));
        }

        private static string Slugify(string value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return string.Empty;
            }

            var builder = new StringBuilder();
            foreach (var character in value.Trim().ToLowerInvariant())
            {
                if (char.IsLetterOrDigit(character))
                {
                    builder.Append(character);
                }
                else if (builder.Length > 0 && builder[builder.Length - 1] != '-')
                {
                    builder.Append('-');
                }
            }

            return builder.ToString().Trim('-');
        }

        private static string ComputeSha256(byte[] value)
        {
            using (var sha256 = SHA256.Create())
            {
                var hash = sha256.ComputeHash(value);
                var builder = new StringBuilder(hash.Length * 2);
                foreach (var b in hash)
                {
                    builder.Append(b.ToString("x2"));
                }

                return builder.ToString();
            }
        }

        private static long TryGetAvailableBytes(string path)
        {
            try
            {
                var root = Path.GetPathRoot(Path.GetFullPath(path));
                if (string.IsNullOrWhiteSpace(root))
                {
                    return 0;
                }

                return new DriveInfo(root).AvailableFreeSpace;
            }
            catch
            {
                return 0;
            }
        }

        private static long TryGetDirectorySize(string path)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path))
                {
                    return 0;
                }

                long total = 0;
                foreach (var file in Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories))
                {
                    try
                    {
                        total += new FileInfo(file).Length;
                    }
                    catch
                    {
                    }
                }

                return total;
            }
            catch
            {
                return 0;
            }
        }

        private static long[] SelectSegmentOffsets(string challengeSeedSha256, long fileLength)
        {
            if (fileLength <= 0)
            {
                return Array.Empty<long>();
            }

            var maxOffset = Math.Max(0, fileLength - 1);
            var seedBytes = Convert.FromHexString(challengeSeedSha256);
            var count = fileLength < 4096 ? 1 : Math.Min(4, Math.Max(1, (int)(fileLength / 4096)));
            var offsets = new List<long>();

            for (var i = 0; i < count; i++)
            {
                var start = (i * 8) % seedBytes.Length;
                var buffer = new byte[8];
                for (var j = 0; j < buffer.Length; j++)
                {
                    buffer[j] = seedBytes[(start + j) % seedBytes.Length];
                }

                var raw = BitConverter.ToUInt64(buffer, 0);
                offsets.Add((long)(raw % (ulong)(maxOffset + 1)));
            }

            offsets.Sort();
            return offsets.ToArray();
        }

        private static SegmentProofResponse ComputeSegmentProofResponse(string filePath, IReadOnlyList<long> segmentOffsets)
        {
            const int SegmentLength = 4096;
            using var output = new MemoryStream();
            using var stream = File.OpenRead(filePath);
            var buffer = new byte[SegmentLength];
            long provedBytes = 0;

            foreach (var offset in segmentOffsets)
            {
                stream.Seek(Math.Max(0, Math.Min(offset, Math.Max(0, stream.Length - 1))), SeekOrigin.Begin);
                var read = stream.Read(buffer, 0, (int)Math.Min(SegmentLength, stream.Length - stream.Position));
                if (read <= 0)
                {
                    continue;
                }

                output.Write(buffer, 0, read);
                provedBytes += read;
            }

            return new SegmentProofResponse
            {
                ProvedBytes = provedBytes,
                ResponseSha256 = ComputeSha256(output.ToArray())
            };
        }

        private static string ComputeFileSha256(string filePath)
        {
            using var sha256 = SHA256.Create();
            using var stream = File.OpenRead(filePath);
            var hash = sha256.ComputeHash(stream);
            var builder = new StringBuilder(hash.Length * 2);
            foreach (var b in hash)
            {
                builder.Append(b.ToString("x2"));
            }

            return builder.ToString();
        }

        private static long TryReadInt64(JsonElement element, string propertyName)
        {
            try
            {
                if (!element.TryGetProperty(propertyName, out var property))
                {
                    return 0;
                }

                if (property.ValueKind == JsonValueKind.Number && property.TryGetInt64(out var number))
                {
                    return number;
                }

                if (property.ValueKind == JsonValueKind.String && long.TryParse(property.GetString(), out var parsed))
                {
                    return parsed;
                }
            }
            catch
            {
            }

            return 0;
        }

        private static List<Dictionary<string, object?>> SelectAuditChallengeRecords(string packageRoot, string manifestPath)
        {
            var selected = new List<Dictionary<string, object?>>();

            using var manifestDocument = JsonDocument.Parse(File.ReadAllText(manifestPath));
            var manifestRoot = manifestDocument.RootElement;
            if (!manifestRoot.TryGetProperty("source_records", out var sourceRecordsElement)
                || sourceRecordsElement.ValueKind != JsonValueKind.Array)
            {
                return selected;
            }

            foreach (var sourceRecord in sourceRecordsElement.EnumerateArray())
            {
                var recordType = TryReadString(sourceRecord, "record_type");
                if (!string.Equals(recordType, "storage_epoch_proof_record", StringComparison.Ordinal))
                {
                    continue;
                }

                var packageRecordPath = TryReadString(sourceRecord, "record_path");
                if (string.IsNullOrWhiteSpace(packageRecordPath))
                {
                    continue;
                }

                var resolvedRecordPath = ResolvePackageRelativePath(packageRoot, packageRecordPath);
                var recordId = TryReadString(sourceRecord, "record_id");
                if (File.Exists(resolvedRecordPath))
                {
                    try
                    {
                        using var recordDocument = JsonDocument.Parse(File.ReadAllText(resolvedRecordPath));
                        recordId = TryReadString(recordDocument.RootElement, "record_id");
                    }
                    catch
                    {
                    }
                }

                selected.Add(new Dictionary<string, object?>
                {
                    ["record_type"] = recordType,
                    ["record_id"] = recordId,
                    ["record_path"] = packageRecordPath.Replace(Path.DirectorySeparatorChar, '/'),
                    ["requested_evidence"] = "payload_signature_and_source_assignment"
                });
                break;
            }

            return selected;
        }

        private static List<Dictionary<string, object?>> ReadChallengedRecords(JsonElement root, string challengeReason)
        {
            var challengedRecords = new List<Dictionary<string, object?>>();
            if (!root.TryGetProperty("challenged_records", out var challengedRecordsElement)
                || challengedRecordsElement.ValueKind != JsonValueKind.Array)
            {
                return challengedRecords;
            }

            foreach (var challengedRecordElement in challengedRecordsElement.EnumerateArray())
            {
                var recordType = TryReadString(challengedRecordElement, "record_type");
                var recordId = TryReadString(challengedRecordElement, "record_id");
                var recordPath = TryReadString(challengedRecordElement, "record_path");
                if (string.IsNullOrWhiteSpace(recordType) && string.IsNullOrWhiteSpace(recordId) && string.IsNullOrWhiteSpace(recordPath))
                {
                    continue;
                }

                var normalizedChallengeReason = TryReadString(challengedRecordElement, "challenge_reason");
                if (string.IsNullOrWhiteSpace(normalizedChallengeReason))
                {
                    normalizedChallengeReason = challengeReason;
                }

                challengedRecords.Add(new Dictionary<string, object?>
                {
                    ["record_type"] = recordType,
                    ["record_id"] = recordId,
                    ["record_path"] = recordPath.Replace(Path.DirectorySeparatorChar, '/'),
                    ["challenge_reason"] = normalizedChallengeReason
                });
            }

            return challengedRecords;
        }

        private static List<Dictionary<string, object?>> ToAffectedRecords(IReadOnlyList<Dictionary<string, object?>> challengedRecords)
        {
            var affectedRecords = new List<Dictionary<string, object?>>();
            foreach (var challengedRecord in challengedRecords)
            {
                var recordTypeValue = challengedRecord.TryGetValue("record_type", out var recordType) ? recordType?.ToString() ?? string.Empty : string.Empty;
                var recordIdValue = challengedRecord.TryGetValue("record_id", out var recordId) ? recordId?.ToString() ?? string.Empty : string.Empty;
                var recordPathValue = challengedRecord.TryGetValue("record_path", out var recordPath) ? recordPath?.ToString() ?? string.Empty : string.Empty;
                affectedRecords.Add(new Dictionary<string, object?>
                {
                    ["record_type"] = recordTypeValue,
                    ["record_id"] = recordIdValue,
                    ["record_path"] = recordPathValue
                });
            }

            return affectedRecords;
        }

        private static string ResolvePackageRelativePath(string packageRoot, string path)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                return string.Empty;
            }

            var normalized = path.Replace('/', Path.DirectorySeparatorChar);
            return Path.IsPathRooted(normalized)
                ? Path.GetFullPath(normalized)
                : Path.GetFullPath(Path.Combine(packageRoot, normalized));
        }

        private static string TryReadString(JsonElement element, string propertyName)
        {
            try
            {
                if (!element.TryGetProperty(propertyName, out var property))
                {
                    return string.Empty;
                }

                if (property.ValueKind == JsonValueKind.String)
                {
                    return property.GetString() ?? string.Empty;
                }

                return property.ToString();
            }
            catch
            {
                return string.Empty;
            }
        }

        private static bool TryReadBoolean(JsonElement element, string propertyName)
        {
            try
            {
                if (!element.TryGetProperty(propertyName, out var property))
                {
                    return false;
                }

                if (property.ValueKind == JsonValueKind.True)
                {
                    return true;
                }

                if (property.ValueKind == JsonValueKind.False)
                {
                    return false;
                }

                if (property.ValueKind == JsonValueKind.String && bool.TryParse(property.GetString(), out var parsed))
                {
                    return parsed;
                }
            }
            catch
            {
            }

            return false;
        }

        private static IEnumerable<string> EnumerateLocalSignedMeteringRecords(string workspaceRoot)
        {
            var candidates = new[]
            {
                Path.Combine(workspaceRoot, "records", "passport", "node-activity"),
                Path.Combine(workspaceRoot, "records", "passport", "metering", "submissions"),
                Path.Combine(workspaceRoot, "records", "passport", "metering", "proofs")
            };

            foreach (var candidateRoot in candidates)
            {
                if (!Directory.Exists(candidateRoot))
                {
                    continue;
                }

                foreach (var file in Directory.EnumerateFiles(candidateRoot, "*.json", SearchOption.AllDirectories))
                {
                    var fileName = Path.GetFileName(file);
                    if (fileName.EndsWith(".payload.json", StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }

                    yield return file;
                }
            }
        }

        private static Dictionary<string, object?> VerifyLocalSignedMeteringRecord(
            string workspaceRoot,
            string recordPath,
            string identityId,
            string deviceId,
            byte[] publicKeyBytes)
        {
            var result = new Dictionary<string, object?>
            {
                ["record_path"] = ToWorkspaceRelativePath(workspaceRoot, recordPath),
                ["record_type"] = string.Empty,
                ["record_id"] = string.Empty,
                ["verification_status"] = "failed",
                ["reason"] = string.Empty
            };

            try
            {
                using var document = JsonDocument.Parse(File.ReadAllText(recordPath));
                var root = document.RootElement;
                var recordType = root.TryGetProperty("record_type", out var recordTypeElement)
                    ? recordTypeElement.GetString() ?? string.Empty
                    : string.Empty;
                var recordId = root.TryGetProperty("record_id", out var recordIdElement)
                    ? recordIdElement.GetString() ?? string.Empty
                    : string.Empty;

                result["record_type"] = recordType;
                result["record_id"] = recordId;

                if (!IsLocalSignedMeteringRecordType(recordType))
                {
                    result["verification_status"] = "skipped";
                    result["reason"] = "not_a_signed_metering_record";
                    return result;
                }

                if (root.TryGetProperty("archrealms_identity_id", out var identityElement)
                    && !string.Equals(identityElement.GetString(), identityId, StringComparison.OrdinalIgnoreCase))
                {
                    result["verification_status"] = "skipped";
                    result["reason"] = "different_identity";
                    return result;
                }

                if (root.TryGetProperty("device_id", out var deviceElement)
                    && !string.Equals(deviceElement.GetString(), deviceId, StringComparison.OrdinalIgnoreCase))
                {
                    result["verification_status"] = "skipped";
                    result["reason"] = "different_device";
                    return result;
                }

                if (!root.TryGetProperty("signature", out var signatureElement))
                {
                    result["verification_status"] = "skipped";
                    result["reason"] = "missing_signature";
                    return result;
                }

                var payloadRelativePath = signatureElement.TryGetProperty("signed_payload_path", out var payloadPathElement)
                    ? payloadPathElement.GetString() ?? string.Empty
                    : string.Empty;
                var signatureRelativePath = signatureElement.TryGetProperty("signature_path", out var signaturePathElement)
                    ? signaturePathElement.GetString() ?? string.Empty
                    : string.Empty;
                var expectedPayloadSha256 = signatureElement.TryGetProperty("signed_payload_sha256", out var hashElement)
                    ? hashElement.GetString() ?? string.Empty
                    : string.Empty;

                if (string.IsNullOrWhiteSpace(payloadRelativePath))
                {
                    result["verification_status"] = "skipped";
                    result["reason"] = "missing_signed_payload_path";
                    return result;
                }

                var payloadPath = ResolveWorkspaceRelativePath(workspaceRoot, payloadRelativePath);
                var signaturePath = ResolveWorkspaceRelativePath(workspaceRoot, signatureRelativePath);

                if (!File.Exists(payloadPath))
                {
                    result["reason"] = "signed_payload_not_found";
                    return result;
                }

                if (!File.Exists(signaturePath))
                {
                    result["reason"] = "signature_not_found";
                    return result;
                }

                var payloadBytes = File.ReadAllBytes(payloadPath);
                var actualPayloadSha256 = ComputeSha256(payloadBytes);
                if (!string.Equals(actualPayloadSha256, expectedPayloadSha256, StringComparison.OrdinalIgnoreCase))
                {
                    result["reason"] = "signed_payload_hash_mismatch";
                    result["actual_signed_payload_sha256"] = actualPayloadSha256;
                    return result;
                }

                var signatureBytes = File.ReadAllBytes(signaturePath);
                using var rsa = RSA.Create();
                rsa.ImportSubjectPublicKeyInfo(publicKeyBytes, out _);
                var verified = rsa.VerifyData(payloadBytes, signatureBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                if (!verified)
                {
                    result["reason"] = "signature_verification_failed";
                    return result;
                }

                result["verification_status"] = "verified";
                result["reason"] = "payload_hash_and_signature_verified";
                result["signed_payload_sha256"] = actualPayloadSha256;
                return result;
            }
            catch (Exception ex)
            {
                result["reason"] = "verification_exception: " + ex.Message;
                return result;
            }
        }

        private static bool IsLocalSignedMeteringRecordType(string recordType)
        {
            return string.Equals(recordType, "node_capacity_snapshot_record", StringComparison.Ordinal)
                || string.Equals(recordType, "storage_assignment_acknowledgment_record", StringComparison.Ordinal)
                || string.Equals(recordType, "storage_epoch_proof_record", StringComparison.Ordinal);
        }

        private static string ResolveWorkspaceRelativePath(string workspaceRoot, string path)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                return string.Empty;
            }

            var normalized = path.Replace('/', Path.DirectorySeparatorChar);
            return Path.IsPathRooted(normalized)
                ? Path.GetFullPath(normalized)
                : Path.GetFullPath(Path.Combine(workspaceRoot, normalized));
        }

        private sealed class SegmentProofResponse
        {
            public long ProvedBytes { get; set; }

            public string ResponseSha256 { get; set; } = string.Empty;
        }

        private static string ToWorkspaceRelativePath(string workspaceRoot, string path)
        {
            var normalizedRoot = Path.GetFullPath(workspaceRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var normalizedPath = Path.GetFullPath(path);

            if (normalizedPath.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase))
            {
                var relative = normalizedPath.Substring(normalizedRoot.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                return relative.Replace(Path.DirectorySeparatorChar, '/');
            }

            return path.Replace(Path.DirectorySeparatorChar, '/');
        }
    }
}
