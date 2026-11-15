using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// The built-in components' Inspector fields as text, for tools/gen_csharp_components.py, which makes the typed C#
/// handles (Managed/Tallow.API/NativeComponents.Generated.cs) from it. `TallowLauncher --write-component-catalog`.
///   component <tab> Tallow.Name
///   field <tab> Tallow.Name <tab> fieldName <tab> kind <tab> type (enum type name, list element kind) <tab> flags
///   enum <tab> Tallow.EnumType <tab> Case=Value <tab> ...
static class NativeComponentCatalog
{
	public static bool Write(StringView path)
	{
		let text = scope String();
		let enums = scope List<Type>();
		for (let info in HandleComponents.Types)
		{
			text.AppendF("component\t{}\n", info.fullName);
			let size = Math.Max(info.dataType.InstanceSize, 1);
			let data = new uint8[size + 16];
			defer delete data;
			let aligned = (void*)(((int)(void*)data.Ptr + 15) & ~15);
			let fields = scope List<FieldRef>();
			DataComponents.GetFields(info.dataType, aligned, fields);
			for (let field in fields)
			{
				let type = scope String();
				if (field.kind == .Enum && field.type != null)
				{
					field.type.GetFullName(type);
					if (!enums.Contains(field.type))
						enums.Add(field.type);
				}
				else if (field.kind == .List)
					type.Append(field.elementKind.ToString(.. scope .()));
				let flags = scope String();
				if (field.hidden)
					flags.Append("hidden ");
				if (field.advanced)
					flags.Append("advanced ");
				if (field.sync)
					flags.Append("sync ");
				flags.TrimEnd();
				text.AppendF("field\t{}\t{}\t{}\t{}\t{}\n", info.fullName, field.name, field.kind, type, flags);
			}
		}
		for (let type in enums)
		{
			text.Append("enum\t");
			type.GetFullName(text);
			for (let field in type.GetFields())
			{
				if (!field.IsStatic || field.FieldType != type)
					continue;
				let value = field.GetValue(null).GetValueOrDefault();
				int64 number = 0;
				if (value.HasValue)
					number = (int64)value.Get<int32>();
				text.AppendF("\t{}={}", field.Name, number);
			}
			text.Append('\n');
		}
		return File.WriteAllText(path, text) case .Ok;
	}
}
