using System.Net;

namespace Tallow.ManagedBuild.Export;

/// <summary><c>serve &lt;folder&gt; [--port N]</c>: serves a folder of web builds on 127.0.0.1 for trying them in a
/// browser (a page loaded from a file cannot fetch its own assets). It sends the cross-origin isolation headers too,
/// so a threaded build runs without its service worker. Runs until stopped.</summary>
internal static class WebServer
{
    static readonly Dictionary<string, string> Types = new(StringComparer.OrdinalIgnoreCase)
    {
        [".html"] = "text/html; charset=utf-8", [".js"] = "text/javascript", [".mjs"] = "text/javascript", [".wasm"] = "application/wasm",
        [".json"] = "application/json", [".webmanifest"] = "application/manifest+json", [".css"] = "text/css", [".png"] = "image/png",
        [".jpg"] = "image/jpeg", [".svg"] = "image/svg+xml", [".ico"] = "image/x-icon", [".txt"] = "text/plain; charset=utf-8",
    };

    public static int Run(string[] args)
    {
        string? folder = null;
        int port = 8765;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--port" && i + 1 < args.Length && int.TryParse(args[i + 1], out int chosen))
                port = chosen;
            else if (args[i] == "--port")
                continue;
            else if (!args[i].StartsWith("--", StringComparison.Ordinal) && (i == 0 || args[i - 1] != "--port"))
                folder = Path.GetFullPath(args[i]);
        }
        if (folder == null || !Directory.Exists(folder))
        {
            Console.Error.WriteLine("usage: serve <folder> [--port N]");
            return 2;
        }
        using var listener = new HttpListener();
        listener.Prefixes.Add($"http://127.0.0.1:{port}/");
        try
        {
            listener.Start();
        }
        catch (HttpListenerException exception)
        {
            Console.Error.WriteLine($"Cannot serve on port {port}: {exception.Message}");
            return 1;
        }
        Console.WriteLine($"Serving {folder} at http://127.0.0.1:{port}/");
        while (listener.IsListening)
        {
            HttpListenerContext context = listener.GetContext();
            _ = Task.Run(() => Answer(context, folder));
        }
        return 0;
    }

    static void Answer(HttpListenerContext context, string root)
    {
        var response = context.Response;
        try
        {
            string relative = Uri.UnescapeDataString(context.Request.Url?.AbsolutePath ?? "/").TrimStart('/');
            string path = Path.GetFullPath(Path.Combine(root, relative));
            if (!path.StartsWith(root, StringComparison.Ordinal))
            {
                response.StatusCode = 403;
                return;
            }
            if (Directory.Exists(path))
            {
                if (!context.Request.Url!.AbsolutePath.EndsWith('/'))
                {
                    response.Redirect(context.Request.Url.AbsolutePath + "/");
                    return;
                }
                path = Path.Combine(path, "index.html");
            }
            if (!File.Exists(path))
            {
                response.StatusCode = 404;
                return;
            }
            response.ContentType = Types.TryGetValue(Path.GetExtension(path), out string? type) ? type : "application/octet-stream";
            response.Headers["Cross-Origin-Opener-Policy"] = "same-origin";
            response.Headers["Cross-Origin-Embedder-Policy"] = "require-corp";
            response.Headers["Cache-Control"] = "no-cache";
            using var file = File.OpenRead(path);
            response.ContentLength64 = file.Length;
            if (context.Request.HttpMethod != "HEAD")
                file.CopyTo(response.OutputStream);
        }
        catch (Exception exception) when (exception is IOException or HttpListenerException or UnauthorizedAccessException)
        {
            response.StatusCode = 500;
        }
        finally
        {
            try
            {
                response.Close();
            }
            catch (Exception exception) when (exception is IOException or HttpListenerException or ObjectDisposedException)
            {
            }
        }
    }
}
