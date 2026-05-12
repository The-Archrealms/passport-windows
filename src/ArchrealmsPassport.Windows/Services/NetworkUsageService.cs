using System;
using Windows.Networking.Connectivity;

namespace ArchrealmsPassport.Windows.Services
{
    public sealed class NetworkUsageService : IDisposable
    {
        private readonly NetworkStatusChangedEventHandler _networkStatusChangedHandler;
        private bool _disposed;

        public NetworkUsageService()
        {
            _networkStatusChangedHandler = delegate { NetworkStatusChanged?.Invoke(this, EventArgs.Empty); };

            try
            {
                NetworkInformation.NetworkStatusChanged += _networkStatusChangedHandler;
            }
            catch
            {
            }
        }

        public event EventHandler? NetworkStatusChanged;

        public StorageNetworkPolicyResult EvaluateStorageNetworkPolicy(bool requireUnmetered)
        {
            if (!requireUnmetered)
            {
                return StorageNetworkPolicyResult.Allowed("Storage network use is unrestricted by Passport settings.");
            }

            try
            {
                var profile = NetworkInformation.GetInternetConnectionProfile();
                if (profile == null)
                {
                    return StorageNetworkPolicyResult.Blocked(
                        "Storage requires an unmetered network, but Windows reports no active internet connection.");
                }

                var cost = profile.GetConnectionCost();
                return EvaluateConnectionCost(
                    requireUnmetered,
                    cost.NetworkCostType,
                    cost.Roaming,
                    cost.OverDataLimit,
                    cost.ApproachingDataLimit);
            }
            catch (Exception ex)
            {
                return StorageNetworkPolicyResult.Blocked(
                    "Storage requires an unmetered network, but Windows network cost could not be checked: " + ex.Message);
            }
        }

        public static StorageNetworkPolicyResult EvaluateConnectionCost(
            bool requireUnmetered,
            NetworkCostType networkCostType,
            bool roaming,
            bool overDataLimit,
            bool approachingDataLimit)
        {
            if (!requireUnmetered)
            {
                return StorageNetworkPolicyResult.Allowed("Storage network use is unrestricted by Passport settings.");
            }

            if (networkCostType == NetworkCostType.Unrestricted
                && !roaming
                && !overDataLimit
                && !approachingDataLimit)
            {
                return StorageNetworkPolicyResult.Allowed("Storage is allowed on the current unmetered network.");
            }

            var reason = "Windows reports the current connection as " + FormatNetworkCostType(networkCostType) + ".";
            if (roaming)
            {
                reason += " The connection is roaming.";
            }

            if (overDataLimit)
            {
                reason += " The connection is over its data limit.";
            }

            if (approachingDataLimit)
            {
                reason += " The connection is approaching its data limit.";
            }

            return StorageNetworkPolicyResult.Blocked(
                "Storage requires an unmetered network. "
                + reason
                + " Connect to an unmetered network or turn off this storage setting.");
        }

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            try
            {
                NetworkInformation.NetworkStatusChanged -= _networkStatusChangedHandler;
            }
            catch
            {
            }

            _disposed = true;
        }

        private static string FormatNetworkCostType(NetworkCostType networkCostType)
        {
            switch (networkCostType)
            {
                case NetworkCostType.Unrestricted:
                    return "unmetered";
                case NetworkCostType.Fixed:
                    return "capped or fixed-cost";
                case NetworkCostType.Variable:
                    return "metered or variable-cost";
                default:
                    return "unknown-cost";
            }
        }
    }

    public sealed class StorageNetworkPolicyResult
    {
        private StorageNetworkPolicyResult(bool storageAllowed, string message)
        {
            StorageAllowed = storageAllowed;
            Message = message;
        }

        public bool StorageAllowed { get; }

        public string Message { get; }

        public static StorageNetworkPolicyResult Allowed(string message)
        {
            return new StorageNetworkPolicyResult(true, message);
        }

        public static StorageNetworkPolicyResult Blocked(string message)
        {
            return new StorageNetworkPolicyResult(false, message);
        }
    }
}
