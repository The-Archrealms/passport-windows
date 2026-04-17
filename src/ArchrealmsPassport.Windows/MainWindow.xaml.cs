using System.Windows;
using ArchrealmsPassport.Windows.Services;
using ArchrealmsPassport.Windows.ViewModels;

namespace ArchrealmsPassport.Windows
{
    public partial class MainWindow : Window
    {
        public MainWindow()
        {
            InitializeComponent();

            DataContext = new PassportMainViewModel(
                new PassportSettingsStore(),
                new PassportStatusService(),
                new PowerShellScriptRunner(),
                new PassportRecordService(),
                new PassportCryptoService());
        }
    }
}
