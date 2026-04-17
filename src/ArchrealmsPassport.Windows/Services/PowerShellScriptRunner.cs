using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace ArchrealmsPassport.Windows.Services
{
    public sealed class PowerShellScriptRunner
    {
        public async Task<ScriptRunResult> RunAsync(
            string toolRoot,
            string workingDirectory,
            string scriptRelativePath,
            IReadOnlyList<string> arguments,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            var scriptPath = Path.Combine(toolRoot, scriptRelativePath);
            if (!File.Exists(scriptPath))
            {
                return ScriptRunResult.Failure("Missing script: " + scriptPath);
            }

            var processStartInfo = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                WorkingDirectory = workingDirectory,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };

            processStartInfo.ArgumentList.Add("-NoProfile");
            processStartInfo.ArgumentList.Add("-ExecutionPolicy");
            processStartInfo.ArgumentList.Add("Bypass");
            processStartInfo.ArgumentList.Add("-File");
            processStartInfo.ArgumentList.Add(scriptPath);

            foreach (var argument in arguments)
            {
                processStartInfo.ArgumentList.Add(argument);
            }

            using (var process = new Process { StartInfo = processStartInfo })
            {
                var stdout = new StringBuilder();
                var stderr = new StringBuilder();

                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
                {
                    if (eventArgs.Data != null)
                    {
                        stdout.AppendLine(eventArgs.Data);
                    }
                };

                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
                {
                    if (eventArgs.Data != null)
                    {
                        stderr.AppendLine(eventArgs.Data);
                    }
                };

                process.Start();
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();

                await WaitForExitAsync(process, cancellationToken).ConfigureAwait(false);

                return new ScriptRunResult(
                    process.ExitCode == 0,
                    process.ExitCode,
                    stdout.ToString().Trim(),
                    stderr.ToString().Trim());
            }
        }

        private static Task WaitForExitAsync(Process process, CancellationToken cancellationToken)
        {
            var completion = new TaskCompletionSource<bool>();
            process.EnableRaisingEvents = true;
            process.Exited += delegate { completion.TrySetResult(true); };

            if (process.HasExited)
            {
                completion.TrySetResult(true);
            }

            if (cancellationToken != default(CancellationToken))
            {
                cancellationToken.Register(delegate { completion.TrySetCanceled(); });
            }

            return completion.Task;
        }
    }

    public sealed class ScriptRunResult
    {
        public ScriptRunResult(bool succeeded, int exitCode, string stdout, string stderr)
        {
            Succeeded = succeeded;
            ExitCode = exitCode;
            Stdout = stdout;
            Stderr = stderr;
        }

        public bool Succeeded { get; private set; }

        public int ExitCode { get; private set; }

        public string Stdout { get; private set; }

        public string Stderr { get; private set; }

        public static ScriptRunResult Failure(string message)
        {
            return new ScriptRunResult(false, -1, string.Empty, message);
        }
    }
}
