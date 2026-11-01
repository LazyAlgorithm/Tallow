using System;
using System.Collections;
using System.Reflection;
using System.IO;

namespace Tallow;

extension ScriptReload
{
	static List<Type> sCanonicalTypes = new .() ~ RetireTypeLookup(_);
	[CLink] static extern int32 atexit(function void() callback);

	static void RetireTypeLookup(List<Type> types)
	{
		// Runtime hooks remain installed during other types' static destructors. Keep a native copy
		// until CRT exit, while releasing the tracked List before Beef's final leak check.
		if (sTypeHooks)
		{
			let lookup = (Type*)Internal.StdMalloc(types.Count * sizeof(Type));
			if (lookup == null) return;
			for (int i < types.Count)
				lookup[i] = types[i];
			sLookup = lookup;
			sLookupCount = types.Count;
			atexit( => FreeExitTypeLookup);
		}
		delete types;
	}

	static void FreeExitTypeLookup()
	{
		Internal.StdFree(sLookup);
		sLookup = null;
		sLookupCount = 0;
	}

	static List<Component> sRetired = new .() ~ DeleteContainerAndItems!(_);
	public static void Retire(Component component)
	{
		sRetired.Add(component);
	}

	static Type* sLookup;
	static int sLookupCount;
	static bool sTypeHooks;
	public static List<Type> ReflectedTypes
	{
		get
		{
			if (sCanonicalTypes.Count == 0)
			{
				sCanonicalTypes.Count = (int)Type.TypeIdEnd;
				for (let type in Type.Types)
					sCanonicalTypes[(int)type.TypeId] = type;
			}
			return sCanonicalTypes;
		}
	}

	static Type ResolveReloadType(int32 id)
	{
		if (sLookup != null) return id >= 0 && id < sLookupCount ? sLookup[id] : null;
		return id >= 0 && id < sCanonicalTypes.Count ? sCanonicalTypes[id] : null;
	}

	// Before canonicalization, metadata objects belong to the module's type universe.
	// Read their known ABI layout without performing a cast against resident type IDs.
	static TypeInstance RawInstance(Type value)
	{
		var type = value;
		return *(TypeInstance*)&type;
	}

	struct RangeBackup { public TypeInstance type; public int32 id; public int32 count; }
	public struct TypeUpdate { public Type original; public Type replacement; public String kind; public bool script; }

#if (BF_PLATFORM_LINUX || BF_PLATFORM_WINDOWS) && BF_64_BIT
	bool InstallTypeLookup(void* first, void* second, String error)
	{
		if (sTypeHooks) return true;
		if (ReflectedTypes.Count == 0)
		{
			error.Set("No resident reflection data.");
			return false;
		}
		delegate Type(int32) callback = scope => ResolveReloadType;
		void* target = null;
		if (callback.GetFuncPtr() case .Ok(let ptr))
			target = ptr;
		if (target == null)
		{
			error.Set("Cannot resolve reflection routing callback.");
			return false;
		}
		let maps = scope String();
	#if BF_PLATFORM_LINUX
		File.ReadAllText("/proc/self/maps", maps).IgnoreError();
	#endif
		List<ProtectedPage> pages = scope .();
		defer
		{
			RestorePages(pages);
		}
		if (first == null || second == null)
		{
			error.Set("Missing reflection exports; rebuild with -rdynamic.");
			return false;
		}
		if (!MakeWritable(first, 12, maps, pages, error) || !MakeWritable(second, 12, maps, pages, error)) return false;
		// x86-64 tail jump; no stack frame or calling convention changes.
		for (let address in scope void*[2](first, second))
		{
			let bytes = (uint8*)address;
			bytes[0] = 0x48;
			bytes[1] = 0xB8;
			*(uint64*)(bytes + 2) = (uint64)(uint)target;
			bytes[10] = 0xFF;
			bytes[11] = 0xE0;
		}
		sTypeHooks = true;
		return true;
	}

	static StringView MetadataKind(Type type, Type* table, int count)
	{
		let obj = Internal.UnsafeCastToPtr(type);
		let vdata = (uint64*)(void*)(*(uint*)obj & ~(uint)0xFF);
		let id = (int)(*vdata >> 32);
		if (id <= 0 || id >= count || table[id] == null) return "";
		return RawInstance(table[id]).[Friend]mName;
	}

