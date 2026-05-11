param(
    [string]$DotnetPath,
    [string]$OutputPath,
    [switch]$KeepWorkspace
)

$ErrorActionPreference = "Stop"

if (-not $DotnetPath -and $env:ARCHREALMS_DOTNET) {
    $DotnetPath = $env:ARCHREALMS_DOTNET
}

if ($DotnetPath) {
    $dotnet = (Resolve-Path -LiteralPath $DotnetPath).Path
}
else {
    $dotnet = (Get-Command dotnet -ErrorAction Stop).Source
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$smokeStartedUtc = [DateTime]::UtcNow
$smokeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("passport-smoke-" + [Guid]::NewGuid().ToString("N"))
$harnessRoot = Join-Path $smokeRoot "harness"
$workspacesRoot = Join-Path $smokeRoot "workspaces"
New-Item -ItemType Directory -Force $harnessRoot | Out-Null
New-Item -ItemType Directory -Force $workspacesRoot | Out-Null

function Remove-SmokeTempArtifacts {
    if ($KeepWorkspace) {
        return
    }

    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $targets = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    [void]$targets.Add([System.IO.Path]::GetFullPath($smokeRoot))

    Get-ChildItem -LiteralPath $tempRoot -Directory -Filter "passport-*" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $smokeStartedUtc.AddSeconds(-5) } |
        ForEach-Object { [void]$targets.Add([System.IO.Path]::GetFullPath($_.FullName)) }

    foreach ($target in $targets) {
        if (-not $target.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        if (Test-Path -LiteralPath $target) {
            try {
                Remove-Item -LiteralPath $target -Recurse -Force
            }
            catch {
            }
        }
    }
}

trap {
    Remove-SmokeTempArtifacts
    throw
}

$projectPath = Join-Path $harnessRoot "PassportSmoke.csproj"
$programPath = Join-Path $harnessRoot "Program.cs"
$appProjectPath = Join-Path $repoRoot "src\ArchrealmsPassport.Windows\ArchrealmsPassport.Windows.csproj"

$projectText = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0-windows10.0.19041.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="$appProjectPath" />
  </ItemGroup>
</Project>
"@

$programText = @"
using System;
using System.IO;
using System.Text;
using System.Text.Json;
using ArchrealmsPassport.Windows.Services;

namespace PassportSmoke;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length < 1)
            {
                throw new InvalidOperationException("Missing workspaces root.");
            }

            var workspacesRoot = args[0];
            var authorityWorkspace = Path.Combine(workspacesRoot, "authority");
            var candidateWorkspace = Path.Combine(workspacesRoot, "candidate");
            Directory.CreateDirectory(authorityWorkspace);
            Directory.CreateDirectory(candidateWorkspace);

            var recordService = new PassportRecordService();
            var cryptoService = new PassportCryptoService();

            var authority = recordService.CreateNewIdentity(authorityWorkspace, "Authority Persona", "pseudonymous", "Authority Device", false);
            if (!authority.Succeeded) throw new InvalidOperationException(authority.Message);

            var joinRequest = recordService.CreateJoinRequest(candidateWorkspace, authority.IdentityId, "Candidate Device", false);
            if (!joinRequest.Succeeded) throw new InvalidOperationException(joinRequest.Message);

            var approval = cryptoService.ApproveJoinRequest(authorityWorkspace, authority.IdentityId, authority.DeviceId, authority.PrivateKeyPath, joinRequest.JoinRequestPath);
            if (!approval.Succeeded) throw new InvalidOperationException(approval.Message);

            var activation = cryptoService.ImportJoinApproval(candidateWorkspace, approval.ApprovalPackagePath, joinRequest.DeviceId, joinRequest.PrivateKeyPath);
            if (!activation.Succeeded) throw new InvalidOperationException(activation.Message);

            var submission = cryptoService.CreateRegistrySubmission(candidateWorkspace, activation.IdentityId, activation.DeviceId, joinRequest.PrivateKeyPath);
            if (!submission.Succeeded) throw new InvalidOperationException(submission.Message);

            var proofSourcePath = Path.Combine(candidateWorkspace, "metering-proof-source.bin");
            File.WriteAllText(
                proofSourcePath,
                "Archrealms Passport smoke metering proof source " + DateTime.UtcNow.ToString("O"),
                Encoding.UTF8);

            var capacity = recordService.CreateNodeCapacitySnapshot(
                candidateWorkspace,
                activation.IdentityId,
                activation.DeviceId,
                joinRequest.PrivateKeyPath,
                "smoke-node",
                5,
                "Public archive contributor",
                "Balanced pinned archive",
                80,
                "pinned",
                false,
                Path.Combine(candidateWorkspace, "ipfs", "kubo"));
            if (!capacity.Succeeded) throw new InvalidOperationException(capacity.Message);

            var assignment = recordService.CreateStorageAssignmentAcknowledgment(
                candidateWorkspace,
                activation.IdentityId,
                activation.DeviceId,
                joinRequest.PrivateKeyPath,
                "smoke-node",
                "smoke-assignment",
                "bafy-smoke-content",
                "",
                "stewarded_archive_storage",
                new FileInfo(proofSourcePath).Length,
                true);
            if (!assignment.Succeeded) throw new InvalidOperationException(assignment.Message);

            var proof = recordService.CreateStorageEpochProof(
                candidateWorkspace,
                activation.IdentityId,
                activation.DeviceId,
                joinRequest.PrivateKeyPath,
                "smoke-node",
                "smoke-assignment",
                "bafy-smoke-content",
                "",
                "stewarded_archive_storage",
                proofSourcePath);
            if (!proof.Succeeded) throw new InvalidOperationException(proof.Message);

            var meteringStatus = recordService.CreateLocalMeteringStatus(
                candidateWorkspace,
                activation.IdentityId,
                activation.DeviceId,
                "smoke-node");
            if (!meteringStatus.Succeeded) throw new InvalidOperationException(meteringStatus.Message);

            var meteringVerification = recordService.VerifyLocalMeteringRecords(
                candidateWorkspace,
                activation.IdentityId,
                activation.DeviceId,
                joinRequest.PrivateKeyPath);
            if (!meteringVerification.Succeeded) throw new InvalidOperationException(meteringVerification.Message);

            var payload = new
            {
                AuthorityDeviceId = authority.DeviceId,
                AuthorityKeyReference = authority.PrivateKeyPath,
                CandidateIdentityId = activation.IdentityId,
                CandidateDeviceId = joinRequest.DeviceId,
                CandidateKeyReference = joinRequest.PrivateKeyPath,
                SubmissionPath = submission.SubmissionPath,
                AuthorityWorkspace = authorityWorkspace,
                CandidateWorkspace = candidateWorkspace,
                NodeCapacitySnapshotPath = capacity.RecordPath,
                StorageAssignmentAcknowledgmentPath = assignment.RecordPath,
                StorageEpochProofPath = proof.RecordPath,
                LocalMeteringStatusPath = meteringStatus.RecordPath,
                LocalMeteringVerificationPath = meteringVerification.RecordPath
            };

            Console.WriteLine(JsonSerializer.Serialize(payload));
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.ToString());
            return 1;
        }
    }
}
"@

