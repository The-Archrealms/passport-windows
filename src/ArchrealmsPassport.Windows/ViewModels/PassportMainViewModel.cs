using System.ComponentModel;
using System.Windows.Input;
using ArchrealmsPassport.Windows.Commands;
using ArchrealmsPassport.Windows.Services;

namespace ArchrealmsPassport.Windows.ViewModels
{
    public sealed partial class PassportMainViewModel : INotifyPropertyChanged
    {
        private readonly PassportSettingsStore _settingsStore;
        private readonly PassportStatusService _statusService;
        private readonly PowerShellScriptRunner _scriptRunner;
        private readonly PassportRecordService _recordService;
        private readonly PassportCryptoService _cryptoService;
        private readonly string _toolRoot;
        private readonly AsyncRelayCommand _saveSettingsCommand;
        private readonly AsyncRelayCommand _refreshStatusCommand;
        private readonly AsyncRelayCommand _initializeNodeCommand;
        private readonly AsyncRelayCommand _provisionIdentityCommand;
        private readonly AsyncRelayCommand _approveJoinRequestCommand;
        private readonly AsyncRelayCommand _importJoinApprovalCommand;
        private readonly AsyncRelayCommand _generateChallengeCommand;
        private readonly AsyncRelayCommand _signChallengeCommand;
        private readonly AsyncRelayCommand _createRegistrySubmissionCommand;
        private readonly AsyncRelayCommand _publishRegistrySubmissionCommand;

        private string _citizenName = string.Empty;
        private string _selectedProvisioningMode = "Create new Passport identity";
        private string _selectedIdentityMode = "pseudonymous";
        private string _existingIdentityId = string.Empty;
        private string _activeIdentityId = string.Empty;
        private string _activeDeviceId = string.Empty;
        private string _activeDeviceKeyPath = string.Empty;
        private string _pendingDeviceId = string.Empty;
        private string _pendingDeviceKeyPath = string.Empty;
        private string _deviceLabel = string.Empty;
        private string _joinRequestPath = string.Empty;
        private string _joinApprovalPath = string.Empty;
        private string _challengeText = string.Empty;
        private string _challengeSignatureText = "No signed challenge yet";
        private string _registrySubmissionText = "No registry submission package yet";
        private string _registrySubmissionCidText = "Not published";
        private string _workspaceRoot = string.Empty;
        private string _ipfsRepoPath = string.Empty;
        private double _storageAllocationGb = 25;
        private bool _participateInPublicRegistry = true;
        private bool _preferWindowsHelloCredentials;
        private bool _publishCarExports = true;
        private bool _preferWifiOnly;
        private string _workspaceStateText = "Workspace unavailable";
        private string _ipfsStateText = "ipfs.exe not detected";
        private string _nodeStateText = "Node not initialized";
        private string _verificationStateText = "No submission package yet";
        private string _activityLog = string.Empty;

        public PassportMainViewModel(
            PassportSettingsStore settingsStore,
            PassportStatusService statusService,
            PowerShellScriptRunner scriptRunner,
            PassportRecordService recordService,
            PassportCryptoService cryptoService)
        {
            _settingsStore = settingsStore;
            _statusService = statusService;
            _scriptRunner = scriptRunner;
            _recordService = recordService;
            _cryptoService = cryptoService;
            _toolRoot = PassportEnvironment.FindToolRoot();

            _saveSettingsCommand = new AsyncRelayCommand(SaveSettingsAsync);
            _refreshStatusCommand = new AsyncRelayCommand(RefreshStatusAsync);
            _initializeNodeCommand = new AsyncRelayCommand(InitializeNodeAsync, CanRunWorkspaceAction);
            _provisionIdentityCommand = new AsyncRelayCommand(ProvisionIdentityAsync, CanProvisionIdentity);
            _approveJoinRequestCommand = new AsyncRelayCommand(ApproveJoinRequestAsync, CanApproveJoinRequest);
            _importJoinApprovalCommand = new AsyncRelayCommand(ImportJoinApprovalAsync, CanImportJoinApproval);
            _generateChallengeCommand = new AsyncRelayCommand(GenerateChallengeAsync);
            _signChallengeCommand = new AsyncRelayCommand(SignChallengeAsync, CanUseActiveDeviceCredential);
            _createRegistrySubmissionCommand = new AsyncRelayCommand(CreateRegistrySubmissionAsync, CanUseActiveDeviceCredential);
            _publishRegistrySubmissionCommand = new AsyncRelayCommand(PublishRegistrySubmissionAsync, CanPublishRegistrySubmission);

            SaveSettingsCommand = _saveSettingsCommand;
            RefreshStatusCommand = _refreshStatusCommand;
            InitializeNodeCommand = _initializeNodeCommand;
            ProvisionIdentityCommand = _provisionIdentityCommand;
            ApproveJoinRequestCommand = _approveJoinRequestCommand;
            ImportJoinApprovalCommand = _importJoinApprovalCommand;
            GenerateChallengeCommand = _generateChallengeCommand;
            SignChallengeCommand = _signChallengeCommand;
            CreateRegistrySubmissionCommand = _createRegistrySubmissionCommand;
            PublishRegistrySubmissionCommand = _publishRegistrySubmissionCommand;

            LoadSettings();
            _ = RefreshStatusAsync();
        }

        public event PropertyChangedEventHandler? PropertyChanged;

        public ICommand SaveSettingsCommand { get; private set; }
        public ICommand RefreshStatusCommand { get; private set; }
        public ICommand InitializeNodeCommand { get; private set; }
        public ICommand ProvisionIdentityCommand { get; private set; }
        public ICommand ApproveJoinRequestCommand { get; private set; }
        public ICommand ImportJoinApprovalCommand { get; private set; }
        public ICommand GenerateChallengeCommand { get; private set; }
        public ICommand SignChallengeCommand { get; private set; }
        public ICommand CreateRegistrySubmissionCommand { get; private set; }
        public ICommand PublishRegistrySubmissionCommand { get; private set; }
    }
}
