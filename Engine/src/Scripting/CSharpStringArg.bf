using System;

namespace Tallow;

/// A string of a generated C# binding that passes its strings packed (more arguments than .NET in a browser allows
/// one by one; Managed/Tallow.BindingGen PacksStrings): UTF-8 bytes and their length. The layout of C#'s
/// NativeStringArg.
[CRepr]
struct CSharpStringArg
{
	public char8* Ptr;
	public int32 Length;
}