	static bool InstanceKind(StringView kind)
	{
		return kind == "TypeInstance" || kind == "SpecializedGenericType" || kind == "UnspecializedGenericType" || kind == "ArrayType";
	}

	static TypeId Translate(TypeId id, List<int32> ids)
	{
		let index = (int)id;
		return index >= 0 && index < ids.Count ? (TypeId)ids[index] : (TypeId)0;
	}

	static void RemapAttributes(void* data, List<int32> ids, HashSet<void*> visited)
	{
		if (data == null || !visited.Add(data)) return;
		// Compiler blobs begin with the attribute count (void* increment in corlib is a no-op).
		let count = *(uint8*)data;
		var ptr = (uint8*)data + 1;
		for (int i < count)
		{
			let size = *(uint16*)ptr;
			let id = (TypeId*)(ptr + 2);
			*id = Translate(*id, ids);
			ptr += size;
		}
	}

	static void RemapType(Type value, StringView kind, List<int32> ids, HashSet<void*> attributes)
	{
		var type = value;
		type.[Friend]mTypeId = Translate(type.TypeId, ids);
		type.[Friend]mBoxedType = Translate(type.[Friend]mBoxedType, ids);
		if (InstanceKind(kind))
		{
			let ti = RawInstance(type);
			int genericCount = 0;
			if (kind == "SpecializedGenericType" || kind == "ArrayType")
			{
				let special = *(SpecializedGenericType*)&type;
				var unspecial = ResolveReloadType((int32)special.[Friend]mUnspecializedType);
				if (unspecial != null)
					genericCount = (*(UnspecializedGenericType*)&unspecial).[Friend]mGenericParamCount;
				special.[Friend]mUnspecializedType = Translate(special.[Friend]mUnspecializedType, ids);
				for (int g < genericCount)
					special.[Friend]mResolvedTypeRefs[g] = Translate(special.[Friend]mResolvedTypeRefs[g], ids);
			}
			ti.[Friend]mBaseType = Translate(ti.[Friend]mBaseType, ids);
			ti.[Friend]mUnderlyingType = Translate(ti.[Friend]mUnderlyingType, ids);
			ti.[Friend]mOuterType = Translate(ti.[Friend]mOuterType, ids);
			HashSet<int> attrIndices = scope .();
			if (ti.[Friend]mCustomAttributesIdx >= 0)
				attrIndices.Add(ti.[Friend]mCustomAttributesIdx);
			if (type.[Friend]mTypeFlags.HasFlag(.Splattable) && ti.[Friend]mFieldDataPtr != null)
			{
				let splats = (TypeInstance.FieldSplatData*)ti.[Friend]mFieldDataPtr;
				for (int i < 3)
					splats.mSplatTypes[i] = Translate(splats.mSplatTypes[i], ids);
			}
			else for (int f < ti.[Friend]mFieldDataCount)
				{
					let field = &ti.[Friend]mFieldDataPtr[f];
					field.mFieldTypeId = Translate(field.mFieldTypeId, ids);
					if (field.mCustomAttributesIdx >= 0)
						attrIndices.Add(field.mCustomAttributesIdx);
				}
			for (int m < ti.[Friend]mMethodDataCount)
			{
				let method = &ti.[Friend]mMethodDataPtr[m];
				method.mReturnType = Translate(method.mReturnType, ids);
				if (method.mCustomAttributesIdx >= 0)
					attrIndices.Add(method.mCustomAttributesIdx);
				if (method.mReturnCustomAttributesIdx >= 0)
					attrIndices.Add(method.mReturnCustomAttributesIdx);
				for (int p < method.mParamCount)
				{
					let param = &method.mParamData[p];
					param.mType = Translate(param.mType, ids);
					if (param.mCustomAttributesIdx >= 0)
						attrIndices.Add(param.mCustomAttributesIdx);
				}
			}
			for (int i < ti.[Friend]mInterfaceCount)
				ti.[Friend]mInterfaceDataPtr[i].mInterfaceType = Translate(ti.[Friend]mInterfaceDataPtr[i].mInterfaceType, ids);
			if (ti.[Friend]mCustomAttrDataPtr != null)
			{
				for (let index in attrIndices)
					RemapAttributes(ti.[Friend]mCustomAttrDataPtr[index], ids, attributes);
			}
			if (ti.[Friend]mTypeClassVData != null && !type.IsInterface)
			{
				let header = (uint64*)ti.[Friend]mTypeClassVData;
				*header = ((uint64)(uint32)Translate((TypeId)(uint32)(*header >> 32), ids) << 32)
					| (uint32)Translate((TypeId)(uint32)(*header), ids);
			}
		}
		else if (kind == "PointerType")
			(*(PointerType*)&type).[Friend]mElementType = Translate((*(PointerType*)&type).[Friend]mElementType, ids);
		else if (kind == "RefType")
			(*(RefType*)&type).[Friend]mElementType = Translate((*(RefType*)&type).[Friend]mElementType, ids);
		else if (kind == "SizedArrayType")
			(*(SizedArrayType*)&type).[Friend]mElementType = Translate((*(SizedArrayType*)&type).[Friend]mElementType, ids);
		else if (kind == "ConstExprType")
			(*(ConstExprType*)&type).[Friend]mValueType = Translate((*(ConstExprType*)&type).[Friend]mValueType, ids);
	}
#endif

