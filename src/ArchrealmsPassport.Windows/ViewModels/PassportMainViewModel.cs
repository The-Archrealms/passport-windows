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
        private readonly LocalNodeService _localNodeService;
        private readonly PassportRecordService _recordService;
        private readonly PassportCryptoService _cryptoService;
        private readonly string _toolRoot;
        private readonly AsyncRelayCommand _saveSettingsCommand;
        private readonly AsyncRelayCommand _refreshStatusCommand;
        private readonly AsyncRelayCommand _initializeNodeCommand;
        private readonly AsyncRelayCommand _startNodeCommand;
        private readonly AsyncRelayCommand _stopNodeCommand;
        private readonly AsyncRelayCommand _restartNodeCommand;
        private readonly AsyncRelayCommand _repairNodeCommand;
        private readonly AsyncRelayCommand _writeNodeDiagnosticsCommand;
        private readonly AsyncRelayCommand _recordNodeCapacitySnapshotCommand;
        private readonly AsyncRelayCommand _acknowledgeStorageAssignmentCommand;
        private readonly AsyncRelayCommand _createStorageEpochProofCommand;
        private readonly AsyncRelayCommand _createLocalMeteringStatusCommand;
        private readonly AsyncRelayCommand _verifyLocalMeteringRecordsCommand;
        private readonly AsyncRelayCommand _provisionIdentityCommand;
        private readonly AsyncRelayCommand _approveJoinRequestCommand;
        private readonly AsyncRelayCommand _importJoinApprovalCommand;
        private readonly AsyncRelayCommand _generateChallengeCommand;
        private readonly AsyncRelayCommand _signChallengeCommand;
        private readonly AsyncRelayCommand _createRegistrySubmissionCommand;
        private readonly AsyncRelayCommand _publishRegistrySubmissionCommand;
        private readonly AsyncRelayCommand _previewReadOnlyIpfsFileCommand;
        private readonly AsyncRelayCommand _fetchReadOnlyIpfsFileCommand;
        private readonly AsyncRelayCommand _exportCarCommand;
        private readonly AsyncRelayCommand _primaryActionCommand;

        private string _citizenName = string.Empty;
        private string _selectedProvisioningMode = "Create new Passport identity";
        private string _selectedIdentityMode = "named";
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
        private string _registrySubmissionText = "No registration package yet";
        private string _registrySubmissionCidText = "Not published";
        private string _readOnlyIpfsCid = string.Empty;
        private string _readOnlyIpfsRelativePath = string.Empty;
        private string _readOnlyIpfsPreviewText = "No IPFS file preview yet";
        private string _readOnlyIpfsFetchedPathText = "No read-only copy yet";
        private string _latestCarExportText = "No CAR export yet";
        private string _latestNodeCapacitySnapshotText = "No node capacity snapshot yet";
        private string _latestNodeDiagnosticsText = "No node diagnostics report yet";
        private string _storageAssignmentId = string.Empty;
        private string _storageAssignmentCid = string.Empty;
        private string _storageAssignmentManifestSha256 = string.Empty;
        private string _storageAssignmentServiceClass = "stewarded_archive_storage";
        private double _storageAssignmentBytes;
        private string _latestStorageAssignmentAcknowledgmentText = "No storage assignment acknowledgment yet";
        private string _storageProofSourceFilePath = string.Empty;
        private string _latestStorageEpochProofText = "No storage epoch proof yet";
        private string _latestLocalMeteringStatusText = "No local metering status yet";
        private string _localMeteringSummaryText = "No submitted proof summary yet";
        private string _latestLocalMeteringVerificationText = "No local metering verification report yet";
        private string _activeNodeId = string.Empty;
        private string _workspaceRoot = string.Empty;
        private string _ipfsRepoPath = string.Empty;
        private string _ipfsCliPathOverride = string.Empty;
        private double _storageAllocationGb = 25;
        private string _nodeParticipationMode = "Public archive contributor";
        private string _nodeCachePolicy = "Balanced pinned archive";
        private bool _participateInPublicRegistry = true;
        private bool _preferWindowsHelloCredentials;
        private bool _bootstrapLocalNodeOnOnboarding = true;
        private bool _publishCarExports = true;
        private bool _preferWifiOnly;
        private string _workspaceStateText = "Workspace unavailable";
        private string _ipfsStateText = "No IPFS runtime detected";
        private string _resolvedIpfsCliPathText = "No runtime resolved";
        private string _nodeStateText = "Node not initialized";
        private string _verificationStateText = "No submission package yet";
        private string _storageActionStatusText = "Storage has not been enabled yet.";
        private string _activityLog = string.Empty;

        public PassportMainViewModel(
            PassportSettingsStore settingsStore,
            PassportStatusService statusService,
            LocalNodeService localNodeService,
            PassportRecordService recordService,
            PassportCryptoService cryptoService)
        {
            _settingsStore = settingsStore;
            _statusService = statusService;
            _localNodeService = localNodeService;
            _recordService = recordService;
            _cryptoService = cryptoService;
            _toolRoot = PassportEnvironment.FindToolRoot();

            _saveSettingsCommand = new AsyncRelayCommand(SaveSettingsAsync);
            _refreshStatusCommand = new AsyncRelayCommand(RefreshStatusAsync);
            _initializeNodeCommand = new AsyncRelayCommand(InitializeNodeAsync, CanRunWorkspaceAction);
            _startNodeCommand = new AsyncRelayCommand(StartNodeAsync, CanRunWorkspaceAction);
            _stopNodeCommand = new AsyncRelayCommand(StopNodeAsync, CanRunWorkspaceAction);
            _restartNodeCommand = new AsyncRelayCommand(RestartNodeAsync, CanRunWorkspaceAction);
            _repairNodeCommand = new AsyncRelayCommand(RepairNodeAsync, CanRunWorkspaceAction);
            _writeNodeDiagnosticsCommand = new AsyncRelayCommand(WriteNodeDiagnosticsAsync, CanRunWorkspaceAction);
            _recordNodeCapacitySnapshotCommand = new AsyncRelayCommand(RecordNodeCapacitySnapshotAsync, CanUseActiveDeviceCredential);
            _acknowledgeStorageAssignmentCommand = new AsyncRelayCommand(AcknowledgeStorageAssignmentAsync, CanAcknowledgeStorageAssignment);
            _createStorageEpochProofCommand = new AsyncRelayCommand(CreateStorageEpochProofAsync, CanCreateStorageEpochProof);
            _createLocalMeteringStatusCommand = new AsyncRelayCommand(CreateLocalMeteringStatusAsync, CanUseActiveDeviceCredential);
            _verifyLocalMeteringRecordsCommand = new AsyncRelayCommand(VerifyLocalMeteringRecordsAsync, CanUseActiveDeviceCredential);
            _provisionIdentityCommand = new AsyncRelayCommand(ProvisionIdentityAsync, CanProvisionIdentity);
            _approveJoinRequestCommand = new AsyncRelayCommand(ApproveJoinRequestAsync, CanApproveJoinRequest);
            _importJoinApprovalCommand = new AsyncRelayCommand(ImportJoinApprovalAsync, CanImportJoinApproval);
            _generateChallengeCommand = new AsyncRelayCommand(GenerateChallengeAsync);
            _signChallengeCommand = new AsyncRelayCommand(SignChallengeAsync, CanUseActiveDeviceCredential);
            _createRegistrySubmissionCommand = new AsyncRelayCommand(RegisterWithArchrealmsAsync, CanRegisterWithArchrealms);
            _publishRegistrySubmissionCommand = new AsyncRelayCommand(PublishRegistrySubmissionAsync, CanPublishRegistrySubmission);
            _previewReadOnlyIpfsFileCommand = new AsyncRelayCommand(PreviewReadOnlyIpfsFileAsync, CanReadOnlyAccessIpfsFile);
            _fetchReadOnlyIpfsFileCommand = new AsyncRelayCommand(FetchReadOnlyIpfsFileAsync, CanReadOnlyAccessIpfsFile);
            _exportCarCommand = new AsyncRelayCommand(ExportCarAsync, CanReadOnlyAccessIpfsFile);
            _primaryActionCommand = new AsyncRelayCommand(ExecutePrimaryActionAsync, CanExecutePrimaryAction);

            SaveSettingsCommand = _saveSettingsCommand;
            RefreshStatusCommand = _refreshStatusCommand;
            InitializeNodeCommand = _initializeNodeCommand;
            StartNodeCommand = _startNodeCommand;
            StopNodeCommand = _stopNodeCommand;
            RestartNodeCommand = _restartNodeCommand;
            RepairNodeCommand = _repairNodeCommand;
            WriteNodeDiagnosticsCommand = _writeNodeDiagnosticsCommand;
            RecordNodeCapacitySnapshotCommand = _recordNodeCapacitySnapshotCommand;
            AcknowledgeStorageAssignmentCommand = _acknowledgeStorageAssignmentCommand;
            CreateStorageEpochProofCommand = _createStorageEpochProofCommand;
            CreateLocalMeteringStatusCommand = _createLocalMeteringStatusCommand;
            VerifyLocalMeteringRecordsCommand = _verifyLocalMeteringRecordsCommand;
            ProvisionIdentityCommand = _provisionIdentityCommand;
            ApproveJoinRequestCommand = _approveJoinRequestCommand;
            ImportJoinApprovalCommand = _importJoinApprovalCommand;
            GenerateChallengeCommand = _generateChallengeCommand;
            SignChallengeCommand = _signChallengeCommand;
            CreateRegistrySubmissionCommand = _createRegistrySubmissionCommand;
            PublishRegistrySubmissionCommand = _publishRegistrySubmissionCommand;
            PreviewReadOnlyIpfsFileCommand = _previewReadOnlyIpfsFileCommand;
            FetchReadOnlyIpfsFileCommand = _fetchReadOnlyIpfsFileCommand;
            ExportCarCommand = _exportCarCommand;
            PrimaryActionCommand = _primaryActionCommand;

            LoadSettings();
            _ = RefreshStatusAsync();
        }

        public event PropertyChangedEventHandler? PropertyChanged;

        public ICommand SaveSettingsCommand { get; private set; }
        public ICommand RefreshStatusCommand { get; private set; }
        public ICommand InitializeNodeCommand { get; private set; }
        public ICommand StartNodeCommand { get; private set; }
        public ICommand StopNodeCommand { get; private set; }
        public ICommand RestartNodeCommand { get; private set; }
        public ICommand RepairNodeCommand { get; private set; }
        public ICommand WriteNodeDiagnosticsCommand { get; private set; }
        public ICommand RecordNodeCapacitySnapshotCommand { get; private set; }
        public ICommand AcknowledgeStorageAssignmentCommand { get; private set; }
        public ICommand CreateStorageEpochProofCommand { get; private set; }
        public ICommand CreateLocalMeteringStatusCommand { get; private set; }
        public ICommand VerifyLocalMeteringRecordsCommand { get; private set; }
        public ICommand ProvisionIdentityCommand { get; private set; }
        public ICommand ApproveJoinRequestCommand { get; private set; }
        public ICommand ImportJoinApprovalCommand { get; private set; }
        public ICommand GenerateChallengeCommand { get; private set; }
        public ICommand SignChallengeCommand { get; private set; }
        public ICommand CreateRegistrySubmissionCommand { get; private set; }
        public ICommand PublishRegistrySubmissionCommand { get; private set; }
        public ICommand PreviewReadOnlyIpfsFileCommand { get; private set; }
        public ICommand FetchReadOnlyIpfsFileCommand { get; private set; }
        public ICommand ExportCarCommand { get; private set; }
        public ICommand PrimaryActionCommand { get; private set; }
    }
}
