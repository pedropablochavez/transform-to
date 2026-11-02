using System.IO.Pipes;
using System.Text;

namespace TransformTo;

/// <summary>
/// When you select 100 files and pick "Transform to > PNG", Explorer starts TransformTo.exe 100 times, one file each.
/// The first process to start becomes the "collector": it listens on a named pipe and the other processes hand it
/// their file and exit, so the whole selection is converted in one batch with a single progress window.
/// </summary>
static class FileCollector
{
    // How long the collector keeps waiting after the last file arrived. Explorer launches the processes one after
    // another, so a short quiet period means the selection is complete.
    static readonly TimeSpan QuietPeriod = TimeSpan.FromMilliseconds(900);

    /// <summary>
    /// Returns every file to convert if this process is the collector, or null if the files were handed to another
    /// process (in which case this process should just exit).
    /// </summary>
    public static List<string>? Collect(string targetId, IReadOnlyList<string> myFiles)
    {
        var session = System.Diagnostics.Process.GetCurrentProcess().SessionId;
        var key = $"TransformTo-{Environment.UserName}-{session}-{targetId}";
        key = string.Concat(key.Select(c => char.IsLetterOrDigit(c) || c == '-' ? c : '_'));

        using var mutex = new Mutex(false, @"Local\" + key);
        if (!TryAcquire(mutex, TimeSpan.Zero))
        {
            if (TrySendToCollector(key, myFiles))
                return null;
            // The collector stopped listening before we got through; wait for it to let go and collect ourselves.
            TryAcquire(mutex, Timeout.InfiniteTimeSpan);
        }

        try
        {
            return Listen(key, myFiles);
        }
        finally
        {
            mutex.ReleaseMutex();
        }
    }

    static bool TryAcquire(Mutex mutex, TimeSpan timeout)
    {
        try
        {
            return mutex.WaitOne(timeout);
        }
        catch (AbandonedMutexException)
        {
            return true; // previous collector crashed; the mutex is ours now
        }
    }

    static List<string> Listen(string pipeName, IReadOnlyList<string> myFiles)
    {
        var files = new List<string>(myFiles);
        while (true)
        {
            using var server = new NamedPipeServerStream(pipeName, PipeDirection.InOut,
                NamedPipeServerStream.MaxAllowedServerInstances, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
            using var timeout = new CancellationTokenSource(QuietPeriod);
            try
            {
                server.WaitForConnectionAsync(timeout.Token).GetAwaiter().GetResult();
            }
            catch (OperationCanceledException)
            {
                return files;
            }

            try
            {
                using var reader = new StreamReader(server, Encoding.UTF8, leaveOpen: true);
                string? line;
                var received = new List<string>();
                while (!string.IsNullOrEmpty(line = reader.ReadLine()))
                    received.Add(line);
                server.WriteByte(1); // ack: "I have your files, you can exit"
                server.Flush();
                files.AddRange(received);
            }
            catch (IOException)
            {
                // Client vanished mid-message; it will fall back to converting its own file.
            }
        }
    }

    static bool TrySendToCollector(string pipeName, IReadOnlyList<string> files)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut);
            client.Connect(3000);
            var payload = Encoding.UTF8.GetBytes(string.Join('\n', files) + "\n\n");
            client.Write(payload);
            client.Flush();
            return client.ReadByte() == 1;
        }
        catch (Exception ex) when (ex is TimeoutException or IOException)
        {
            return false;
        }
    }
}