Set-Content -LiteralPath $projectPath -Value $projectText -Encoding UTF8
Set-Content -LiteralPath $programPath -Value $programText -Encoding UTF8

$harnessOutput = & $dotnet run --project $projectPath -v q -p:RuntimeIdentifiers=win-x64 -- $workspacesRoot
if ($LASTEXITCODE -ne 0) {
    throw "Passport smoke harness failed."
}

$harnessJson = $harnessOutput | Select-Object -Last 1
$harness = $harnessJson | ConvertFrom-Json

$verifyScript = Join-Path $repoRoot "tools\passport\Verify-ArchrealmsRegistrySubmission.ps1"
$meteringVerifyScript = Join-Path $repoRoot "tools\passport\Verify-ArchrealmsPassportMetering.ps1"
$newMeteringPackageScript = Join-Path $repoRoot "tools\passport\New-ArchrealmsPassportMeteringPackage.ps1"
$verifyMeteringPackageScript = Join-Path $repoRoot "tools\passport\Verify-ArchrealmsPassportMeteringPackage.ps1"
$newMeteringAdmissionScript = Join-Path $repoRoot "tools\passport\New-ArchrealmsPassportMeteringAdmission.ps1"
$verifyMeteringAdmissionScript = Join-Path $repoRoot "tools\passport\Verify-ArchrealmsPassportMeteringAdmission.ps1"
$newMeteringAuditChallengeScript = Join-Path $repoRoot "tools\passport\New-ArchrealmsPassportMeteringAuditChallenge.ps1"
$newMeteringDisputeScript = Join-Path $repoRoot "tools\passport\New-ArchrealmsPassportMeteringDispute.ps1"
$newMeteringCorrectionScript = Join-Path $repoRoot "tools\passport\New-ArchrealmsPassportMeteringCorrection.ps1"
$newMeteringSettlementHandoffScript = Join-Path $repoRoot "tools\passport\New-ArchrealmsPassportMeteringSettlementHandoff.ps1"
$verifySignedReviewRecordScript = Join-Path $repoRoot "tools\passport\Verify-ArchrealmsPassportSignedReviewRecord.ps1"
$newMockBlockchainSettlementScript = Join-Path $repoRoot "tools\passport\New-ArchrealmsPassportMockBlockchainSettlement.ps1"
$verifyMockBlockchainSettlementScript = Join-Path $repoRoot "tools\passport\Verify-ArchrealmsPassportMockBlockchainSettlement.ps1"
$newBlockchainChainEvaluationScript = Join-Path $repoRoot "tools\passport\New-ArchrealmsPassportBlockchainSettlementChainEvaluation.ps1"
$verifyBlockchainChainEvaluationScript = Join-Path $repoRoot "tools\passport\Verify-ArchrealmsPassportBlockchainSettlementChainEvaluation.ps1"
$submissionRoot = Split-Path -Parent $harness.SubmissionPath
$unanchoredReport = Join-Path $submissionRoot "verification-report.unanchored.json"
$anchoredReport = Join-Path $submissionRoot "verification-report.anchored.json"
$meteringReport = Join-Path $harness.CandidateWorkspace "records\passport\metering\status\authoritative-metering-report.json"
$meteringPackageRoot = Join-Path $harness.CandidateWorkspace "records\passport\metering\packages\smoke-metering-package"
$meteringPackageVerificationReport = Join-Path $meteringPackageRoot "metering-package-verification-report.json"

