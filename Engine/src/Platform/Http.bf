using System;
using System.Collections;
using System.IO;
using System.Threading;

namespace Tallow;

/// Downloads over HTTP and HTTPS, for launchers, updaters and games that fetch content. Nothing extra is needed:
/// Windows' own WinHTTP, and elsewhere the system's libcurl, are loaded the first time a download starts.
/// Calls block until done, so run long downloads on a thread (HttpDownload does that for you).
static class Http
{
	public function int32 ProgressFunction(void* user, int64 done, int64 total);

	[CLink] static extern int32 tn_http_get(char8* url, char8* userAgent, char8* path, out char8* data, out int64 size, ProgressFunction progress, void* user, out int32 status, char8* error, int32 errorSize);
	[CLink] static extern void tn_http_free(char8* data);
	[CLink] static extern char8* tn_inflate(void* data, int32 length, int32 expectedSize, int32 zlibHeader, out int32 outLength);

	/// Sent with every request (GitHub's API asks for one).
	public static String UserAgent = new .("Tallow") ~ delete _;

	/// Fetches a page or API answer as text. error says what went wrong on failure.
	public static bool GetText(StringView url, String text, String error = null)
	{
		char8* data;
		int64 size;
		int32 status;
		char8[512] message = default;
		if (tn_http_get(scope String(url).CStr(), UserAgent.CStr(), null, out data, out size, null, null, out status, &message, 512) == 0)
		{
			error?.Set(StringView(&message));
			return false;
		}
		text.Append(data, (int)size);
		tn_http_free(data);
		return true;
	}

	/// Downloads to a file (written beside it first, then moved into place). progress, if given, is called with the
	/// bytes so far and the total (-1 when unknown) and can return false to stop.
	public static bool Download(StringView url, StringView path, String error = null, delegate bool(int64 done, int64 total) progress = null)
	{
		char8* data;
		int64 size;
		int32 status;
		char8[512] message = default;
		ProgressFunction callback = null;
		if (progress != null)
			callback = => Progress;
		let ok = tn_http_get(scope String(url).CStr(), UserAgent.CStr(), scope String(path).CStr(), out data, out size,
			callback, progress != null ? Internal.UnsafeCastToPtr(progress) : null, out status, &message, 512) != 0;
		if (!ok)
			error?.Set(StringView(&message));
		return ok;
	}

	static int32 Progress(void* user, int64 done, int64 total)
	{
		let callback = (delegate bool(int64, int64))Internal.UnsafeCastToObject(user);
		return callback(done, total) ? 0 : 1;
	}

	/// Inflates deflate data: raw (as in zip files) or with a zlib header. Null if it is damaged; delete the result.
	public static uint8[] Inflate(Span<uint8> data, int expectedSize, bool zlibHeader = false)
	{
		int32 length;
		let raw = tn_inflate(data.Ptr, (int32)data.Length, (int32)expectedSize, zlibHeader ? 1 : 0, out length);
		if (raw == null)
			return null;
		let result = new uint8[length];
		Internal.MemCpy(result.Ptr, raw, length);
		tn_http_free(raw);
		return result;
	}
}

/// A download on a thread of its own, for a window that shows progress while it runs.
class HttpDownload
{
	public String Url = new .() ~ delete _;
	public String Path = new .() ~ delete _;
	public String Error = new .() ~ delete _;
	Thread mThread ~
		{
			if (_ != null)
			{
				_.Join();
				delete _;
			}
		};
	int64 mDone;
	int64 mTotal = -1;
	bool mCancel;
	bool mFinished;
	bool mSucceeded;

	public this(StringView url, StringView path)
	{
		Url.Set(url);
		Path.Set(path);
	}

	public void Start()
	{
		mThread = new Thread(new => Run);
		mThread.Start(false);
	}

	void Run()
	{
		let error = scope String();
		let ok = Http.Download(Url, Path, error, scope (done, total) =>
			{
				mDone = done;
				mTotal = total;
				return !mCancel;
			});
		mSucceeded = ok;
		if (!ok)
		{
			using (sLock.Enter())
				Error.Set(error);
		}
		mFinished = true;
	}

	static Monitor sLock = new .() ~ delete _;

	public bool Finished => mFinished;
	public bool Succeeded => mSucceeded;
	public int64 BytesDone => mDone;
	/// -1 when the server did not say.
	public int64 BytesTotal => mTotal;
	/// 0 to 1, or -1 when the size is not known.
	public float Fraction => mTotal > 0 ? (float)((double)mDone / mTotal) : -1;
	public void Cancel()
	{
		mCancel = true;
	}
}

/// Reads zip files: lists and extracts them, keeping Unix file permissions (so programs stay runnable).
static class ZipFile
{
#if !BF_PLATFORM_WINDOWS
	[CLink] static extern int32 chmod(char8* path, uint32 mode);
#endif

