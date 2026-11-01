using System;
using System.IO;
using Tallow;
using Tallow.Editor;

namespace ScriptCatalogTests;

[Component] class Deleted : Component { }
[Component] class Renamed : Component { }
class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	public static int Main(String[] args)
	{
		let root = "/tmp/tallow-script-catalog-test";
		Directory.CreateDirectory(root);
		let path = scope $"{root}/Example.bf";
		defer
		{
			File.Delete(path);
			Directory.Delete(root);
		}
		let catalog = scope ScriptComponentCatalog();
		let deleted = ComponentRegistry.Find("ScriptCatalogTests.Deleted");
		let renamed = ComponentRegistry.Find("ScriptCatalogTests.Renamed");
		bool ok = Check(deleted != null && renamed != null, "fixture components registered");
		if (!ok) return 1;
		File.WriteAllText(path, "namespace ScriptCatalogTests; [Component] class Deleted : Component {} [Component] class Renamed : Component {}");
		catalog.Refresh(root, "ScriptCatalogTests");
		ok &= Check(catalog.IsVisible(deleted) && catalog.IsVisible(renamed), "multiple declarations remain available");
		File.WriteAllText(path, "namespace ScriptCatalogTests; /* class Deleted */ [Component] class Renamed : Component {}");
		catalog.Refresh(root, "ScriptCatalogTests");
		ok &= Check(!catalog.IsVisible(deleted) && catalog.IsVisible(renamed), "removed declaration hidden; comments ignored");
		File.Move(path, scope $"{root}/Moved.bf");
		catalog.Refresh(root, "ScriptCatalogTests");
		ok &= Check(catalog.IsVisible(renamed), "file rename preserves component");
		File.Delete(scope $"{root}/Moved.bf");
		catalog.Refresh(root, "ScriptCatalogTests");
		ok &= Check(!catalog.IsVisible(renamed), "external file deletion removes component");
		let fresh = scope ScriptComponentCatalog();
		fresh.Refresh(root, "ScriptCatalogTests");
		ok &= Check(!fresh.IsVisible(deleted), "deletion before editor startup is hidden");
		ok &= Check(fresh.IsVisible(ComponentRegistry.Find("Tallow.Camera")), "built-in components remain available");
		return ok ? 0 : 1;
	}
}
