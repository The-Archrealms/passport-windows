using System.Threading;
using System.Threading.Tasks;

namespace ArchrealmsPassport.Windows.Services
{
    public interface ILocalNodeService
    {
        Task<LocalNodeOperationResult> InitializeAsync(
            string toolRoot,
            string workspaceRoot,
            string ipfsRepoPath,
            double storageAllocationGb,
            string participationMode,
            string cachePolicy,
            int storageGcWatermark,
            string provideStrategy,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken));

        Task<LocalNodeOperationResult> StartAsync(
            string toolRoot,
            string workspaceRoot,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken));

        Task<LocalNodeOperationResult> RepairAsync(
            string toolRoot,
            string workspaceRoot,
            string ipfsRepoPath,
            double storageAllocationGb,
            string participationMode,
            string cachePolicy,
            int storageGcWatermark,
            string provideStrategy,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken));

        Task<LocalNodeOperationResult> StopAsync(
            string toolRoot,
            string workspaceRoot,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken));

        Task<LocalNodeOperationResult> RestartAsync(
            string toolRoot,
            string workspaceRoot,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken));

        Task<LocalNodeOperationResult> WriteDiagnosticsAsync(
            string toolRoot,
            string workspaceRoot,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken));

        Task<LocalNodeOperationResult> ExportCarAsync(
            string toolRoot,
            string workspaceRoot,
            string cid,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken));

        Task<LocalNodeOperationResult> PublishRegistrySubmissionAsync(
            string toolRoot,
            string workspaceRoot,
            string submissionPath,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            bool exportCar,
            CancellationToken cancellationToken = default(CancellationToken));

        Task<LocalNodeOperationResult> PreviewReadOnlyIpfsFileAsync(
            string toolRoot,
            string workspaceRoot,
            string cid,
            string relativePath,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken));

        Task<LocalNodeOperationResult> FetchReadOnlyIpfsFileAsync(
            string toolRoot,
            string workspaceRoot,
            string cid,
            string relativePath,
            string ipfsRepoPath,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken));

        Task<LocalNodeHealthSnapshot> GetHealthAsync(
            string workspaceRoot,
            string ipfsRepoPath,
            string toolRoot,
            string ipfsCliPathOverride,
            CancellationToken cancellationToken = default(CancellationToken));
    }
}