powershell -ExecutionPolicy Bypass -File $verifyScript -SubmissionPath $harness.SubmissionPath -OutputPath $unanchoredReport -DotnetPath $dotnet | Out-Null
powershell -ExecutionPolicy Bypass -File $verifyScript -SubmissionPath $harness.SubmissionPath -OutputPath $anchoredReport -TrustedWorkspaceRoot $harness.AuthorityWorkspace -DotnetPath $dotnet | Out-Null
powershell -ExecutionPolicy Bypass -File $meteringVerifyScript -WorkspaceRoot $harness.CandidateWorkspace -OutputPath $meteringReport -DotnetPath $dotnet | Out-Null
powershell -ExecutionPolicy Bypass -File $newMeteringPackageScript -WorkspaceRoot $harness.CandidateWorkspace -MeteringReportPath $meteringReport -OutputRoot $meteringPackageRoot | Out-Null
powershell -ExecutionPolicy Bypass -File $verifyMeteringPackageScript -PackageRoot $meteringPackageRoot -OutputPath $meteringPackageVerificationReport | Out-Null
$meteringAdmissionJson = powershell -ExecutionPolicy Bypass -File $newMeteringAdmissionScript -WorkspaceRoot $harness.CandidateWorkspace -IdentityId $harness.CandidateIdentityId -DeviceId $harness.CandidateDeviceId -DeviceKeyReferencePath $harness.CandidateKeyReference -PackageRoot $meteringPackageRoot -PackageVerificationReportPath $meteringPackageVerificationReport -DotnetPath $dotnet
$meteringAdmission = $meteringAdmissionJson | Select-Object -Last 1 | ConvertFrom-Json
$meteringAdmissionVerificationReport = Join-Path (Split-Path -Parent $meteringAdmission.RecordPath) "metering-admission-verification-report.json"
powershell -ExecutionPolicy Bypass -File $verifyMeteringAdmissionScript -AdmissionPath $meteringAdmission.RecordPath -WorkspaceRoot $harness.CandidateWorkspace -OutputPath $meteringAdmissionVerificationReport -DotnetPath $dotnet | Out-Null
$meteringAuditChallengeJson = powershell -ExecutionPolicy Bypass -File $newMeteringAuditChallengeScript -WorkspaceRoot $harness.CandidateWorkspace -IdentityId $harness.CandidateIdentityId -DeviceId $harness.CandidateDeviceId -DeviceKeyReferencePath $harness.CandidateKeyReference -AdmissionPath $meteringAdmission.RecordPath -RegistrarId "smoke-registrar" -ChallengeReason "routine_sample" -DotnetPath $dotnet
$meteringAuditChallenge = $meteringAuditChallengeJson | Select-Object -Last 1 | ConvertFrom-Json
$meteringAuditChallengeVerificationReport = Join-Path (Split-Path -Parent $meteringAuditChallenge.RecordPath) "metering-audit-challenge-verification-report.json"
powershell -ExecutionPolicy Bypass -File $verifySignedReviewRecordScript -RecordPath $meteringAuditChallenge.RecordPath -WorkspaceRoot $harness.CandidateWorkspace -ExpectedRecordType "passport_metering_audit_challenge_record" -OutputPath $meteringAuditChallengeVerificationReport -DotnetPath $dotnet | Out-Null
$meteringDisputeJson = powershell -ExecutionPolicy Bypass -File $newMeteringDisputeScript -WorkspaceRoot $harness.CandidateWorkspace -IdentityId $harness.CandidateIdentityId -DeviceId $harness.CandidateDeviceId -DeviceKeyReferencePath $harness.CandidateKeyReference -AdmissionPath $meteringAdmission.RecordPath -AuditChallengePath $meteringAuditChallenge.RecordPath -OpenedByRole "registrar" -OpenedById "smoke-registrar" -DisputeScope "proof_count_or_service_units" -ChallengeReason "audit_review" -RequestedRemedy "exclude_or_correct_challenged_units" -DotnetPath $dotnet
$meteringDispute = $meteringDisputeJson | Select-Object -Last 1 | ConvertFrom-Json
$meteringDisputeVerificationReport = Join-Path (Split-Path -Parent $meteringDispute.RecordPath) "metering-dispute-verification-report.json"
powershell -ExecutionPolicy Bypass -File $verifySignedReviewRecordScript -RecordPath $meteringDispute.RecordPath -WorkspaceRoot $harness.CandidateWorkspace -ExpectedRecordType "passport_metering_dispute_record" -OutputPath $meteringDisputeVerificationReport -DotnetPath $dotnet | Out-Null
$meteringCorrectionJson = powershell -ExecutionPolicy Bypass -File $newMeteringCorrectionScript -WorkspaceRoot $harness.CandidateWorkspace -IdentityId $harness.CandidateIdentityId -DeviceId $harness.CandidateDeviceId -DeviceKeyReferencePath $harness.CandidateKeyReference -AdmissionPath $meteringAdmission.RecordPath -AuditChallengePath $meteringAuditChallenge.RecordPath -DisputePath $meteringDispute.RecordPath -RegistrarId "smoke-registrar" -CorrectionReason "dispute_resolution" -CorrectedAcceptedProofCount 0 -CorrectedRejectedProofCount 1 -CorrectedVerifiedReplicatedByteSeconds 0 -DotnetPath $dotnet
$meteringCorrection = $meteringCorrectionJson | Select-Object -Last 1 | ConvertFrom-Json
$meteringCorrectionVerificationReport = Join-Path (Split-Path -Parent $meteringCorrection.RecordPath) "metering-correction-verification-report.json"
powershell -ExecutionPolicy Bypass -File $verifySignedReviewRecordScript -RecordPath $meteringCorrection.RecordPath -WorkspaceRoot $harness.CandidateWorkspace -ExpectedRecordType "passport_metering_correction_record" -OutputPath $meteringCorrectionVerificationReport -DotnetPath $dotnet | Out-Null
$meteringSettlementHandoffJson = powershell -ExecutionPolicy Bypass -File $newMeteringSettlementHandoffScript -WorkspaceRoot $harness.CandidateWorkspace -IdentityId $harness.CandidateIdentityId -DeviceId $harness.CandidateDeviceId -DeviceKeyReferencePath $harness.CandidateKeyReference -AdmissionPath $meteringAdmission.RecordPath -AuditChallengePath $meteringAuditChallenge.RecordPath -DisputePath $meteringDispute.RecordPath -CorrectionPath $meteringCorrection.RecordPath -RegistrarId "smoke-registrar" -HandoffStatus "eligible_for_settlement_review" -DotnetPath $dotnet
$meteringSettlementHandoff = $meteringSettlementHandoffJson | Select-Object -Last 1 | ConvertFrom-Json
$meteringSettlementHandoffVerificationReport = Join-Path (Split-Path -Parent $meteringSettlementHandoff.RecordPath) "metering-settlement-handoff-verification-report.json"
powershell -ExecutionPolicy Bypass -File $verifySignedReviewRecordScript -RecordPath $meteringSettlementHandoff.RecordPath -WorkspaceRoot $harness.CandidateWorkspace -ExpectedRecordType "passport_metering_settlement_handoff_record" -OutputPath $meteringSettlementHandoffVerificationReport -DotnetPath $dotnet | Out-Null
$mockBlockchainSettlementRoot = Join-Path $harness.CandidateWorkspace "records\passport\settlement\mock-chain\smoke"
$mockBlockchainSettlementJson = powershell -ExecutionPolicy Bypass -File $newMockBlockchainSettlementScript -WorkspaceRoot $harness.CandidateWorkspace -HandoffPath $meteringSettlementHandoff.RecordPath -OutputRoot $mockBlockchainSettlementRoot -ChainId "mock-chain-local" -SettlementContract "mock-passport-settlement-v0" -SettlementMethod "mock_finality_commitment" -AssetOrCreditId "mock-service-credit" -FinalityConfirmationsRequired 1 -FinalityConfirmationsObserved 1
$mockBlockchainSettlement = $mockBlockchainSettlementJson | Select-Object -Last 1 | ConvertFrom-Json
$mockBlockchainSettlementVerificationReport = Join-Path $mockBlockchainSettlementRoot "mock-blockchain-settlement-verification-report.json"
powershell -ExecutionPolicy Bypass -File $verifyMockBlockchainSettlementScript -BatchPath $mockBlockchainSettlement.batch_record_path -StatusPath $mockBlockchainSettlement.status_record_path -HandoffPath $meteringSettlementHandoff.RecordPath -OutputPath $mockBlockchainSettlementVerificationReport | Out-Null
$blockchainChainEvaluationRoot = Join-Path $harness.CandidateWorkspace "records\passport\settlement\chain-evaluations\smoke-mock-chain"
$blockchainChainEvaluationJson = powershell -ExecutionPolicy Bypass -File $newBlockchainChainEvaluationScript -WorkspaceRoot $harness.CandidateWorkspace -OutputRoot $blockchainChainEvaluationRoot -ChainName "Mock Chain Local" -ChainId "mock-chain-local" -NetworkType "private" -NativeAsset "none" -CandidateSettlementAssetOrCredit "mock-service-credit" -FinalityModel "simulated_confirmations" -ConfirmationsRequired 1 -ExpectedTimeToFinalitySeconds 1 -ReorgOrReversalRisk "none_for_simulation_only" -FinalityRuleSummary "Mock finality is final when observed confirmations are greater than or equal to required confirmations." -AverageBatchTransactionCostEstimate "0 simulated cost" -CostVolatilityRisk "not applicable for mock chain" -ExpectedEpochBatchCapacity "single smoke batch" -ThroughputNotes "Dev-only smoke evaluation." -SupportsEvidenceRootCommitment 1 -SupportsHandoffIdDeduplication 1 -SupportsParticipantOutputs 1 -SupportsCorrectionBatches 1 -SupportsPauseControls 1 -SupportsEventsOrIndexableRecords 1 -UpgradeabilityModel "mock script versioning only" -PublicRpcAvailable 0 -IndexerAvailable 0 -PassportCanVerifyFinalityWithoutCustody 1 -ReadPathNotes "Passport can read local mock status records only; no public RPC or indexer exists." -MultisigOrThresholdSigningAvailable 0 -RegistrarTreasurySeparationSupported 0 -KeyRotationSupported 0 -EmergencyPauseSupported 0 -CustodyNotes "No custody exists in the mock chain path." -LegalReviewStatus "not_started" -TaxReviewStatus "not_started" -TreasuryReviewStatus "not_started" -GovernanceReviewStatus "not_started" -RpcProviderRisk "not applicable for mock chain" -IndexerProviderRisk "not applicable for mock chain" -BridgeOrDependencyRisk "no bridge dependency in mock chain" -MigrationPlanRequired 1 -ContinuityNotes "Replace with a real chain evaluation before public economy-facing release." -Recommendation "dev_only" -RequiredConditionsCsv "real chain selection,contract semantics,finality policy,custody policy,legal tax treasury governance approval" -Reviewer "passport-smoke" -Summary "Smoke-only mock chain evaluation. This record verifies evaluation shape but does not satisfy the blockchain release gate."
$blockchainChainEvaluation = $blockchainChainEvaluationJson | Select-Object -Last 1 | ConvertFrom-Json
$blockchainChainEvaluationVerificationReport = Join-Path $blockchainChainEvaluationRoot "blockchain-settlement-chain-evaluation-verification-report.json"
powershell -ExecutionPolicy Bypass -File $verifyBlockchainChainEvaluationScript -EvaluationPath $blockchainChainEvaluation.evaluation_path -OutputPath $blockchainChainEvaluationVerificationReport | Out-Null

