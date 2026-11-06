using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using Tallow;
using Tallow.Editor;

namespace EcsBench;

static class SemanticClientChecks
{
	public static int Run(StringView engine, StringView project)
	{
		let client = scope BeefAnalysisClient(project, scope $"{engine}/tools/semantic/service.py" , scope $"{engine}/build/semantic/beef-resolve");
		let clock = scope Stopwatch(true);
		while (!client.Ready && !client.Failed && clock.ElapsedMilliseconds < 30000)
			Thread.Sleep(10);
		if (!client.Ready)
		{
			Console.WriteLine("Semantic client did not start");
			return 1;
		}
		let path = scope $"{project}/src/Program.bf";
		let text = scope String();
		if (File.ReadAllText(path, text) case .Err) return 1;
		let request = scope SaveNode(.Object);
		request.Set("id", SaveNode.MakeInt(1));
		request.Set("generation", SaveNode.MakeInt(7));
		request.Set("path", SaveNode.MakeString(path));
		request.Set("cursor", SaveNode.MakeInt(-1));
		request.Set("kind", SaveNode.MakeString("diagnostics"));
		let buffers = new SaveNode(.List);
		request.Set("buffers", buffers);
		let buffer = new SaveNode(.Object);
		buffer.Set("path", SaveNode.MakeString(path));
		buffer.Set("revision", SaveNode.MakeInt(42));
		buffer.Set("text", SaveNode.MakeString(text));
		buffers.items.Add(buffer);
		let message = scope String();
		request.ToText(message, false);
		client.Submit(message);
		let response = scope String();
		clock.Restart();
		while (!client.TakeResult(response) && !client.Failed && clock.ElapsedMilliseconds < 30000)
			Thread.Sleep(10);
		let result = SaveNode.FromText(response);
		defer delete result;
		if (result == null || result["id"]?.AsInteger != 1 || result["generation"]?.AsInteger != 7 || result["revision"]?.AsInteger != 42)
		{
			Console.WriteLine(scope $"Unexpected semantic response: {response}");
			return 1;
		}
		client.Stop();
		client.Stop(); // Editor shutdown and destructor may both stop the worker.
		Console.WriteLine("Beef editor process integration passed");
		return 0;
	}
}
