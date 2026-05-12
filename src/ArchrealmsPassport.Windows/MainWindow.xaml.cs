using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using ArchrealmsPassport.Windows.Services;
using ArchrealmsPassport.Windows.ViewModels;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace ArchrealmsPassport.Windows
{
    public partial class MainWindow : Window
    {
        private Forms.NotifyIcon? _trayIcon;
        private Drawing.Icon? _trayIconImage;
        private bool _trayNoticeShown;
        private bool _allowExit;

        public MainWindow()
        {
            InitializeComponent();

            var scriptRunner = new PowerShellScriptRunner();
            var localNodeService = new LocalNodeService(scriptRunner);
            var networkUsageService = new NetworkUsageService();

            DataContext = new PassportMainViewModel(
                new PassportSettingsStore(),
                new PassportStatusService(localNodeService),
                localNodeService,
                new PassportRecordService(),
                new PassportCryptoService(),
                networkUsageService);

            InitializeTrayIcon();
        }

        private void InitializeTrayIcon()
        {
            _trayIconImage = LoadTrayIcon();

            var openItem = new Forms.ToolStripMenuItem("Open Archrealms Passport");
            openItem.Click += delegate { RestoreFromTray(); };

            var exitItem = new Forms.ToolStripMenuItem("Exit");
            exitItem.Click += delegate { ExitFromTray(); };

            var contextMenu = new Forms.ContextMenuStrip();
            contextMenu.Items.Add(openItem);
            contextMenu.Items.Add(new Forms.ToolStripSeparator());
            contextMenu.Items.Add(exitItem);

            _trayIcon = new Forms.NotifyIcon
            {
                ContextMenuStrip = contextMenu,
                Icon = _trayIconImage,
                Text = "Archrealms Passport",
                Visible = true
            };
            _trayIcon.DoubleClick += delegate { RestoreFromTray(); };

            StateChanged += MainWindow_StateChanged;
            Closing += MainWindow_Closing;
        }

        private void MainWindow_StateChanged(object? sender, EventArgs e)
        {
            if (WindowState == WindowState.Minimized)
            {
                KeepRunningInTaskbar();
            }
        }

        private void MainWindow_Closing(object? sender, CancelEventArgs e)
        {
            if (!_allowExit)
            {
                e.Cancel = true;
                KeepRunningInTaskbar();
                return;
            }

            StateChanged -= MainWindow_StateChanged;
            Closing -= MainWindow_Closing;
            if (DataContext is IDisposable disposable)
            {
                disposable.Dispose();
                DataContext = null;
            }

            DisposeTrayIcon();
        }

        private void KeepRunningInTaskbar()
        {
            ShowInTaskbar = true;
            if (WindowState != WindowState.Minimized)
            {
                WindowState = WindowState.Minimized;
            }

            if (!_trayNoticeShown && _trayIcon != null)
            {
                _trayNoticeShown = true;
                _trayIcon.ShowBalloonTip(
                    2500,
                    "Archrealms Passport",
                    "Passport is still running. Use the taskbar or tray icon to reopen it.",
                    Forms.ToolTipIcon.Info);
            }
        }

        private void RestoreFromTray()
        {
            if (!Dispatcher.CheckAccess())
            {
                Dispatcher.Invoke(RestoreFromTray);
                return;
            }

            ShowInTaskbar = true;
            Show();

            if (WindowState == WindowState.Minimized)
            {
                WindowState = WindowState.Normal;
            }

            Activate();
        }

        private void ExitFromTray()
        {
            if (!Dispatcher.CheckAccess())
            {
                Dispatcher.Invoke(ExitFromTray);
                return;
            }

            _allowExit = true;
            Close();
        }

        private void DisposeTrayIcon()
        {
            if (_trayIcon != null)
            {
                var contextMenu = _trayIcon.ContextMenuStrip;
                _trayIcon.Visible = false;
                _trayIcon.Dispose();
                contextMenu?.Dispose();
                _trayIcon = null;
            }

            _trayIconImage?.Dispose();
            _trayIconImage = null;
        }

        private static Drawing.Icon LoadTrayIcon()
        {
            try
            {
                var executablePath = Process.GetCurrentProcess().MainModule?.FileName;
                if (!string.IsNullOrWhiteSpace(executablePath) && File.Exists(executablePath))
                {
                    var associatedIcon = Drawing.Icon.ExtractAssociatedIcon(executablePath);
                    if (associatedIcon != null)
                    {
                        return associatedIcon;
                    }
                }
            }
            catch
            {
            }

            return (Drawing.Icon)Drawing.SystemIcons.Application.Clone();
        }
    }
}
