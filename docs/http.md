# Downloads and zip files

For launchers, updaters and games that fetch content. Nothing extra is needed: Windows' own WinHTTP and, elsewhere, the system's libcurl (part of macOS and practically every Linux) are loaded the first time a download starts, so a game that never downloads does not depend on them.

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