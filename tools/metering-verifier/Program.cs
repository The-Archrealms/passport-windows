using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;

namespace Archrealms.MeteringVerifier;

internal static class Program
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length < 1)
            {
                Console.Error.WriteLine("Usage: Archrealms.MeteringVerifier <workspace-root> [output-path]");
                return 1;
            }

            var workspaceRoot = Path.GetFullPath(args[0]);
            var outputPath = args.Length > 1 && !string.IsNullOrWhiteSpace(args[1])
                ? Path.GetFullPath(args[1])
                : Path.Combine(workspaceRoot, "records", "passport", "metering", "status", "authoritative-metering-report.json");

            if (!Directory.Exists(workspaceRoot))
            {
                throw new DirectoryNotFoundException("Workspace root not found: " + workspaceRoot);
            }

            var checkedRecords = new List<Dictionary<string, object?>>();
            var acceptedProofCount = 0;
            var rejectedProofCount = 0;
            long acceptedReplicatedByteSeconds = 0;
            long acceptedStorageBytes = 0;

            foreach (var recordPath in EnumerateSignedMeteringRecords(workspaceRoot))
            {
                var result = VerifyRecord(workspaceRoot, recordPath);
                checkedRecords.Add(result.Report);

                if (result.IsStorageProof)
                {
                    if (result.Accepted)
                    {
                        acceptedProofCount++;
                        acceptedReplicatedByteSeconds += result.ClaimedReplicatedByteSeconds;
                        acceptedStorageBytes += result.ClaimedStorageBytes;
                    }
                    else
                    {
                        rejectedProofCount++;
                    }
                }
            }

            var report = new Dictionary<string, object?>
            {
                ["verified_utc"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                ["workspace_root"] = workspaceRoot,
                ["metering_authority"] = "archrealms-metering-verifier-local-v1",
                ["accepted_proof_count"] = acceptedProofCount,
                ["rejected_proof_count"] = rejectedProofCount,
                ["verified_replicated_byte_seconds"] = acceptedReplicatedByteSeconds,
                ["verified_storage_bytes"] = acceptedStorageBytes,
                ["settlement_status"] = "not_settled",
                ["records"] = checkedRecords,
                ["summary"] = "Authoritative local metering verification report. This accepts or rejects submitted proof records for metering only; it does not create payout, wallet balance, token, redemption, or settlement."
            };

            var outputDirectory = Path.GetDirectoryName(outputPath);
            if (!string.IsNullOrWhiteSpace(outputDirectory))
            {
                Directory.CreateDirectory(outputDirectory);
            }

            File.WriteAllText(outputPath, JsonSerializer.Serialize(report, JsonOptions) + Environment.NewLine);

            Console.WriteLine();
            Console.WriteLine("Archrealms metering verification recorded:");
            Console.WriteLine("  Workspace       : " + workspaceRoot);
            Console.WriteLine("  Report          : " + outputPath);
            Console.WriteLine("  Accepted proofs : " + acceptedProofCount);
            Console.WriteLine("  Rejected proofs : " + rejectedProofCount);
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }

    private static IEnumerable<string> EnumerateSignedMeteringRecords(string workspaceRoot)
    {
        var roots = new[]
        {
            Path.Combine(workspaceRoot, "records", "passport", "node-activity"),
            Path.Combine(workspaceRoot, "records", "passport", "metering", "submissions"),
            Path.Combine(workspaceRoot, "records", "passport", "metering", "proofs")
        };

        foreach (var root in roots)
        {
            if (!Directory.Exists(root))
            {
                continue;
            }

            foreach (var file in Directory.EnumerateFiles(root, "*.json", SearchOption.AllDirectories))
            {
                if (!Path.GetFileName(file).EndsWith(".payload.json", StringComparison.OrdinalIgnoreCase))
                {
                    yield return file;
                }
            }
        }
    }

    private static VerificationResult VerifyRecord(string workspaceRoot, string recordPath)
    {
        var report = new Dictionary<string, object?>
        {
            ["record_path"] = ToWorkspaceRelativePath(workspaceRoot, recordPath),
            ["record_type"] = "",
            ["record_id"] = "",
            ["accepted"] = false,
            ["reason"] = ""
        };

        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(recordPath));
            var root = document.RootElement;
            var recordType = GetString(root, "record_type");
            var recordId = GetString(root, "record_id");
            var deviceId = GetString(root, "device_id");

            report["record_type"] = recordType;
            report["record_id"] = recordId;
            report["device_id"] = deviceId;

            if (!IsSignedMeteringRecordType(recordType))
            {
                report["reason"] = "unsupported_record_type";
                return new VerificationResult(report, false, false, 0, 0);
            }

            if (!root.TryGetProperty("signature", out var signature))
            {
                report["reason"] = "missing_signature";
                return new VerificationResult(report, false, IsStorageProof(recordType), 0, 0);
            }

            var payloadPath = ResolveWorkspaceRelativePath(workspaceRoot, GetString(signature, "signed_payload_path"));
            var signaturePath = ResolveWorkspaceRelativePath(workspaceRoot, GetString(signature, "signature_path"));
            var expectedPayloadSha256 = GetString(signature, "signed_payload_sha256");
            var publicKeyPath = Path.Combine(workspaceRoot, "records", "registry", "public-keys", deviceId + ".spki.der");

            if (!File.Exists(payloadPath))
            {
                report["reason"] = "signed_payload_not_found";
                return new VerificationResult(report, false, IsStorageProof(recordType), 0, 0);
            }

            if (!File.Exists(signaturePath))
            {
                report["reason"] = "signature_not_found";
                return new VerificationResult(report, false, IsStorageProof(recordType), 0, 0);
            }

            if (!File.Exists(publicKeyPath))
            {
                report["reason"] = "device_public_key_not_found";
                return new VerificationResult(report, false, IsStorageProof(recordType), 0, 0);
            }

            var payloadBytes = File.ReadAllBytes(payloadPath);
            var actualPayloadSha256 = ComputeSha256(payloadBytes);
            if (!string.Equals(actualPayloadSha256, expectedPayloadSha256, StringComparison.OrdinalIgnoreCase))
            {
                report["reason"] = "signed_payload_hash_mismatch";
                report["actual_signed_payload_sha256"] = actualPayloadSha256;
                return new VerificationResult(report, false, IsStorageProof(recordType), 0, 0);
            }

            if (!VerifySignature(publicKeyPath, payloadBytes, File.ReadAllBytes(signaturePath)))
            {
                report["reason"] = "signature_verification_failed";
                return new VerificationResult(report, false, IsStorageProof(recordType), 0, 0);
            }

            using var payloadDocument = JsonDocument.Parse(payloadBytes);
            var signedRoot = payloadDocument.RootElement;
            if (!string.Equals(GetString(signedRoot, "record_id"), recordId, StringComparison.Ordinal))
            {
                report["reason"] = "signed_payload_record_id_mismatch";
                return new VerificationResult(report, false, IsStorageProof(recordType), 0, 0);
            }

            long claimedReplicatedByteSeconds = 0;
            long claimedStorageBytes = 0;
            if (signedRoot.TryGetProperty("metering_claim", out var claim))
            {
                claimedReplicatedByteSeconds = GetInt64(claim, "claimed_replicated_byte_seconds");
                claimedStorageBytes = GetInt64(claim, "claimed_storage_bytes");
            }

            var accepted = true;
            var reason = "payload_hash_and_signature_verified";

            if (IsStorageProof(recordType))
            {
                accepted = HasAcceptedStorageProofPackage(signedRoot, out reason);
                if (signedRoot.TryGetProperty("delivery_metering", out var deliveryMetering))
                {
                    report["verified_gb_days"] = GetInt64(deliveryMetering, "verified_gb_days");
                }

                if (signedRoot.TryGetProperty("proof_response", out var proofResponse))
                {
                    report["proved_bytes"] = GetInt64(proofResponse, "proved_bytes");
                }

                if (signedRoot.TryGetProperty("retrieval_response", out var retrievalResponse))
                {
                    report["retrieved_bytes"] = GetInt64(retrievalResponse, "retrieved_bytes");
                }
            }

            report["accepted"] = accepted;
            report["reason"] = reason;
            report["signed_payload_sha256"] = actualPayloadSha256;
            report["claimed_replicated_byte_seconds"] = claimedReplicatedByteSeconds;
            report["claimed_storage_bytes"] = claimedStorageBytes;
            return new VerificationResult(report, accepted, IsStorageProof(recordType), claimedReplicatedByteSeconds, claimedStorageBytes);
        }
        catch (Exception ex)
        {
            report["reason"] = "verification_exception: " + ex.Message;
            return new VerificationResult(report, false, false, 0, 0);
        }
    }

    private static bool IsSignedMeteringRecordType(string recordType)
    {
        return recordType == "node_capacity_snapshot_record"
            || recordType == "storage_assignment_acknowledgment_record"
            || recordType == "storage_epoch_proof_record";
    }

    private static bool IsStorageProof(string recordType)
    {
        return recordType == "storage_epoch_proof_record";
    }

    private static bool HasAcceptedStorageProofPackage(JsonElement root, out string reason)
    {
        if (GetString(root, "status") != "submitted" && GetString(root, "status") != "accepted")
        {
            reason = "storage_proof_status_not_submitted_or_accepted";
            return false;
        }

        if (!root.TryGetProperty("content_ref", out var contentRef)
            || string.IsNullOrWhiteSpace(GetString(contentRef, "cid"))
            || string.IsNullOrWhiteSpace(GetString(contentRef, "manifest_sha256")))
        {
            reason = "storage_proof_missing_content_manifest";
            return false;
        }

        if (!root.TryGetProperty("object_manifest", out var objectManifest)
            || GetInt64(objectManifest, "total_size_bytes") <= 0
            || GetInt64(objectManifest, "redundancy_target") <= 0
            || string.IsNullOrWhiteSpace(GetString(objectManifest, "privacy_preserving_object_id_sha256"))
            || !ObjectManifestHasChunkHashes(objectManifest))
        {
            reason = "storage_proof_missing_object_manifest";
            return false;
        }

        if (!root.TryGetProperty("challenge", out var challenge)
            || string.IsNullOrWhiteSpace(GetString(challenge, "challenge_seed_sha256"))
            || !HasNonEmptyArray(challenge, "segment_offsets"))
        {
            reason = "storage_proof_missing_possession_challenge";
            return false;
        }

        if (!root.TryGetProperty("proof_response", out var proofResponse)
            || GetInt64(proofResponse, "proved_bytes") <= 0
            || string.IsNullOrWhiteSpace(GetString(proofResponse, "response_sha256")))
        {
            reason = "storage_proof_missing_possession_response";
            return false;
        }

        if (!root.TryGetProperty("retrieval_challenge", out var retrievalChallenge)
            || GetInt64(retrievalChallenge, "latency_threshold_ms") <= 0
            || string.IsNullOrWhiteSpace(GetString(retrievalChallenge, "verifier_id")))
        {
            reason = "storage_proof_missing_retrieval_challenge";
            return false;
        }

        if (!root.TryGetProperty("retrieval_response", out var retrievalResponse)
            || !GetBoolean(retrievalResponse, "succeeded")
            || GetInt64(retrievalResponse, "retrieved_bytes") <= 0
            || !retrievalResponse.TryGetProperty("latency_ms", out _)
            || GetInt64(retrievalResponse, "latency_ms") > GetInt64(retrievalChallenge, "latency_threshold_ms")
            || string.IsNullOrWhiteSpace(GetString(retrievalResponse, "verifier_signature")))
        {
            reason = "storage_proof_missing_successful_retrieval_response";
            return false;
        }

        if (!root.TryGetProperty("metering_claim", out var meteringClaim)
            || GetInt64(meteringClaim, "claimed_storage_bytes") <= 0
            || GetInt64(meteringClaim, "claimed_replicated_byte_seconds") <= 0)
        {
            reason = "storage_proof_missing_metering_claim";
            return false;
        }

        if (!root.TryGetProperty("delivery_metering", out var deliveryMetering)
            || GetInt64(deliveryMetering, "verified_gb_days") <= 0
            || string.IsNullOrWhiteSpace(GetString(deliveryMetering, "metering_formula")))
        {
            reason = "storage_proof_missing_delivery_metering";
            return false;
        }

        if (!root.TryGetProperty("repair_status", out var repairStatus)
            || string.IsNullOrWhiteSpace(GetString(repairStatus, "redundancy_status"))
            || (GetBoolean(repairStatus, "node_failed") && string.IsNullOrWhiteSpace(GetString(repairStatus, "repair_action"))))
        {
            reason = "storage_proof_missing_repair_status";
            return false;
        }

        if (!root.TryGetProperty("failure_remedy", out var failureRemedy)
            || string.IsNullOrWhiteSpace(GetString(failureRemedy, "failed_epoch_remedy")))
        {
            reason = "storage_proof_missing_failure_remedy";
            return false;
        }

        reason = "storage_proof_package_accepted";
        return true;
    }

    private static bool ObjectManifestHasChunkHashes(JsonElement objectManifest)
    {
        if (!objectManifest.TryGetProperty("chunks", out var chunks) || chunks.ValueKind != JsonValueKind.Array)
        {
            return false;
        }

        foreach (var chunk in chunks.EnumerateArray())
        {
            if (GetInt64(chunk, "size_bytes") > 0 && !string.IsNullOrWhiteSpace(GetString(chunk, "sha256")))
            {
                return true;
            }
        }

        return false;
    }

    private static bool HasNonEmptyArray(JsonElement root, string propertyName)
    {
        return root.TryGetProperty(propertyName, out var value)
            && value.ValueKind == JsonValueKind.Array
            && value.GetArrayLength() > 0;
    }

    private static bool VerifySignature(string publicKeyPath, byte[] data, byte[] signatureBytes)
    {
        using var rsa = RSA.Create();
        rsa.ImportSubjectPublicKeyInfo(File.ReadAllBytes(publicKeyPath), out _);
        return rsa.VerifyData(data, signatureBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
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

    private static string ToWorkspaceRelativePath(string workspaceRoot, string path)
    {
        var root = Path.GetFullPath(workspaceRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var normalizedPath = Path.GetFullPath(path);
        if (normalizedPath.StartsWith(root, StringComparison.OrdinalIgnoreCase))
        {
            return normalizedPath.Substring(root.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Replace(Path.DirectorySeparatorChar, '/');
        }

        return normalizedPath;
    }

    private static string GetString(JsonElement root, string propertyName)
    {
        return root.TryGetProperty(propertyName, out var value) ? value.GetString() ?? string.Empty : string.Empty;
    }

    private static long GetInt64(JsonElement root, string propertyName)
    {
        if (!root.TryGetProperty(propertyName, out var value))
        {
            return 0;
        }

        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number))
        {
            return number;
        }

        return value.ValueKind == JsonValueKind.String && long.TryParse(value.GetString(), out var parsed) ? parsed : 0;
    }

    private static bool GetBoolean(JsonElement root, string propertyName)
    {
        return root.TryGetProperty(propertyName, out var value)
            && (value.ValueKind == JsonValueKind.True
                || (value.ValueKind == JsonValueKind.String && bool.TryParse(value.GetString(), out var parsed) && parsed));
    }

    private static string ComputeSha256(byte[] bytes)
    {
        using var sha256 = SHA256.Create();
        return string.Concat(sha256.ComputeHash(bytes).Select(b => b.ToString("x2")));
    }

    private sealed record VerificationResult(
        Dictionary<string, object?> Report,
        bool Accepted,
        bool IsStorageProof,
        long ClaimedReplicatedByteSeconds,
        long ClaimedStorageBytes);
}
