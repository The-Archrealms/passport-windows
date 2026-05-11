using System;
using System.Collections.Generic;
using System.Runtime.ExceptionServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using ArchrealmsPassport.Windows.Commands;
using Xunit;

namespace ArchrealmsPassport.Windows.Tests;

public sealed class AsyncRelayCommandTests
{
    [Fact]
    public void ExecuteRaisesCompletionCanExecuteChangedOnApplicationDispatcher()
    {
        Exception? threadException = null;
        var completed = new ManualResetEventSlim(false);
        var eventThreadIds = new List<int>();
        var uiThreadId = 0;

        var thread = new Thread(() =>
        {
            try
            {
                var application = Application.Current ?? new Application
                {
                    ShutdownMode = ShutdownMode.OnExplicitShutdown
                };
                uiThreadId = Environment.CurrentManagedThreadId;

                var releaseCommand = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                var command = new AsyncRelayCommand(async delegate
                {
                    await Task.Run(async delegate { await releaseCommand.Task; });
                });

                var frame = new DispatcherFrame();
                var timeout = new DispatcherTimer
                {
                    Interval = TimeSpan.FromSeconds(5)
                };
                timeout.Tick += delegate
                {
                    timeout.Stop();
                    frame.Continue = false;
                };

                command.CanExecuteChanged += delegate
                {
                    eventThreadIds.Add(Environment.CurrentManagedThreadId);
                    if (eventThreadIds.Count >= 2)
                    {
                        frame.Continue = false;
                    }
                };

                command.Execute(null);
                ThreadPool.QueueUserWorkItem(_ => releaseCommand.SetResult());
                timeout.Start();
                Dispatcher.PushFrame(frame);
                timeout.Stop();

                if (eventThreadIds.Count < 2)
                {
                    throw new TimeoutException("The command did not raise both command-state notifications.");
                }

                application.Shutdown();
            }
            catch (Exception ex)
            {
                threadException = ex;
            }
            finally
            {
                completed.Set();
            }
        });

        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        Assert.True(completed.Wait(TimeSpan.FromSeconds(10)), "The WPF dispatcher test did not complete.");
        if (threadException != null)
        {
            ExceptionDispatchInfo.Capture(threadException).Throw();
        }

        Assert.All(eventThreadIds, eventThreadId => Assert.Equal(uiThreadId, eventThreadId));
    }
}
