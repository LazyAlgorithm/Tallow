using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;

namespace HttpTests;

/// Downloads over HTTPS and zip files. Needs the internet: it reads Tallow's own GitHub releases.
class Program
{
	[CLink] static extern int32 system(char8* command);
	static int sFailures;
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		if (!pass)
			sFailures++;
		return pass;
	}

	public static int Main(String[] args)
	{
		let folder = "/tmp/tallow-http-test";
		if (Directory.Exists(folder))
			Directory.DelTree(folder).IgnoreError();
		Directory.CreateDirectory(folder).IgnoreError();

		// ---- text ----
		let text = scope String();
		let error = scope String();
		let fetched = Http.GetText("https://api.github.com/repos/LazyAlgorithm/Tessera/releases?per_page=3", text, error);
		Check(fetched && text.StartsWith("[") && text.Contains("tag_name"), scope $"GitHub's API answers over HTTPS ({text.Length} characters{(error.IsEmpty ? "" : ", ")}{error})");
		let missing = scope String();
		error.Clear();
		Check(!Http.GetText("https://api.github.com/repos/LazyAlgorithm/Tessera/releases/tags/no-such-release", missing, error) && error.Contains("404"), scope $"a missing page is a failure that says why ({error})");

		// ---- files, with progress ----
		let zip = scope $"{folder}/xwin.zip";
		int64 lastDone = 0, lastTotal = 0;
		int calls = 0;
		error.Clear();
		let downloaded = Http.Download("https://github.com/LazyAlgorithm/Tessera/releases/download/toolchain-1/xwin-windows-x64.zip", zip, error, scope [&] (done, total) =>
			{
				calls++;
				lastDone = done;
				lastTotal = total;
				return true;
			});
		Check(downloaded && File.Exists(zip) && !File.Exists(scope $"{zip}.part") && calls > 0 && lastDone > 1000000 && (lastTotal < 0 || lastTotal == lastDone),
scope $"a release file downloads through GitHub's redirect, reporting progress ({lastDone} bytes, {calls} reports){error}");
		let cancelled = scope $"{folder}/cancelled.zip";
		Check(!Http.Download("https://github.com/LazyAlgorithm/Tessera/releases/download/toolchain-1/xwin-windows-x64.zip", cancelled, null, scope (done, total) => done < 100000)
			&& !File.Exists(cancelled) && !File.Exists(scope $"{cancelled}.part"), "a download can be stopped part way, leaving nothing behind");

		// ---- zip ----
		error.Clear();
		Check(ZipFile.Extract(zip, scope $"{folder}/out" , error) && File.Exists(scope $"{folder}/out/xwin.exe"), scope $"a zip unpacks{error}");
		let large = scope $"{folder}/out/xwin.exe";
		List<uint8> exe = scope .();
		File.ReadAll(large, exe).IgnoreError();
		Check(exe.Count > 1000000 && exe[0] == 'M' && exe[1] == 'Z', scope $"with its contents whole ({exe.Count} bytes, a Windows program)");

		// A zip made here, with a program that must stay runnable.
		Directory.CreateDirectory(scope $"{folder}/src/sub").IgnoreError();
		File.WriteAllText(scope $"{folder}/src/sub/run.sh" , "#!/bin/sh\necho ran\n").IgnoreError();
		let repeated = scope String();
		for (int i < 2000)
			repeated.Append("Tallow ");
		File.WriteAllText(scope $"{folder}/src/text.txt" , repeated).IgnoreError();
		let zipped = scope $"{folder}/made.zip";
		let made = scope $"cd {folder}/src && chmod +x sub/run.sh && python3 -c \"import zipfile,os; z=zipfile.ZipFile('{zipped}','w',zipfile.ZIP_DEFLATED); [z.write(p) for p in ('sub/run.sh','text.txt')]; z.writestr('stored.txt','plain', compress_type=zipfile.ZIP_STORED); z.close()\"";
		Check(system(made.CStr()) == 0, "made a zip to read");
		error.Clear();
		let extracted = ZipFile.Extract(zipped, scope $"{folder}/made" , error);
		let read = scope String();
		File.ReadAllText(scope $"{folder}/made/text.txt" , read).IgnoreError();
		let plain = scope String();
		File.ReadAllText(scope $"{folder}/made/stored.txt" , plain).IgnoreError();
		Check(extracted && read == repeated && plain == "plain", scope $"compressed and stored files come out as they went in{error}");
		Check(system(scope $"{folder}/made/sub/run.sh > /dev/null" .CStr()) == 0, "and a program keeps permission to run");
		let evil = scope $"{folder}/evil.zip";
		system(scope $"python3 -c \"import zipfile; z=zipfile.ZipFile('{evil}','w'); z.writestr('../outside.txt','x'); z.close()\"" .CStr());
		Check(!ZipFile.Extract(evil, scope $"{folder}/evil" , error) && !File.Exists(scope $"{folder}/outside.txt"), "a zip naming a file outside its folder is refused");
		Check(!ZipFile.Extract(scope $"{folder}/src/text.txt" , scope $"{folder}/bad" , error), "something that is not a zip is refused");

		Console.WriteLine(scope $"{sFailures} failed");
		return sFailures == 0 ? 0 : 1;
	}
}
