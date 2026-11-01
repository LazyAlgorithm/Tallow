using System;
using System.Collections;
using System.IO;
using System.Reflection;

namespace Tallow;

/// Development code reload (Linux and Windows, 64-bit debug builds). Compatible method edits preserve the live
/// scene and fields. Retain loaded generations: old delegates may still reference their code.
class ScriptReload
{
#if BF_PLATFORM_LINUX
	[CLink] static extern void* dlopen(char8* path, int32 flags);
	[CLink] static extern void* dlsym(void* handle, char8* name);
	[CLink] static extern int32 dlclose(void* handle);
	[CLink] static extern char8* dlerror();
	[CLink] static extern int32 mprotect(void* address, uint size, int32 protection);
	[CLink] static extern int32 getpagesize();
#endif
	List<void*> mModules = new .() ~ delete _;
	void* mCurrentModule;
	struct ClassPatch { public TypeInstance original; public TypeInstance replacement; public int size; }
	struct ProtectedPage { public uint address; public int32 protection; }
	struct StatePatch { public void* original; public void* replacement; public int size; }
	/// A script library that has been brought into the process, and what is needed from it and from the host.
	struct LoadedModule
	{
		public void* handle;
		public Type* table;
		public int32* count;
		/// Type.GetType(TypeId) and Type.GetType_(int) in the host.
		public void* getType, getTypeById;
		public uint functionTable;
		public uint32 functionCount;
	}

	public bool Inspect(StringView path, String error)
	{
#if BF_PLATFORM_LINUX
		let module = Open(path, error);
		if (module == null) return false;
		let valid = ValidateTypes(module, error);
		dlclose(module);
		return valid;
#else
		error.Set("Script reload supports Linux debug builds.");
		return false;
#endif
	}

#if BF_PLATFORM_LINUX
	static void* Open(StringView path, String error)
	{
		let module = dlopen(scope String(path).CStr(), 2);
		if (module == null)
		{
			let message = dlerror();
			error.Set(message != null ? StringView(message) : "Could not load script library.");
		}
		return module;
	}

	static bool ValidateTypes(void* module, String error)
	{
		let table = (Type*)dlsym(module, "_ZN2bf6System4Type6sTypesE");
		let count = (int32*)dlsym(module, "_ZN2bf6System4Type10sTypeCountE");
		let host = (Type*)dlsym(null, "_ZN2bf6System4Type6sTypesE");
		let hostCount = (int32*)dlsym(null, "_ZN2bf6System4Type10sTypeCountE");
		if (table == null || count == null || host == null || hostCount == null)
		{
			error.Set("Missing host exports. Full rebuild the editor with -rdynamic.");
			return false;
		}
		if (*count != *hostCount)
		{
			error.Set(scope $"Compiled type set changed ({*hostCount} -> {*count}).");
			int changes = 0;
			for (int i < Math.Min(*count, *hostCount))
			{
				let a = host[i];
				let b = table[i];
				let original = scope String();
				let replacement = scope String();
				if (a != null)
					a.GetFullName(original);
				if (b != null)
					b.GetFullName(replacement);
				if (original != replacement && changes++ < 6)
					error.AppendF("\nType {}: {} -> {}", i, original, replacement);
			}
			error.Append("\nFull Rebuild & Restart is required; existing scripts remain active.");
			return false;
		}
		for (int i < *count)
		{
			let a = host[i];
			let b = table[i];
			if ((a == null) != (b == null))
			{
				error.Set("Compiled type IDs changed. Full rebuild required.");
				return false;
			}
			if (a == null) continue;
			let original = scope String();
			let replacement = scope String();
			a.GetFullName(original);
			b.GetFullName(replacement);
			if (original != replacement || a.InstanceSize != b.InstanceSize)
			{
				error.Set(scope $"Type layout changed: {original}. Full rebuild required.");
				return false;
			}
		}
		return true;
	}

	static bool MakeWritable(void* address, int size, String maps, List<ProtectedPage> pages, String error)
	{
		if (size <= 0) return true;
		let pageSize = (uint)getpagesize();
		let start = (uint)address & ~(pageSize - 1);
		let end = ((uint)address + (uint)size + pageSize - 1) & ~(pageSize - 1);
		for (var page = start; page < end; page += pageSize)
		{
			bool seen = false;
			for (let saved in pages)
			{
				if (saved.address == page)
				{
					seen = true;
					break;
				}
			}
			if (seen) continue;
			int32 protection = 0;
			for (let line in maps.Split('\n'))
			{
				let dash = line.IndexOf('-');
				let space = line.IndexOf(' ');
				if (dash < 0 || space < dash || line.Length < space + 5) continue;
				if (uint64.Parse(line.Substring(0, dash), .HexNumber) case .Ok(let lower))
				{
					if (uint64.Parse(line.Substring(dash + 1, space - dash - 1), .HexNumber) case .Ok(let upper))
					{
						if (page >= lower && page < upper)
						{
							let mode = line.Substring(space + 1, 4);
							if (mode[0] == 'r')
								protection |= 1;
							if (mode[1] == 'w')
								protection |= 2;
							if (mode[2] == 'x')
								protection |= 4;
							break;
						}
					}
				}
			}
			if (protection == 0 || mprotect((void*)page, pageSize, protection | 2) != 0)
			{
				error.Set("Could not make script dispatch metadata writable.");
				return false;
			}
			pages.Add(.() { address = page, protection = protection });
		}
		return true;
	}