	bool ApplyStructural(String text, String error, Scene scene)
	{
#if (BF_PLATFORM_LINUX || BF_PLATFORM_WINDOWS) && BF_64_BIT
		let path = scope String();
		ManifestModule(text, path);
		// Candidate types are told apart by the names the resident ones go by, so those must exist first.
		if (ReflectedTypes.Count == 0)
		{
			error.Set("No resident reflection data.");
			return false;
		}
		HashSet<void*> scriptClasses = scope .();
		LoadedModule module;
		if (!OpenModule(text, path, out module, scriptClasses, error))
			return false;
		bool committed = false;
		defer
		{
			if (!committed)
				CloseModule(module);
		}
		if (!InstallTypeLookup(module.getType, module.getTypeById, error))
			return false;
		let table = module.table;
		let countPtr = module.count;
		if (table == null || countPtr == null || *countPtr <= 0 || *countPtr > 1000000)
		{
			error.Set("Invalid script type table.");
			return false;
		}
		let count = *countPtr;
		List<String> residentNames = scope .();
		List<String> names = scope .();
		List<String> kinds = scope .();
		defer
		{
			for (let name in residentNames)
				delete name;
			for (let name in names)
				delete name;
			for (let storedKind in kinds)
				delete storedKind;
		}
		ResidentTypeNames(residentNames);
		let maps = scope String();
		#if BF_PLATFORM_LINUX
		File.ReadAllText("/proc/self/maps", maps).IgnoreError();
		#endif
		List<ProtectedPage> pages = scope .();
		defer
		{
			RestorePages(pages);
		}

		// The candidate's names are worked out in its own universe of type ids, which needs the resident reflection
		// classes to accept its metadata objects for a moment.
		List<RangeBackup> backups = scope .();
		if (!BorrowReflectionRanges(table, count, residentNames, maps, pages, backups, error))
			return false;
		sLookup = table;
		sLookupCount = count;
		defer
		{
			sLookup = null;
			sLookupCount = 0;
			if (!committed)
				RestoreRanges(backups);
		}
		CandidateTypeNames(table, count, names, kinds);
		// Restore the resident universe before capturing live scene values.
		sLookup = null;
		sLookupCount = 0;
		RestoreRanges(backups);

		// Each candidate type is matched to the resident type of the same name, or gets a new id.
		List<int32> ids = scope .();
		ids.Count = count;
		List<TypeUpdate> updates = scope .();
		List<Type> added = scope .();
		for (int i < count)
		{
			if (i == 0)
			{
				ids[i] = 0;
				continue;
			}
			let type = table[i];
			int found = type != null ? residentNames.IndexOf(names[i]) : -1;
			if (found < 0)
			{
				found = sCanonicalTypes.Count + added.Count;
				added.Add(type);
			}
			ids[i] = (int32)found;
			if (type == null)
				continue;
			let original = found < sCanonicalTypes.Count ? sCanonicalTypes[found] : null;
			bool script = InstanceKind(kinds[i]) && scriptClasses.Contains(RawInstance(type).[Friend]mTypeClassVData);
			if (original != null && !script && InstanceKind(kinds[i]) && original.InstanceSize != RawInstance(type).[Friend]mInstSize)
			{
				error.Set(scope $"Resident layout changed: {names[i]} ({original.InstanceSize} -> {type.InstanceSize}, raw {RawInstance(type).[Friend]mInstSize}, kind {kinds[i]}, id {i}). Full rebuild required.");
				return false;
			}
			updates.Add(.() { original = original, replacement = type, kind = kinds[i], script = script });
			if (!MakeTypeWritable(type, kinds[i], original, maps, pages, error))
				return false;
		}
		let migration = scope ScriptStateMigration();
		if (scene != null)
			migration.Capture(scene, updates);
		#if BF_PLATFORM_LINUX
		if (!MakeModuleDataWritable(path, maps, pages, error))
			return false;
		#endif
		sLookup = table;
		sLookupCount = count;
		HashSet<void*> attributes = scope .();
		for (int i < count)
		{
			if (table[i] != null)
				RemapType(table[i], kinds[i], ids, attributes);
		}
		sLookup = null;
		sLookupCount = 0;
		if (!CommitUpdates(updates, maps, pages, error))
			return false;
		for (let type in added)
			sCanonicalTypes.Add(type);
		// Newly assigned IDs may have gaps for types without emitted reflection.
		for (int i < count)
		{
			if (table[i] != null && ids[i] >= residentNames.Count)
				sCanonicalTypes[ids[i]] = table[i];
		}
		ComponentRegistry.Refresh();
		committed = true;
		KeepModule(module);
		mModules.Add(module.handle);
		mCurrentModule = module.handle;
		if (scene != null)
			migration.Restore(scene);
		return true;
#else
		error.Set("Script reload needs a 64-bit Linux or Windows debug build.");
		return false;
#endif
	}

#if (BF_PLATFORM_LINUX || BF_PLATFORM_WINDOWS) && BF_64_BIT
	/// What a type is matched by between the running program and a new script library: its full name, the kind of
	/// metadata it is, and for an open generic type how many parameters it takes.
	static void TypeKey(Type type, StringView kind, String name)
	{
		type.GetFullName(name);
		name.Append("|", kind);
		if (kind == "UnspecializedGenericType")
		{
			var raw = type;
			name.AppendF("|{}", (*(UnspecializedGenericType*)&raw).[Friend]mGenericParamCount);
		}
	}

