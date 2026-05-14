using System.Threading.Tasks;
using ArchrealmsPassport.Windows.Services;

namespace ArchrealmsPassport.Windows.ViewModels
{
    public sealed partial class PassportMainViewModel
    {
        private Task RefreshRegistryBrowserAsync()
        {
            var service = new PassportRegistryBrowserService();
            var records = service.ListRecords(WorkspaceRoot, RegistryFilterText);

            RegistryBrowserSummaryText = records.Count == 1
                ? "1 registry record"
                : records.Count + " registry records";
            RegistryRecordListText = service.FormatRecordList(records);
            AppendLog("Refreshed registry browser: " + RegistryBrowserSummaryText + ".");
            return Task.CompletedTask;
        }

        private bool CanRefreshRegistryBrowser()
        {
            return CanRunWorkspaceAction();
        }
    }
}