$unanchored = Get-Content -LiteralPath $unanchoredReport -Raw | ConvertFrom-Json
$anchored = Get-Content -LiteralPath $anchoredReport -Raw | ConvertFrom-Json
$metering = Get-Content -LiteralPath $meteringReport -Raw | ConvertFrom-Json
$meteringPackageVerification = Get-Content -LiteralPath $meteringPackageVerificationReport -Raw | ConvertFrom-Json
$meteringAdmissionVerification = Get-Content -LiteralPath $meteringAdmissionVerificationReport -Raw | ConvertFrom-Json
$meteringAuditChallengeVerification = Get-Content -LiteralPath $meteringAuditChallengeVerificationReport -Raw | ConvertFrom-Json
$meteringDisputeVerification = Get-Content -LiteralPath $meteringDisputeVerificationReport -Raw | ConvertFrom-Json
$meteringCorrectionVerification = Get-Content -LiteralPath $meteringCorrectionVerificationReport -Raw | ConvertFrom-Json
$meteringSettlementHandoffVerification = Get-Content -LiteralPath $meteringSettlementHandoffVerificationReport -Raw | ConvertFrom-Json
$mockBlockchainSettlementVerification = Get-Content -LiteralPath $mockBlockchainSettlementVerificationReport -Raw | ConvertFrom-Json
$blockchainChainEvaluationVerification = Get-Content -LiteralPath $blockchainChainEvaluationVerificationReport -Raw | ConvertFrom-Json
$authorityKeyRef = Get-Content -LiteralPath $harness.AuthorityKeyReference -Raw | ConvertFrom-Json
$candidateKeyRef = Get-Content -LiteralPath $harness.CandidateKeyReference -Raw | ConvertFrom-Json