	static void RestorePages(List<ProtectedPage> pages)
	{
		for (let page in pages)
			mprotect((void*)page.address, (uint)getpagesize(), page.protection);
	}

	static bool OpenModule(String manifest, String path, out LoadedModule module, HashSet<void*> scriptClasses, String error)
	{
		module = default;
		let handle = dlopen(path.CStr(), 258);
		if (handle == null)
		{
			error.Set(StringView(dlerror()));
			return false;
		}
		module.handle = handle;
		module.table = (Type*)dlsym(handle, "_ZN2bf6System4Type6sTypesE");
		module.count = (int32*)dlsym(handle, "_ZN2bf6System4Type10sTypeCountE");
		module.getType = dlsym(null, "_ZN2bf6System4Type7GetTypeENS0_10Reflection6TypeIdE");
		module.getTypeById = dlsym(null, "_ZN2bf6System4Type8GetType_Ei");
		List<StringView> tokens = scope .();
		List<String> storage = scope .();
		defer
		{
			for (let value in storage)
				delete value;
		}
		for (let line in manifest.Split('\n'))
		{
			tokens.Clear();
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.Count == 3 && tokens[0] == "class")
				scriptClasses.Add(dlsym(handle, scope String(tokens[1]).CStr()));
		}
		return true;
	}

	static void CloseModule(LoadedModule module)
	{
		dlclose(module.handle);
	}

	static void KeepModule(LoadedModule module) { }

	static bool ValidateClass(TypeInstance a, TypeInstance b, String error)
	{
		if (a.[Friend]mFieldDataCount != b.[Friend]mFieldDataCount || a.[Friend]mMethodDataCount != b.[Friend]mMethodDataCount)
		{
			error.Set("Script field/method declarations changed. Full rebuild required.");
			return false;
		}
		for (int i < a.[Friend]mFieldDataCount)
		{
			let x = &a.[Friend]mFieldDataPtr[i];
			let y = &b.[Friend]mFieldDataPtr[i];
			if (x.mName != y.mName || x.mFieldTypeId != y.mFieldTypeId || x.mFlags != y.mFlags
				|| (!x.mFlags.HasFlag(.Static) && x.mData != y.mData))
			{
				error.Set("Script field layout changed. Full rebuild required.");
				return false;
			}
		}
		for (int i < a.[Friend]mMethodDataCount)
		{
			let x = &a.[Friend]mMethodDataPtr[i];
			let y = &b.[Friend]mMethodDataPtr[i];
			if (x.mName != y.mName || x.mParamCount != y.mParamCount || x.mReturnType != y.mReturnType
				|| x.mFlags != y.mFlags || x.mVirtualIdx != y.mVirtualIdx)
			{
				error.Set("Script method ABI changed. Full rebuild required.");
				return false;
			}
			for (int p < x.mParamCount)
			{
				if (x.mParamData[p].mType != y.mParamData[p].mType || x.mParamData[p].mParamFlags != y.mParamData[p].mParamFlags)
				{
					error.Set("Script method parameter ABI changed. Full rebuild required.");
					return false;
				}
			}
		}
		return true;
	}
#endif

	/// Call only at a main-thread frame boundary, before any scene callbacks.
