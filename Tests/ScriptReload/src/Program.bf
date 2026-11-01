using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;

namespace ReloadTests;

[Component]
class ReloadLinks : Component
{
	public Component target;
}
class Program
{
#if BF_PLATFORM_LINUX
	[CLink] static extern void* signal(int32 number, void* handler);
	[CLink] static extern int32 backtrace(void** buffer, int32 size);
	[CLink] static extern void backtrace_symbols_fd(void** buffer, int32 size, int32 fd);
	[CLink] static extern void _exit(int32 code);
	static void Fault(int32 code)
	{
		void*[40] stack = default;
		let count = backtrace(&stack[0], 40);
		backtrace_symbols_fd(&stack[0], count, 2);
		_exit(99);
	}
#endif

	static FieldRef Field(Component component, StringView name)
	{
		List<FieldRef> fields = scope .();
		ComponentRegistry.GetFields(component, fields, true);
		for (let field in fields)
		{
			if (field.name == name)
				return field;
		}
		return default;
	}

	public static int Main(String[] args)
	{
#if BF_PLATFORM_LINUX
		delegate void(int32) fault = scope => Fault;
		if (fault.GetFuncPtr() case .Ok(let ptr))
			signal(11, ptr);
#endif
		if (args.Count != 1) return 2;
		let folder = args[0];
		let scene = scope Scene();
		let player = scene.CreateGameObject("Player");
		let particles = player.AddComponent<ParticleSystem>();
		let probe = player.AddComponent<ReloadProbe>();
		probe.amount = 3;
		probe.particles = particles;
		let links = scene.CreateGameObject("Links").AddComponent<ReloadLinks>();
		links.target = probe;
		let physics = scene.Physics;
		Input.[Friend]sKeys[(int)KeyCode.Space] = true;
		scene.StartPlay();
		scene.Update();
		if (probe.Total != 3 || particles.Enabled || ReloadProbe.calls != 1) return 1;
		if (!ScriptReload.WriteHostInfo(scope $"{folder}/baseline.host"))
		{
			Console.WriteLine("FAIL: no room for script libraries");
			return 1;
		}
		File.WriteAllText(scope $"{folder}/ready" , "ready").IgnoreError();
		let loader = scope ScriptReload();
		let error = scope String();
		for (int generation = 1; generation <= 6; generation++)
		{
			let manifest = scope $"{folder}/generation-{generation}.manifest";
			int waits = 0;
			while (!File.Exists(manifest) && waits++ < 6000)
				Thread.Sleep(10);
			if (!File.Exists(manifest))
			{
				Console.WriteLine("FAIL: timeout");
				return 1;
			}
			if (!loader.Apply(manifest, error, scene))
			{
				Console.WriteLine(error);
				return 1;
			}
			let actual = player.Components[1];
			actual.Update();
			let expected = generation == 1 ? 33.0f : (generation == 2 ? 93.0f : (generation == 3 ? 153.0f : (generation == 4 ? 213.0f : (generation == 5 ? 233.0f : 253.0f))));
			let amount = Field(actual, "amount");
			if (amount.hidden != (generation == 4))
			{
				Console.WriteLine("FAIL: changing/removing HideInInspector on existing field");
				return 1;
			}
			let amountValue = amount.kind == .Float ? *(float*)amount.ptr : (float) * (int32*)amount.ptr;
			if (*(int*)Field(actual, "platformInt").ptr != 5000000000 || *(uint64*)Field(actual, "quota").ptr != uint64.MaxValue || *(double*)Field(actual, "precise").ptr != 0.12345678901234567 || ((Vector4*)Field(actual, "vector").ptr).w != 4)
			{
				Console.WriteLine("FAIL: expanded inspector types during reload");
				return 1;
			}
			let currentLinks = scene.Find("Links").Components[0];
			if (*(float*)Field(actual, "mTotal").ptr != expected || amountValue != (generation < 5 ? 3.0f : 1.0f)
				|| *(ParticleSystem*)Field(actual, "particles").ptr != particles || player.Transform.LocalPosition.x != expected
				|| particles.Enabled != (generation % 2 == 1) || ReloadProbe.calls != generation + 1
				|| *(Component*)Field(currentLinks, "target").ptr != actual || !scene.IsPlaying || scene.Physics != physics || !actual.IsAwake || !actual.[Friend]mStarted)
			{
				Console.WriteLine(scope $"FAIL: generation {generation}, expected {expected}, total {*(float*)Field(actual,"mTotal").ptr}, amount {amountValue}, calls {ReloadProbe.calls}");
				return 1;
			}
			if (generation >= 3)
			{
				List<FieldRef> exposed = scope .();
				ComponentRegistry.GetFields(actual, exposed);
				bool found = false;
				for (let field in exposed)
				{
					if (field.name == "mVisiblePrivate")
					{
						found = !field.hidden && field.hasRange;
					}
				}
				if (!found || *(float*)Field(actual, "mVisiblePrivate").ptr != (generation == 3 ? 7.0f : 77.0f))
				{
					Console.WriteLine("FAIL: private ShowInInspector");
					return 1;
				}
				*(float*)Field(actual, "mVisiblePrivate").ptr = 77;
				if (generation < 6)
				{
					bool hidden = false;
					for (let field in exposed)
					{
						if (field.name == "addedField")
							hidden = field.hidden;
					}
					if (!hidden || *(int32*)Field(actual, "addedField").ptr != (generation == 3 ? 42 : 91))
					{
						Console.WriteLine("FAIL: HideInInspector metadata/state");
						return 1;
					}
					*(int32*)Field(actual, "addedField").ptr = 91;
				}
			}
			if (generation == 4)
			{
				let info = ComponentRegistry.Find("ReloadTests.Added");
				if (info == null)
				{
					Console.WriteLine("FAIL: added script not registered");
					return 1;
				}
				let added = scene.CreateGameObject("Added").AddComponent(info.type);
				added.Update();
				if (*(int32*)Field(added, "ticks").ptr != 1)
				{
					Console.WriteLine("FAIL: added script callback");
					return 1;
				}
			}
			if (generation >= 5)
			{
				let added = scene.Find("Added").Components[0];
				added.Update();
				if (*(int32*)Field(added, "ticks").ptr != generation - 3)
				{
					Console.WriteLine("FAIL: added script state in subsequent reload");
					return 1;
				}
			}
			Console.WriteLine(scope $"PASS: generation {generation}; code, supported private fields, references, static state, input, Play and physics world preserved");
			File.WriteAllText(scope $"{folder}/applied-{generation}" , "applied").IgnoreError();
		}
		Input.[Friend]sKeys[(int)KeyCode.Space] = false;
		scene.StopPlay();
		return 0;
	}
}
