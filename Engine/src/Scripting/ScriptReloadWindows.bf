using System;
using System.Collections;
using System.IO;

namespace Tallow;

// Script reload on Windows. A Windows program does not share its symbols with a library the way a Linux one
// does, so the script library is not loaded by Windows at all: tools/reload_scripts.py links it at an exact
// address just below this program, with every reference to the engine already resolved, and the code here
// copies its sections into place. This program keeps a stretch of address space free for that, and tells the
// tool where it is (WriteHostInfo).
extension ScriptReload
{
#if BF_PLATFORM_WINDOWS && BF_64_BIT
	[CLink, CallingConvention(.Stdcall)] static extern void* VirtualAlloc(void* address, uint size, uint32 type, uint32 protection);
	[CLink, CallingConvention(.Stdcall)] static extern int32 VirtualProtect(void* address, uint size, uint32 protection, uint32* previous);
	[CLink, CallingConvention(.Stdcall)] static extern void* GetModuleHandleA(char8* name);
	[CLink, CallingConvention(.Stdcall)] static extern void* GetCurrentProcess();
	[CLink, CallingConvention(.Stdcall)] static extern int32 FlushInstructionCache(void* process, void* address, uint size);
	[CLink, CallingConvention(.Stdcall)] static extern uint8 RtlAddFunctionTable(void* table, uint32 count, uint64 baseAddress);

	const uint32 MemReserve = 0x2000, MemCommit = 0x1000;
	const uint32 NoAccess = 0x01, ReadWrite = 0x04, ExecuteRead = 0x20, ExecuteReadWrite = 0x40;
	const uint Page = 0x1000, Grain = 0x10000;

	// The address space kept for script libraries: they fill it from the top down.
	static uint sArenaBottom, sArenaTop;

	static uint HostBase => (uint)(void*)GetModuleHandleA(null);

	static bool ReserveArena()
	{
		if (sArenaTop != 0)
			return true;
		// As near below the program as there is room, and never so far that a library at the bottom could not
		// reach the top of the program with a 32-bit offset.
		let host = HostBase & ~(Grain - 1);
		for (uint size = 1024; size >= 64; size /= 2)
		{
			for (uint gap = 0; gap <= 512; gap += 16)
			{
				let top = host - gap * 0x100000;
				let bottom = top - size * 0x100000;
				if (bottom > top || VirtualAlloc((void*)bottom, top - bottom, MemReserve, NoAccess) == null)
					continue;
				sArenaBottom = bottom;
				sArenaTop = top;
				return true;
			}
		}
		return false;
	}