#if BF_PLATFORM_LINUX
	/// Reads the manifest's "class" and "state" lines: each script class's dispatch table and each static field, in
	/// the running program and in the new library. False (with the reason in `error`) when they no longer match.
	bool ReadPatches(StringView text, void* module, List<ClassPatch> classes, List<StatePatch> state, String error)
	{
		List<StringView> tokens = scope .();
		List<String> storage = scope .();
		defer
		{
			for (let value in storage)
				delete value;
		}
		let host = (Type*)dlsym(null, "_ZN2bf6System4Type6sTypesE");
		let table = (Type*)dlsym(module, "_ZN2bf6System4Type6sTypesE");
		let count = *(int32*)dlsym(module, "_ZN2bf6System4Type10sTypeCountE");
		for (let line in text.Split('\n'))
		{
			tokens.Clear();
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.Count != 3) continue;
			let symbol = scope String(tokens[1]);
			let size = SceneSerializer.ParseInt(tokens[2]);
			if (size <= 0 || size > 1024 * 1024)
			{
				error.Set("Invalid script symbol size.");
				return false;
			}
			let replacement = dlsym(module, symbol.CStr());
			if (tokens[0] == "class")
			{
				let original = dlsym(null, symbol.CStr());
				if (original == null || replacement == null)
				{
					error.Set("Script class set changed. Full rebuild required.");
					return false;
				}
				bool found = false;
				for (int i < count)
				{
					let a = host[i] as TypeInstance;
					let b = table[i] as TypeInstance;
					if (a == null || b == null || (void*)a.[Friend]mTypeClassVData != original) continue;
					if ((void*)b.[Friend]mTypeClassVData != replacement || !ValidateClass(a, b, error)) return false;
					classes.Add(.() { original = a, replacement = b, size = size });
					found = true;
					break;
				}
				if (!found)
				{
					error.Set("Missing reflected script class metadata.");
					return false;
				}
			}
			else if (tokens[0] == "state")
			{
				var original = dlsym(mCurrentModule, symbol.CStr());
				if (original == null)
					original = dlsym(null, symbol.CStr());
				if (original == null || replacement == null)
				{
					error.Set("Script static fields changed. Full rebuild required.");
					return false;
				}
				state.Add(.() { original = original, replacement = replacement, size = size });
			}
		}
		return true;
	}

#endif

	/// The library a reload manifest names on its "module <path>" line.
	static void ManifestModule(StringView text, String path)
	{
		List<StringView> tokens = scope .();
		List<String> storage = scope .();
		defer
		{
			for (let value in storage)
				delete value;
		}
		for (let line in text.Split('\n'))
		{
			tokens.Clear();
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.Count == 2 && tokens[0] == "module")
				path.Set(tokens[1]);
		}
	}

	public bool Apply(StringView manifestPath, String error, Scene scene = null)
	{
		// A reload can change a class's fields or their attributes (HideInInspector, Range...) without changing
		// its layout: what the registry worked out about fields before is no longer to be trusted.
		ComponentRegistry.ClearFieldCache();
		defer ComponentRegistry.ClearFieldCache();
		let text = scope String();
		if (File.ReadAllText(manifestPath, text) case .Err)
		{
			error.Set("Script library manifest is missing.");
			return false;
		}
		if (text.Contains("mode structural")) return ApplyStructural(text, error, scene ?? Scene.Active);
#if BF_PLATFORM_LINUX
		let path = scope String();
		ManifestModule(text, path);
		let module = Open(path, error);
		if (module == null) return false;
		bool applied = false;
		defer
		{
			if (!applied)
				dlclose(module);
		}
		if (!ValidateTypes(module, error)) return false;
		List<ClassPatch> classes = scope .();
		List<StatePatch> state = scope .();
		if (!ReadPatches(text, module, classes, state, error))
			return false;
		if (classes.Count == 0)
		{
			error.Set("Script library has no reloadable classes.");
			return false;
		}
		// ELF RELRO protects dispatch metadata. Restore each page's original permissions afterward.
		let maps = scope String();
		if (File.ReadAllText("/proc/self/maps", maps) case .Err)
		{
			error.Set("Could not inspect metadata page permissions.");
			return false;
		}
		List<ProtectedPage> pages = scope .();
		defer
		{
			for (let page in pages)
				mprotect((void*)page.address, (uint)getpagesize(), page.protection);
		}
		for (let patch in classes)
		{
			if (!MakeWritable(patch.original.[Friend]mTypeClassVData, patch.size, maps, pages, error)) return false;
			if (!MakeWritable(patch.original.[Friend]mMethodDataPtr, patch.original.[Friend]mMethodDataCount * sizeof(TypeInstance.MethodData), maps, pages, error)) return false;
		}
		// Validate everything first; only this section changes the running program.
		for (let patch in state)
			Internal.MemCpy(patch.replacement, patch.original, patch.size);
		for (let patch in classes)
		{
			Internal.MemCpy(patch.original.[Friend]mTypeClassVData, patch.replacement.[Friend]mTypeClassVData, patch.size);
			for (int i < patch.original.[Friend]mMethodDataCount)
				patch.original.[Friend]mMethodDataPtr[i].mFuncPtr = patch.replacement.[Friend]mMethodDataPtr[i].mFuncPtr;
		}
		mModules.Add(module);
		mCurrentModule = module;
		applied = true;
		return true;
#else
		error.Set("This script library was not built for structural reload.");
		return false;
#endif
	}
}