	/// The key of every type in the running program, by type id (empty where there is none).
	static void ResidentTypeNames(List<String> names)
	{
		for (let type in sCanonicalTypes)
		{
			let name = new String();
			if (type != null)
				TypeKey(type, type.GetType().GetName(.. scope .()), name);
			names.Add(name);
		}
	}

	/// The key and metadata kind of every type in the candidate library, by its own type id.
	static void CandidateTypeNames(Type* table, int count, List<String> names, List<String> kinds)
	{
		for (int i < count)
		{
			let name = new String();
			let kind = new String();
			if (table[i] != null)
			{
				kind.Set(MetadataKind(table[i], table, count));
				TypeKey(table[i], kind, name);
			}
			names.Add(name);
			kinds.Add(kind);
		}
	}

	/// Gives the resident System.Reflection classes the candidate's inheritance ranges, so that casts on the
	/// candidate's metadata objects work while its names are read. RestoreRanges puts them back.
	static bool BorrowReflectionRanges(Type* table, int count, List<String> residentNames, String maps, List<ProtectedPage> pages, List<RangeBackup> backups, String error)
	{
		for (int i < count)
		{
			let type = table[i];
			if (type == null)
				continue;
			let kind = MetadataKind(type, table, count);
			if (!InstanceKind(kind))
				continue;
			let ti = RawInstance(type);
			if (ti.[Friend]mNamespace != "System.Reflection")
				continue;
			for (int j < sCanonicalTypes.Count)
			{
				if (sCanonicalTypes[j] == null || residentNames[j] != scope $"System.Reflection.{ti.[Friend]mName}|TypeInstance")
					continue;
				let host = RawInstance(sCanonicalTypes[j]);
				if (!MakeWritable(Internal.UnsafeCastToPtr(host), typeof(TypeInstance).InstanceSize, maps, pages, error))
					return false;
				backups.Add(.() { type = host, id = host.[Friend]mInheritanceId, count = host.[Friend]mInheritanceCount });
				host.[Friend]mInheritanceId = ti.[Friend]mInheritanceId;
				host.[Friend]mInheritanceCount = ti.[Friend]mInheritanceCount;
			}
		}
		return true;
	}