$result = [pscustomobject]@{
    verified_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    dotnet = $dotnet
    authority_key_backend = $authorityKeyRef.StorageBackend
    authority_key_provider = $authorityKeyRef.Provider
    candidate_key_backend = $candidateKeyRef.StorageBackend
    candidate_key_provider = $candidateKeyRef.Provider
    unanchored_verified = $unanchored.verified
    unanchored_authorization_summary = $unanchored.authorization_summary
    anchored_verified = $anchored.verified
    anchored_authorization_summary = $anchored.authorization_summary
    metering_capacity_snapshot_path = $harness.NodeCapacitySnapshotPath
    metering_assignment_acknowledgment_path = $harness.StorageAssignmentAcknowledgmentPath
    metering_storage_epoch_proof_path = $harness.StorageEpochProofPath
    metering_status_path = $harness.LocalMeteringStatusPath
    metering_verification_path = $harness.LocalMeteringVerificationPath
    authoritative_metering_report_path = $meteringReport
    authoritative_metering_accepted_proof_count = $metering.accepted_proof_count
    authoritative_metering_rejected_proof_count = $metering.rejected_proof_count
    authoritative_metering_verified_replicated_byte_seconds = $metering.verified_replicated_byte_seconds
    metering_package_root = $meteringPackageRoot
    metering_package_verified = $meteringPackageVerification.verified
    metering_package_document_hashes_valid = $meteringPackageVerification.document_hashes_valid
    metering_admission_path = $meteringAdmission.RecordPath
    metering_admission_verified = $meteringAdmissionVerification.verified
    metering_admission_signature_verified = $meteringAdmissionVerification.signature_verified
    metering_admission_settlement_status = $meteringAdmissionVerification.settlement_status
    metering_audit_challenge_path = $meteringAuditChallenge.RecordPath
    metering_audit_challenge_verified = $meteringAuditChallengeVerification.verified
    metering_audit_challenge_signature_verified = $meteringAuditChallengeVerification.signature_verified
    metering_audit_challenge_settlement_status = $meteringAuditChallengeVerification.settlement_status
    metering_dispute_path = $meteringDispute.RecordPath
    metering_dispute_verified = $meteringDisputeVerification.verified
    metering_dispute_signature_verified = $meteringDisputeVerification.signature_verified
    metering_dispute_settlement_status = $meteringDisputeVerification.settlement_status
    metering_correction_path = $meteringCorrection.RecordPath
    metering_correction_verified = $meteringCorrectionVerification.verified
    metering_correction_signature_verified = $meteringCorrectionVerification.signature_verified
    metering_correction_settlement_status = $meteringCorrectionVerification.settlement_status
    metering_settlement_handoff_path = $meteringSettlementHandoff.RecordPath
    metering_settlement_handoff_verified = $meteringSettlementHandoffVerification.verified
    metering_settlement_handoff_signature_verified = $meteringSettlementHandoffVerification.signature_verified
    metering_settlement_handoff_settlement_status = $meteringSettlementHandoffVerification.settlement_status
    mock_blockchain_settlement_batch_path = $mockBlockchainSettlement.batch_record_path
    mock_blockchain_settlement_status_path = $mockBlockchainSettlement.status_record_path
    mock_blockchain_settlement_verified = $mockBlockchainSettlementVerification.verified
    mock_blockchain_settlement_finality_status = $mockBlockchainSettlementVerification.settlement_finality_status
    mock_blockchain_settlement_simulated_only = $mockBlockchainSettlementVerification.simulated_only
    blockchain_chain_evaluation_path = $blockchainChainEvaluation.evaluation_path
    blockchain_chain_evaluation_verified = $blockchainChainEvaluationVerification.verified
    blockchain_chain_evaluation_recommendation = $blockchainChainEvaluationVerification.recommendation
    blockchain_chain_evaluation_release_gate_satisfied = $blockchainChainEvaluationVerification.release_gate_satisfied
    authority_workspace = $harness.AuthorityWorkspace
    candidate_workspace = $harness.CandidateWorkspace
    submission_path = $harness.SubmissionPath
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $smokeRoot "passport-smoke-report.json"
}

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory) {
    New-Item -ItemType Directory -Force $outputDirectory | Out-Null
}

$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Get-Content -LiteralPath $OutputPath
Remove-SmokeTempArtifacts