	// Zip records (PKWARE APPNOTE): their signatures and fixed sizes.
	const uint32 ZipEndSignature = 0x06054b50;
	const uint32 ZipEntrySignature = 0x02014b50;
	const uint32 ZipLocalSignature = 0x04034b50;
	const int ZipEndSize = 22;
	const int ZipEntrySize = 46;
	const int ZipLocalSize = 30;
	/// The end record is followed by a comment of up to 64 KB.
	const int ZipEndSearch = ZipEndSize + 65535;
	const uint16 ZipStored = 0;
	const uint16 ZipDeflated = 8;

	static uint16 U16(Span<uint8> data, int at) => (uint16)(data[at] | ((uint16)data[at + 1] << 8));
	static uint32 U32(Span<uint8> data, int at) => (uint32)data[at] | ((uint32)data[at + 1] << 8) | ((uint32)data[at + 2] << 16) | ((uint32)data[at + 3] << 24);

	/// Extracts every file in the zip into folder (made if missing). Returns false, with error, if the zip is
	/// damaged or a file cannot be written. Names that would leave the folder (../) are refused.
	public static bool Extract(StringView zipPath, StringView folder, String error = null, delegate void(int done, int total) progress = null)
	{
		List<uint8> zip = scope .();
		if (File.ReadAll(zipPath, zip) case .Err)
		{
			error?.Set("Could not read the zip file.");
			return false;
		}
		let data = Span<uint8>(zip.Ptr, zip.Count);
		int end = -1;
		for (int i = data.Length - ZipEndSize; i >= Math.Max(0, data.Length - ZipEndSearch); i--)
		{
			if (U32(data, i) == ZipEndSignature)
			{
				end = i;
				break;
			}
		}
		if (end < 0)
		{
			error?.Set("Not a zip file.");
			return false;
		}
		let count = (int)U16(data, end + 10);
		var at = (int)U32(data, end + 16);
		Directory.CreateDirectory(folder).IgnoreError();
		for (int index < count)
		{
			if (at + ZipEntrySize > data.Length || U32(data, at) != ZipEntrySignature)
			{
				error?.Set("The zip file is damaged.");
				return false;
			}
			let method = U16(data, at + 10);
			let compressed = (int)U32(data, at + 20);
			let size = (int)U32(data, at + 24);
			let nameLength = (int)U16(data, at + 28);
			let extraLength = (int)U16(data, at + 30);
			let commentLength = (int)U16(data, at + 32);
			let external = U32(data, at + 38);
			let local = (int)U32(data, at + 42);
			let name = scope String((char8*)data.Ptr + at + ZipEntrySize, nameLength);
			name.Replace('\\', '/');
			at += ZipEntrySize + nameLength + extraLength + commentLength;
			if (name.StartsWith('/') || name.Contains("../") || name == "..")
			{
				error?.Set(scope $"The zip file names a file outside its folder: {name}");
				return false;
			}
			let target = scope $"{folder}/{name}";
			if (name.EndsWith('/'))
			{
				Directory.CreateDirectory(target).IgnoreError();
				continue;
			}
			let parent = scope String();
			if (System.IO.Path.GetDirectoryPath(target, parent) case .Ok)
				Directory.CreateDirectory(parent).IgnoreError();
			if (!WriteEntry(data, local, method, compressed, size, name, target, error))
				return false;
#if !BF_PLATFORM_WINDOWS
			// Made on Unix: the upper half of the external attributes is the file mode.
			let mode = external >> 16;
			if ((mode & 0x1FF) != 0)
				chmod(target.CStr(), mode & 0xFFF);
#endif
			progress?.Invoke(index + 1, count);
		}
		return true;
	}

	/// Writes one file of the zip, from its local record at `local`, unpacking it if it is deflated.
	static bool WriteEntry(Span<uint8> data, int local, uint16 method, int compressed, int size, StringView name, StringView target, String error)
	{
		if (local + ZipLocalSize > data.Length || U32(data, local) != ZipLocalSignature)
		{
			error?.Set("The zip file is damaged.");
			return false;
		}
		let start = local + ZipLocalSize + (int)U16(data, local + 26) + (int)U16(data, local + 28);
		if (start + compressed > data.Length)
		{
			error?.Set("The zip file is cut short.");
			return false;
		}
		let stored = Span<uint8>(data.Ptr + start, compressed);
		Result<void> written;
		if (method == ZipStored)
			written = File.WriteAll(target, stored);
		else if (method == ZipDeflated)
		{
			let plain = Http.Inflate(stored, size);
			defer delete plain;
			if (plain == null || plain.Count != size)
			{
				error?.Set(scope $"Could not unpack {name}.");
				return false;
			}
			written = File.WriteAll(target, Span<uint8>(plain.Ptr, plain.Count));
		}
		else
		{
			error?.Set(scope $"{name} is packed in a way this reader does not know ({method}).");
			return false;
		}
		if (written case .Err)
		{
			error?.Set(scope $"Could not write {target}.");
			return false;
		}
		return true;
	}
}