	static void RestoreRanges(List<RangeBackup> backups)
	{
		for (let saved in backups)
		{
			saved.type.[Friend]mInheritanceId = saved.id;
			saved.type.[Friend]mInheritanceCount = saved.count;
		}
	}

	/// Makes a candidate type's metadata, and the reflected arrays it points to, writable before they are remapped.
	static bool MakeTypeWritable(Type type, StringView kind, Type original, String maps, List<ProtectedPage> pages, String error)
	{
		if (!MakeWritable(Internal.UnsafeCastToPtr(type), 256, maps, pages, error))
			return false;
		if (!InstanceKind(kind))
			return true;
		let ti = RawInstance(type);
		if (!MakeWritable(ti.[Friend]mFieldDataPtr, ti.[Friend]mFieldDataCount * sizeof(TypeInstance.FieldData), maps, pages, error))
			return false;
		if (!MakeWritable(ti.[Friend]mMethodDataPtr, ti.[Friend]mMethodDataCount * sizeof(TypeInstance.MethodData), maps, pages, error))
			return false;
		for (int m < ti.[Friend]mMethodDataCount)
		{
			let method = ti.[Friend]mMethodDataPtr[m];
			if (!MakeWritable(method.mParamData, method.mParamCount * sizeof(TypeInstance.ParamData), maps, pages, error))
				return false;
		}
		if (ti.[Friend]mTypeClassVData != null && !MakeWritable(ti.[Friend]mTypeClassVData, 256, maps, pages, error))
			return false;
		if (original != null && !MakeWritable(Internal.UnsafeCastToPtr(original), original.GetType().InstanceSize, maps, pages, error))
			return false;
		return true;
	}

#if BF_PLATFORM_LINUX
	/// Attribute blobs and interface maps live in the candidate library's read-only data pages: those (and only
	/// those) are made writable. On Windows the library's data was put in place writable to begin with.
	static bool MakeModuleDataWritable(StringView path, String maps, List<ProtectedPage> pages, String error)
	{
		for (let line in maps.Split('\n'))
		{
			if (!line.Contains(path) || !line.Contains(" r--p "))
				continue;
			let dash = line.IndexOf('-');
			let space = line.IndexOf(' ');
			if (!(uint64.Parse(line.Substring(0, dash), .HexNumber) case .Ok(let lower)))
				continue;
			if (!(uint64.Parse(line.Substring(dash + 1, space - dash - 1), .HexNumber) case .Ok(let upper)))
				continue;
			if (!MakeWritable((void*)(uint)lower, (int)(upper - lower), maps, pages, error))
				return false;
		}
		return true;
	}
#endif

	/// Commits the new metadata over the resident types: a script class is replaced whole, any other type takes the
	/// new inheritance range (which runtime casts use).
	static bool CommitUpdates(List<TypeUpdate> updates, String maps, List<ProtectedPage> pages, String error)
	{
		for (let update in updates)
		{
			if (update.original == null || !InstanceKind(update.kind))
				continue;
			let a = RawInstance(update.original);
			let b = RawInstance(update.replacement);
			if (update.script)
			{
				Internal.MemCpy(Internal.UnsafeCastToPtr(a), Internal.UnsafeCastToPtr(b), typeof(TypeInstance).InstanceSize);
				continue;
			}
			a.[Friend]mInheritanceId = b.[Friend]mInheritanceId;
			a.[Friend]mInheritanceCount = b.[Friend]mInheritanceCount;
			if (a.[Friend]mTypeClassVData != null && b.[Friend]mTypeClassVData != null && !a.IsInterface)
			{
				if (!MakeWritable(a.[Friend]mTypeClassVData, 16, maps, pages, error))
					return false;
				*((int32*)((uint8*)a.[Friend]mTypeClassVData + 8)) = b.[Friend]mInheritanceId;
			}
		}
		return true;
	}
#endif
}
