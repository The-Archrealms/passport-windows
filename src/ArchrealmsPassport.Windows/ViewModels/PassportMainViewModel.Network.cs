using System;
using System.Threading.Tasks;
using System.Windows;

namespace ArchrealmsPassport.Windows.ViewModels
{
    public sealed partial class PassportMainViewModel : IDisposable
    {
        private async Task RefreshStatusAndEnforceNetworkPolicyAsync()
        {
            await RefreshStatusAsync();
            await StopStorageIfNetworkIsRestrictedAsync("Network policy checked.");
        }

        private bool TryAllowStorageNetworkOperation(string operationName)
        {
            var policy = _networkUsageService.EvaluateStorageNetworkPolicy(PreferWifiOnly);
            if (policy.StorageAllowed)
            {
                return true;
            }

            StorageActionStatusText = "Storage paused: " + policy.Message;
            AppendLog(operationName + " blocked. " + policy.Message);
            return false;
        }

        private void NetworkUsageService_NetworkStatusChanged(object? sender, EventArgs e)
        {
            if (!PreferWifiOnly || Application.Current == null)
            {
                return;
            }

            Application.Current.Dispatcher.BeginInvoke(new Action(async delegate
            {
                await StopStorageIfNetworkIsRestrictedAsync("Network changed.");
            }));
        }

        private async Task StopStorageIfNetworkIsRestrictedAsync(string reason)
        {
            if (_storageNetworkStopInProgress || !PreferWifiOnly)
            {
                return;
            }

            var policy = _networkUsageService.EvaluateStorageNetworkPolicy(true);
            if (policy.StorageAllowed)
            {
                return;
            }

            _storageNetworkStopInProgress = true;
            try
            {
                StorageActionStatusText = "Storage paused: " + policy.Message;
                AppendLog(reason + " " + policy.Message);

                var result = await _localNodeService.StopAsync(
                    _toolRoot,
                    WorkspaceRoot,
                    IpfsRepoPath,
                    IpfsCliPathOverride);

                AppendLocalNodeResult(result, "Stopped storage because the current network is capped or metered.");
                await RefreshStatusAsync();
            }
            catch (Exception ex)
            {
                AppendLog("Network enforcement failed: " + ex.Message);
            }
            finally
            {
                _storageNetworkStopInProgress = false;
            }
        }

        public void Dispose()
        {
            _networkUsageService.NetworkStatusChanged -= NetworkUsageService_NetworkStatusChanged;
            _networkUsageService.Dispose();
        }
    }
}
