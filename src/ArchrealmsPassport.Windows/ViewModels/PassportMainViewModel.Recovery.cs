using System.Threading.Tasks;
using ArchrealmsPassport.Windows.Services;

namespace ArchrealmsPassport.Windows.ViewModels
{
    public sealed partial class PassportMainViewModel
    {
        private Task ExportRecoveryGuidanceAsync()
        {
            var guidance = new PassportRecoveryService(_releaseLane).CreateRecoveryGuidanceExport(
                WorkspaceRoot,
                ActiveIdentityId);
            RecoveryStatusText = guidance.Message;
            AppendLog(guidance.Message);
            if (guidance.Succeeded)
            {
                LatestRecoveryGuidanceText = guidance.RecordPath;
                AppendLog("Recovery guidance: " + guidance.RecordPath);
            }

            return Task.CompletedTask;
        }

        private Task FreezeAccountAsync()
        {
            var freeze = new PassportRecoveryService(_releaseLane).CreateAccountSecurityFreeze(
                WorkspaceRoot,
                ActiveIdentityId,
                ActiveDeviceId,
                ActiveDeviceKeyPath,
                RecoveryReasonCode,
                RecoveryFreezeWalletOperations,
                RecoveryFreezePendingEscrow,
                RecoveryRevokeAiSessions,
                RecoveryPauseStorageNodeOperations);
            RecoveryStatusText = freeze.Message;
            AppendLog(freeze.Message);
            if (freeze.Succeeded)
            {
                LatestSecurityFreezeText = freeze.RecordPath;
                AppendLog("Security freeze: " + freeze.RecordPath);
                UpdateMonetaryStatus();
                UpdateRecoveryReadiness();
            }

            return Task.CompletedTask;
        }

        private Task DeauthorizeDeviceAsync()
        {
            var targetDeviceId = string.IsNullOrWhiteSpace(RecoveryTargetDeviceId)
                ? ActiveDeviceId
                : RecoveryTargetDeviceId;
            var deauthorization = new PassportRecoveryService(_releaseLane).CreateDeviceDeauthorization(
                WorkspaceRoot,
                ActiveIdentityId,
                ActiveDeviceId,
                ActiveDeviceKeyPath,
                targetDeviceId,
                RecoveryReasonCode);
            RecoveryStatusText = deauthorization.Message;
            AppendLog(deauthorization.Message);
            if (deauthorization.Succeeded)
            {
                LatestDeviceDeauthorizationText = deauthorization.RecordPath;
                AppendLog("Device deauthorization: " + deauthorization.RecordPath);
                UpdateRecoveryReadiness();
                RaiseCommandAvailability();
            }

            return Task.CompletedTask;
        }

        private Task RevokeWalletKeyAsync()
        {
            var revocation = new PassportWalletKeyService(_releaseLane).RevokeWalletKey(
                WorkspaceRoot,
                ActiveIdentityId,
                ActiveDeviceId,
                ActiveDeviceKeyPath,
                ActiveWalletKeyId,
                RecoveryReasonCode,
                RecoveryFreezePendingEscrow);
            RecoveryStatusText = revocation.Message;
            AppendLog(revocation.Message);
            if (revocation.Succeeded)
            {
                LatestWalletRevocationText = revocation.RevocationRecordPath;
                ActiveWalletKeyId = string.Empty;
                ActiveWalletKeyReferencePath = string.Empty;
                ActiveWalletPublicKeyPath = string.Empty;
                _settingsStore.Save(CreateSettingsSnapshot());
                AppendLog("Wallet revocation: " + revocation.RevocationRecordPath);
                UpdateMonetaryStatus();
                UpdateRecoveryReadiness();
            }

            return Task.CompletedTask;
        }

        private Task RotateWalletKeyAsync()
        {
            var rotation = new PassportWalletKeyService(_releaseLane).RotateWalletKey(
                WorkspaceRoot,
                ActiveIdentityId,
                ActiveDeviceId,
                ActiveDeviceKeyPath,
                ActiveWalletKeyId,
                RecoveryFreezePendingEscrow);
            RecoveryStatusText = rotation.Message;
            AppendLog(rotation.Message);
            if (rotation.Succeeded)
            {
                LatestWalletRevocationText = rotation.Revocation.RevocationRecordPath;
                ActiveWalletKeyId = rotation.Binding.WalletKeyId;
                ActiveWalletKeyReferencePath = rotation.Binding.WalletKeyReferencePath;
                ActiveWalletPublicKeyPath = rotation.Binding.WalletPublicKeyPath;
                _settingsStore.Save(CreateSettingsSnapshot());
                AppendLog("Old wallet revocation: " + rotation.Revocation.RevocationRecordPath);
                AppendLog("New wallet binding: " + rotation.Binding.BindingRecordPath);
                UpdateMonetaryStatus();
                UpdateRecoveryReadiness();
            }

            return Task.CompletedTask;
        }

        private bool CanRevokeWalletKey()
        {
            return HasActiveWalletKey() && CanUseActiveDeviceCredential();
        }

        private void UpdateRecoveryReadiness()
        {
            if (string.IsNullOrWhiteSpace(ActiveIdentityId))
            {
                RecoveryReadinessText = "Recovery readiness unavailable until a Passport is active.";
                return;
            }

            var readiness = new PassportRecoveryService(_releaseLane).GetRecoveryReadiness(
                WorkspaceRoot,
                ActiveIdentityId);
            RecoveryReadinessText = readiness.Summary;
        }
    }
}