	static bool MakeWritable(void* address, int size, String maps, List<ProtectedPage> pages, String error)
	{
		if (size <= 0) return true;
		let start = (uint)address & ~(Page - 1);
		let end = ((uint)address + (uint)size + Page - 1) & ~(Page - 1);
		for (var page = start; page < end; page += Page)
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
			uint32 previous = 0;
			if (VirtualProtect((void*)page, Page, ExecuteReadWrite, &previous) == 0)
			{
				error.Set("Could not make script dispatch metadata writable.");
				return false;
			}
			pages.Add(.() { address = page, protection = (int32)previous });
		}
		return true;
	}

	static void RestorePages(List<ProtectedPage> pages)
	{
		for (let page in pages)
		{
			uint32 previous = 0;
			VirtualProtect((void*)page.address, Page, (uint32)page.protection, &previous);
		}
		FlushInstructionCache(GetCurrentProcess(), null, 0);
	}

	static bool Hex(StringView text, out uint value)
	{
		value = 0;
		if (uint64.Parse(text, .HexNumber) case .Ok(let parsed))
		{
			value = (uint)parsed;
			return true;
		}
		return false;
	}

	/// Copies a script library's sections to the address it was linked for.
	static bool MapImage(StringView path, uint imageBase, uint span, out uint functionTable, out uint32 functionCount, String error)
	{
		functionTable = 0;
		functionCount = 0;
		List<uint8> file = scope .();
		if (File.ReadAll(path, file) case .Err)
		{
			error.Set("Could not read the script library.");
			return false;
		}
		if (file.Count < 0x400)
		{
			error.Set("The script library is not a program image.");
			return false;
		}
		let data = file.Ptr;
		let header = (int) * (uint32*)(data + 0x3C);
		if (header + 0x108 > file.Count || *(uint32*)(data + header) != 0x00004550)
		{
			error.Set("The script library is not a program image.");
			return false;
		}
		let sectionCount = (int) * (uint16*)(data + header + 6);
		let optional = header + 24;
		let optionalSize = (int) * (uint16*)(data + header + 20);
		if (*(uint64*)(data + optional + 24) != (uint64)imageBase)
		{
			error.Set("The script library was linked for another address.");
			return false;
		}
		if (imageBase < sArenaBottom || imageBase + span > sArenaTop || span == 0)
		{
			error.Set("The script library was not linked for the room this program keeps for it. Restart the editor.");
			return false;
		}
		// Directories 1 (imports) and 9 (thread-local storage) would need Windows' own loader.
		if (*(uint32*)(data + optional + 112 + 8 * 1 + 4) != 0)
		{
			error.Set("The script library imports from another library. Full rebuild required.");
			return false;
		}
		if (*(uint32*)(data + optional + 112 + 8 * 9 + 4) != 0)
		{
			error.Set("Scripts with thread-local static fields cannot be reloaded on Windows. Full rebuild required.");
			return false;
		}
		if (VirtualAlloc((void*)imageBase, span, MemCommit, ReadWrite) == null)
		{
			error.Set("No memory for the script library.");
			return false;
		}
		uint32 previous = 0;
		VirtualProtect((void*)imageBase, span, ReadWrite, &previous);
		Internal.MemSet((void*)imageBase, 0, (int)span);
		let sections = data + optional + optionalSize;
		if ((int)(sections - data) + sectionCount * 40 > file.Count)
		{
			error.Set("The script library is damaged.");
			return false;
		}
		for (int i < sectionCount)
		{
			let section = sections + i * 40;
			if (StringView((char8*)section, 8) == ".hostimg")
				continue; // the stand-in for this program itself: nothing to load
			let virtualSize = (uint) * (uint32*)(section + 8);
			let address = (uint) * (uint32*)(section + 12);
			let rawSize = (uint) * (uint32*)(section + 16);
			let rawOffset = (uint) * (uint32*)(section + 20);
			let flags = *(uint32*)(section + 36);
			if ((flags & 0x02000000) != 0)
				continue; // discardable
			let size = Math.Max(virtualSize, rawSize);
			if (address + size > span || rawOffset + rawSize > (uint)file.Count)
			{
				error.Set("The script library has a section outside the room kept for it.");
				return false;
			}
			Internal.MemCpy((void*)(imageBase + address), data + rawOffset, (int)(virtualSize > 0 ? Math.Min(rawSize, virtualSize) : rawSize));
			if (StringView((char8*)section, 6) == ".pdata" && section[6] == 0)
			{
				functionTable = imageBase + address;
				functionCount = (uint32)(virtualSize / 12);
			}
		}
		// Code becomes runnable; data stays writable, because reloading rewrites the type descriptions in it.
		for (int i < sectionCount)
		{
			let section = sections + i * 40;
			let flags = *(uint32*)(section + 36);
			if ((flags & 0x20000000) == 0 || (flags & 0x02000000) != 0 || StringView((char8*)section, 8) == ".hostimg")
				continue;
			let size = (uint)Math.Max(*(uint32*)(section + 8), *(uint32*)(section + 16));
			VirtualProtect((void*)(imageBase + (uint) * (uint32*)(section + 12)), size, ExecuteRead, &previous);
		}
		FlushInstructionCache(GetCurrentProcess(), (void*)imageBase, span);
		return true;
	}

	static bool OpenModule(String manifest, String path, out LoadedModule module, HashSet<void*> scriptClasses, String error)
	{
		module = default;
		if (!ReserveArena())
		{
			error.Set("No address space near the program for script libraries. Restart the editor.");
			return false;
		}
		uint imageBase = 0, span = 0, types = 0, count = 0, first = 0, second = 0;
		List<StringView> tokens = scope .();
		List<String> storage = scope .();
		defer
		{
			for (let value in storage)
				delete value;
		}
		List<uint> classes = scope .();
		bool valid = true;
		for (let line in manifest.Split('\n'))
		{
			tokens.Clear();
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.Count == 3 && tokens[0] == "image")
				valid &= Hex(tokens[1], out imageBase) && Hex(tokens[2], out span);
			else if (tokens.Count == 2 && tokens[0] == "types")
				valid &= Hex(tokens[1], out types);
			else if (tokens.Count == 2 && tokens[0] == "count")
				valid &= Hex(tokens[1], out count);
			else if (tokens.Count == 2 && tokens[0] == "gettype")
				valid &= Hex(tokens[1], out first);
			else if (tokens.Count == 2 && tokens[0] == "gettype_")
				valid &= Hex(tokens[1], out second);
			else if (tokens.Count == 3 && tokens[0] == "class")
			{
				uint address;
				valid &= Hex(tokens[2], out address);
				classes.Add(address);
			}
		}
		if (!valid || imageBase == 0 || types == 0 || count == 0 || first == 0 || second == 0)
		{
			error.Set("The script library's manifest is incomplete.");
			return false;
		}
		for (let address in classes)
		{
			if (address < imageBase || address >= imageBase + span)
			{
				error.Set("The script library's manifest names a class outside it.");
				return false;
			}
			scriptClasses.Add((void*)address);
		}
		if (types < imageBase || types >= imageBase + span || count < imageBase || count >= imageBase + span)
		{
			error.Set("The script library's manifest names a type table outside it.");
			return false;
		}
		uint functionTable;
		uint32 functionCount;
		if (!MapImage(path, imageBase, span, out functionTable, out functionCount, error))
			return false;
		module.handle = (void*)imageBase;
		module.table = (Type*)(void*)types;
		module.count = (int32*)(void*)count;
		module.getType = (void*)(HostBase + first);
		module.getTypeById = (void*)(HostBase + second);
		module.functionTable = functionTable;
		module.functionCount = functionCount;
		return true;
	}

	/// A library that was not taken up after all: its pages are simply written over by the next one.
	static void CloseModule(LoadedModule module) { }

	static void KeepModule(LoadedModule module)
	{
		// So that the system can walk the stack through the new code (crash reports, the debugger).
		if (module.functionTable != 0 && module.functionCount > 0)
			RtlAddFunctionTable((void*)module.functionTable, module.functionCount, (uint64)(uint)module.handle);
	}
#endif

	/// Writes down where this program is loaded and where it keeps room for script libraries, for
	/// tools/reload_scripts.py to link them against. Only Windows needs it; elsewhere this does nothing.
	public static bool WriteHostInfo(StringView path)
	{
#if BF_PLATFORM_WINDOWS && BF_64_BIT
		if (!ReserveArena())
			return false;
		return File.WriteAllText(path, scope $"base {HostBase:x}\ntop {sArenaTop:x}\nbottom {sArenaBottom:x}\n") case .Ok;
#else
		return true;
#endif
	}
}
