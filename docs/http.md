# Downloads and zip files

For games that fetch content (news, level packs, leaderboards), launchers and updaters.

C# scripts use .NET's own `HttpClient` (`System.Net.Http` is imported in every script) and
`System.IO.Compression.ZipFile`. An `await` carries on on the game thread, so the result can be used on objects
straight away:

```csharp
using System.IO.Compression;

static readonly HttpClient Client = new() { DefaultRequestHeaders = { { "User-Agent", "MyGame" } } };

string releases = await Client.GetStringAsync("https://api.github.com/repos/owner/repo/releases");

// A file, with progress:
using (HttpResponseMessage response = await Client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead))
{
    response.EnsureSuccessStatusCode();
    long total = response.Content.Headers.ContentLength ?? -1;
    await using Stream input = await response.Content.ReadAsStreamAsync();
    await using FileStream output = File.Create(path + ".part");
    var buffer = new byte[81920];
    long done = 0;
    for (int read; (read = await input.ReadAsync(buffer)) > 0; done += read)
    {
        await output.WriteAsync(buffer.AsMemory(0, read));
        progress = total > 0 ? (float)done / total : -1;
    }
}
File.Move(path + ".part", path, overwrite: true);

ZipFile.ExtractToDirectory(zipPath, folder, overwriteFiles: true);
```

Write downloads under `GamePaths.PlayerData`, not beside the game (which may not be writable). In a web build
`HttpClient` goes through the browser's `fetch`, so the server must allow the page's origin (CORS).

## The engine's own downloader

The launcher and the Tallow Manager are Beef, and use the engine's `Http` and `ZipFile`. Nothing extra is needed: Windows' own WinHTTP and, elsewhere, the system's libcurl (part of macOS and practically every Linux) are loaded the first time a download starts, so a program that never downloads does not depend on them.

```beef
let text = scope String();
if (Http.GetText("https://api.github.com/repos/owner/repo/releases", text, error)) ...

Http.Download(url, "/path/file.zip", error, scope (done, total) => { progress = done; return !cancelled; });

// On a thread of its own, for a window that shows progress:
let download = new HttpDownload(url, path);
download.Start();
... download.Fraction, download.Finished, download.Succeeded, download.Error, download.Cancel()

ZipFile.Extract("/path/file.zip", "/path/folder", error);
```

- Redirects are followed (GitHub's release downloads redirect to its file servers).
- A file is downloaded beside its name (`.part`) and moved into place only when complete; a failed or stopped download leaves nothing behind.
- Answers other than 2xx are failures, and the error says the status ("The server answered 404").
- `Http.UserAgent` is sent with every request (GitHub's API requires one).
- `ZipFile.Extract` keeps Unix permissions, so programs in the zip stay runnable, and refuses names that would leave the folder.
- `Http.Inflate` unpacks deflate data on its own.

## Tests