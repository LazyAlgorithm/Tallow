// Isolated resolve-only compiler worker. The controller supplies the complete project graph and unsaved buffers.
// Wire offsets and revisions refer to UTF-8 bytes, not display columns. See docs/beef-semantic-editor.md.
#include <iostream>
#include <iomanip>
#include <sstream>
#include <string>
#include <unordered_map>
#include <stdexcept>
#include <cstdlib>
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
void* CompilerSymbol(const char* name)
{
	static HMODULE runtime = []
	{
		const char* dist = std::getenv("TALLOW_BEEF_DIST");
		if (dist)
			SetDllDirectoryA(dist);
		return LoadLibraryA("BeefySysLib64.dll");
	}();
	static HMODULE compiler = LoadLibraryA("IDEHelper64.dll");
	auto address = compiler ? GetProcAddress(compiler, name) : nullptr;
	if (!address && runtime)
		address = GetProcAddress(runtime, name);
	if (!address)
		throw std::runtime_error(std::string("Compiler ABI entry is unavailable: ") + name);
	return reinterpret_cast<void*>(address);
}
void BfpSystem_Init(int a0, int a1)
{
	using Function = void (*)(int, int);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfpSystem_Init"));
	return fn(a0, a1);
}
void IDEHelper_ProgramStart()
{
	using Function = void (*)();
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("IDEHelper_ProgramStart"));
	return fn();
}
void IDEHelper_ProgramDone()
{
	using Function = void (*)();
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("IDEHelper_ProgramDone"));
	return fn();
}
void* BfSystem_Create()
{
	using Function = void* (*)();
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfSystem_Create"));
	return fn();
}
void BfSystem_Delete(void* a0)
{
	using Function = void (*)(void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfSystem_Delete"));
	return fn(a0);
}
void BfSystem_Lock(void* a0, int a1)
{
	using Function = void (*)(void*, int);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfSystem_Lock"));
	return fn(a0, a1);
}
void BfSystem_Unlock(void* a0)
{
	using Function = void (*)(void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfSystem_Unlock"));
	return fn(a0);
}
void* BfSystem_CreateProject(void* a0, const char* a1, const char* a2)
{
	using Function = void* (*)(void*, const char*, const char*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfSystem_CreateProject"));
	return fn(a0, a1, a2);
}
void BfProject_SetOptions(void* a0, int a1, const char* a2, const char* a3, int a4, int a5, int a6, int a7, int a8)
{
	using Function = void (*)(void*, int, const char*, const char*, int, int, int, int, int);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfProject_SetOptions"));
	return fn(a0, a1, a2, a3, a4, a5, a6, a7, a8);
}
void BfProject_AddDependency(void* a0, void* a1)
{
	using Function = void (*)(void*, void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfProject_AddDependency"));
	return fn(a0, a1);
}
void* BfSystem_CreateCompiler(void* a0, bool a1)
{
	using Function = void* (*)(void*, bool);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfSystem_CreateCompiler"));
	return fn(a0, a1);
}
void BfCompiler_Delete(void* a0)
{
	using Function = void (*)(void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfCompiler_Delete"));
	return fn(a0);
}
void BfCompiler_SetOptions(void* a0, void* a1, int a2, const char* a3, const char* a4, int a5, int a6, int a7, int a8,
						   int a9, char* a10, char* a11)
{
	using Function = void (*)(void*, void*, int, const char*, const char*, int, int, int, int, int, char*, char*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfCompiler_SetOptions"));
	return fn(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11);
}
bool BfCompiler_Compile(void* a0, void* a1, const char* a2)
{
	using Function = bool (*)(void*, void*, const char*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfCompiler_Compile"));
	return fn(a0, a1, a2);
}
bool BfCompiler_ClassifySource(void* a0, void* a1, void* a2)
{
	using Function = bool (*)(void*, void*, void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfCompiler_ClassifySource"));
	return fn(a0, a1, a2);
}
const char* BfCompiler_GetAutocompleteInfo(void* a0)
{
	using Function = const char* (*)(void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfCompiler_GetAutocompleteInfo"));
	return fn(a0);
}
void* BfSystem_CreatePassInstance(void* a0)
{
	using Function = void* (*)(void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfSystem_CreatePassInstance"));
	return fn(a0);
}
void BfPassInstance_Delete(void* a0)
{
	using Function = void (*)(void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfPassInstance_Delete"));
	return fn(a0);
}
const char* BfPassInstance_PopOutString(void* a0)
{
	using Function = const char* (*)(void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfPassInstance_PopOutString"));
	return fn(a0);
}
int BfPassInstance_GetErrorCount(void* a0)
{
	using Function = int (*)(void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfPassInstance_GetErrorCount"));
	return fn(a0);
}
const char* BfPassInstance_GetErrorData(void* a0, int a1, int& a2, bool& a3, bool& a4, bool& a5, signed char& a6,
										bool& a7, char*& a8, char*& a9, int& a10, int& a11, int* a12, int* a13,
										int& a14)
{
	using Function = const char* (*)(void*, int, int&, bool&, bool&, bool&, signed char&, bool&, char*&, char*&, int&,
									 int&, int*, int*, int&);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfPassInstance_GetErrorData"));
	return fn(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14);
}
void BfSystem_RemoveOldParsers(void* a0)
{
	using Function = void (*)(void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfSystem_RemoveOldParsers"));
	return fn(a0);
}
void BfSystem_RemoveOldData(void* a0)
{
	using Function = void (*)(void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfSystem_RemoveOldData"));
	return fn(a0);
}
void* BfSystem_CreateParser(void* a0, void* a1)
{
	using Function = void* (*)(void*, void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfSystem_CreateParser"));
	return fn(a0, a1);
}
void BfSystem_DeleteParser(void* a0, void* a1)
{
	using Function = void (*)(void*, void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfSystem_DeleteParser"));
	return fn(a0, a1);
}
void BfParser_SetSource(void* a0, const char* a1, int a2, const char* a3, int a4)
{
	using Function = void (*)(void*, const char*, int, const char*, int);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfParser_SetSource"));
	return fn(a0, a1, a2, a3, a4);
}
void BfParser_SetNextRevision(void* a0, void* a1)
{
	using Function = void (*)(void*, void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfParser_SetNextRevision"));
	return fn(a0, a1);
}
void BfParser_SetIsClassifying(void* a0)
{
	using Function = void (*)(void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfParser_SetIsClassifying"));
	return fn(a0);
}
void BfParser_SetAutocomplete(void* a0, int a1)
{
	using Function = void (*)(void*, int);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfParser_SetAutocomplete"));
	return fn(a0, a1);
}
bool BfParser_Parse(void* a0, void* a1, bool a2)
{
	using Function = bool (*)(void*, void*, bool);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfParser_Parse"));
	return fn(a0, a1, a2);
}
bool BfParser_Reduce(void* a0, void* a1)
{
	using Function = bool (*)(void*, void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfParser_Reduce"));
	return fn(a0, a1);
}
bool BfParser_BuildDefs(void* a0, void* a1, void* a2, bool a3)
{
	using Function = bool (*)(void*, void*, void*, bool);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfParser_BuildDefs"));
	return fn(a0, a1, a2, a3);
}
void* BfParser_CreateResolvePassData(void* a0, int a1, bool a2)
{
	using Function = void* (*)(void*, int, bool);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfParser_CreateResolvePassData"));
	return fn(a0, a1, a2);
}
void BfResolvePassData_SetDocumentationRequest(void* a0, char* a1)
{
	using Function = void (*)(void*, char*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfResolvePassData_SetDocumentationRequest"));
	return fn(a0, a1);
}
void BfResolvePassData_Delete(void* a0)
{
	using Function = void (*)(void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfResolvePassData_Delete"));
	return fn(a0);
}
void BfParser_CreateClassifier(void* a0, void* a1, void* a2, void* a3)
{
	using Function = void (*)(void*, void*, void*, void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfParser_CreateClassifier"));
	return fn(a0, a1, a2, a3);
}
void BfParser_FinishClassifier(void* a0, void* a1)
{
	using Function = void (*)(void*, void*);
	static auto fn = reinterpret_cast<Function>(CompilerSymbol("BfParser_FinishClassifier"));
	return fn(a0, a1);
}
#else
extern "C"
{
	void BfpSystem_Init(int, int);
	void IDEHelper_ProgramStart();
	void IDEHelper_ProgramDone();
	void* BfSystem_Create();
	void BfSystem_Delete(void*);
	void BfSystem_Lock(void*, int);
	void BfSystem_Unlock(void*);
	void* BfSystem_CreateProject(void*, const char*, const char*);
	void BfProject_SetOptions(void*, int, const char*, const char*, int, int, int, int, int);
	void BfProject_AddDependency(void*, void*);
	void* BfSystem_CreateCompiler(void*, bool);
	void BfCompiler_Delete(void*);
	void BfCompiler_SetOptions(void*, void*, int, const char*, const char*, int, int, int, int, int, char*, char*);
	bool BfCompiler_Compile(void*, void*, const char*);
	bool BfCompiler_ClassifySource(void*, void*, void*);
	const char* BfCompiler_GetAutocompleteInfo(void*);
	void* BfSystem_CreatePassInstance(void*);
	void BfPassInstance_Delete(void*);
	const char* BfPassInstance_PopOutString(void*);
	int BfPassInstance_GetErrorCount(void*);
	const char* BfPassInstance_GetErrorData(void*, int, int&, bool&, bool&, bool&, signed char&, bool&, char*&, char*&,
											int&, int&, int*, int*, int&);
	void BfSystem_RemoveOldParsers(void*);
	void BfSystem_RemoveOldData(void*);
	void* BfSystem_CreateParser(void*, void*);
	void BfSystem_DeleteParser(void*, void*);
	void BfParser_SetSource(void*, const char*, int, const char*, int);
	void BfParser_SetNextRevision(void*, void*);
	void BfParser_SetIsClassifying(void*);
	void BfParser_SetAutocomplete(void*, int);
	bool BfParser_Parse(void*, void*, bool);
	bool BfParser_Reduce(void*, void*);
	bool BfParser_BuildDefs(void*, void*, void*, bool);
	void* BfParser_CreateResolvePassData(void*, int, bool);
	void BfResolvePassData_SetDocumentationRequest(void*, char*);
	void BfResolvePassData_Delete(void*);
	void BfParser_CreateClassifier(void*, void*, void*, void*);
	void BfParser_FinishClassifier(void*, void*);
}
#endif
std::string EncodeHex(const std::string& v)
{
	std::string out;
	const char* h = "0123456789abcdef";
	for (unsigned char c : v)
	{
		out += h[c >> 4];
		out += h[c & 15];
	}
	return out;
}
std::string DecodeHex(const std::string& v)
{
	if (v.size() % 2)
		throw std::runtime_error("odd hex");
	std::string out;
	for (size_t i = 0; i < v.size(); i += 2)
	{
		auto digit = [](char c)
		{
			if (c >= '0' && c <= '9')
				return c - '0';
			if (c >= 'a' && c <= 'f')
				return c - 'a' + 10;
			throw std::runtime_error("invalid hex");
		};
		out += char(digit(v[i]) * 16 + digit(v[i + 1]));
	}
	return out;
}
struct Source
{
	void* project = nullptr;
	void* parser = nullptr;
	std::string text;
	int revision = 0;
};
void WriteDiagnostics(void* pass, int id, int revision)
{
	for (int i = 0; i < BfPassInstance_GetErrorCount(pass); ++i)
	{
		int code = 0, start = 0, end = 0, line = 0, column = 0, more = 0;
		bool warning = false, after = false, deferred = false, persistent = false;
		signed char specializing = 0;
		char* project = nullptr;
		char* file = nullptr;
		const char* message = BfPassInstance_GetErrorData(pass, i, code, warning, after, deferred, specializing,
														  persistent, project, file, start, end, &line, &column, more);
		std::cout << "TALLOW_DIAG " << id << " " << revision << " " << warning << " "
				  << std::quoted(EncodeHex(file ? file : "")) << " " << start << " " << end << " " << line << " "
				  << column << " " << std::quoted(EncodeHex(message ? message : "")) << "\n";
	}
}
struct Context
{
	void* system = BfSystem_Create();
	void* compiler = BfSystem_CreateCompiler(system, true);
	std::unordered_map<std::string, void*> projects;
	std::unordered_map<std::string, Source> sources;
};

void Configure(Context& context, std::istringstream& in)
{
	auto system = context.system;
	auto compiler = context.compiler;
	auto& projects = context.projects;
	auto& sources = context.sources;

	std::string triple;
	in >> triple;
	BfCompiler_SetOptions(compiler, nullptr, -1, triple.c_str(), "", 0, 0, 1, 1, 0x4000, (char*)"malloc",
						  (char*)"free");
}

void AddProject(Context& context, std::istringstream& in)
{
	auto system = context.system;
	auto compiler = context.compiler;
	auto& projects = context.projects;
	auto& sources = context.sources;

	std::string id, path, defines, startup;
	int target;
	in >> std::quoted(id) >> std::quoted(path) >> std::quoted(defines) >> std::quoted(startup) >> target;
	auto p = BfSystem_CreateProject(system, id.c_str(), path.c_str());
	projects[id] = p;
	defines = DecodeHex(defines);
	BfProject_SetOptions(p, target, startup.c_str(), defines.c_str(), 0, 0, 0, 0, 0);
}

void AddDependency(Context& context, std::istringstream& in)
{
	auto system = context.system;
	auto compiler = context.compiler;
	auto& projects = context.projects;
	auto& sources = context.sources;

	std::string a, b;
	in >> std::quoted(a) >> std::quoted(b);
	BfProject_AddDependency(projects.at(a), projects.at(b));
}

void SetSource(Context& context, std::istringstream& in)
{
	auto system = context.system;
	auto compiler = context.compiler;
	auto& projects = context.projects;
	auto& sources = context.sources;

	std::string project, path, text;
	int revision;
	in >> std::quoted(project) >> std::quoted(path) >> revision >> std::quoted(text);
	auto& src = sources[path];
	auto old = src.parser;
	src.project = projects.at(project);
	src.parser = BfSystem_CreateParser(system, src.project);
	src.text = DecodeHex(text);
	src.revision = revision;
	if (old)
	{
		BfParser_SetNextRevision(old, src.parser);
		BfSystem_DeleteParser(system, old);
	}
	BfParser_SetSource(src.parser, src.text.c_str(), (int)src.text.size(), path.c_str(), revision);
	auto pass = BfSystem_CreatePassInstance(system);
	BfParser_Parse(src.parser, pass, false);
	BfParser_Reduce(src.parser, pass);
	BfParser_BuildDefs(src.parser, pass, nullptr, false);
	BfPassInstance_Delete(pass);
}

void Prepare(Context& context, std::istringstream& in)
{
	auto system = context.system;
	auto compiler = context.compiler;
	auto& projects = context.projects;
	auto& sources = context.sources;

	auto pass = BfSystem_CreatePassInstance(system);
	auto resolve = BfParser_CreateResolvePassData(nullptr, 1, false);
	bool ok = BfCompiler_ClassifySource(compiler, pass, resolve);
	BfResolvePassData_Delete(resolve);
	std::string messages;
	while (auto s = BfPassInstance_PopOutString(pass))
		messages += s;
	std::cout << "TALLOW_READY " << ok << " " << BfPassInstance_GetErrorCount(pass) << " "
			  << std::quoted(EncodeHex(messages)) << "\n"
			  << std::flush;
	BfPassInstance_Delete(pass);
}

void Resolve(Context& context, std::istringstream& in)
{
	auto system = context.system;
	auto compiler = context.compiler;
	auto& projects = context.projects;
	auto& sources = context.sources;

	std::string path, documentation;
	int cursor, kind, id;
	in >> std::quoted(path) >> cursor >> kind >> id >> std::quoted(documentation);
	auto& src = sources.at(path);
	if (cursor < -1 || cursor > (int)src.text.size() || (kind != 1 && kind != 3 && kind != 5 && kind != 6))
		throw std::runtime_error("invalid resolve request");
	bool transient = kind != 1;
	auto parser = BfSystem_CreateParser(system, src.project);
	BfParser_SetIsClassifying(parser);
	BfParser_SetSource(parser, src.text.c_str(), (int)src.text.size(), path.c_str(), src.revision);
	if (transient)
		BfParser_SetAutocomplete(parser, cursor);
	else
	{
		BfParser_SetNextRevision(src.parser, parser);
		BfSystem_DeleteParser(system, src.parser);
		src.parser = parser;
	}
	auto pass = BfSystem_CreatePassInstance(system);
	auto resolve = BfParser_CreateResolvePassData(parser, kind, false);
	if (!documentation.empty())
		BfResolvePassData_SetDocumentationRequest(resolve, documentation.data());
	BfParser_Parse(parser, pass, false);
	BfParser_Reduce(parser, pass);
	BfParser_BuildDefs(parser, pass, resolve, false);
	BfParser_CreateClassifier(parser, pass, resolve, nullptr);
	bool ok = BfCompiler_ClassifySource(compiler, pass, resolve);
	const char* result = BfCompiler_GetAutocompleteInfo(compiler);
	std::string info = result ? result : "";
	BfParser_FinishClassifier(parser, resolve);
	std::string messages;
	while (auto s = BfPassInstance_PopOutString(pass))
		messages += s;
	WriteDiagnostics(pass, id, src.revision);
	std::cout << "TALLOW_RESULT " << id << " " << src.revision << " " << ok << " " << std::quoted(EncodeHex(info))
			  << " " << std::quoted(EncodeHex(messages)) << "\n"
			  << std::flush;
	BfResolvePassData_Delete(resolve);
	BfPassInstance_Delete(pass);
	if (transient)
		BfSystem_DeleteParser(system, parser);
	BfSystem_RemoveOldParsers(system);
	BfSystem_RemoveOldData(system);
}

void TraceStartup(const char* stage)
{
	if (std::getenv("TALLOW_ANALYSIS_TRACE"))
		std::cerr << "Beef analysis: " << stage << "\n" << std::flush;
}

int Run()
{
	TraceStartup("initialising platform");
	BfpSystem_Init(2, 0);
	TraceStartup("initialising compiler library");
	IDEHelper_ProgramStart();
	TraceStartup("creating resolve context");
	Context context;
	TraceStartup("context ready");
	auto system = context.system;
	auto compiler = context.compiler;
	std::cout << "TALLOW_HELLO 1 b62833e327d6b08f3566b31102c57646de6916b0\n" << std::flush;
	try
	{
		for (std::string line; std::getline(std::cin, line);)
		{
			std::istringstream in(line);
			std::string cmd;
			in >> cmd;
			if (cmd == "QUIT")
				break;
			if (line.size() > 64 * 1024 * 1024)
				throw std::runtime_error("request too large");
			BfSystem_Lock(system, 0);
			if (cmd == "CONFIG")
			{
				Configure(context, in);
			}
			else if (cmd == "PROJECT")
			{
				AddProject(context, in);
			}
			else if (cmd == "DEPEND")
			{
				AddDependency(context, in);
			}
			else if (cmd == "SOURCE")
			{
				SetSource(context, in);
			}
			else if (cmd == "READY")
			{
				Prepare(context, in);
			}
			else if (cmd == "RESOLVE")
			{
				Resolve(context, in);
			}
			else
				throw std::runtime_error("unknown command");
			if (in.fail())
				throw std::runtime_error("malformed command");
			BfSystem_Unlock(system);
		}
	}
	catch (const std::exception& e)
	{
		std::cerr << e.what() << "\n";
		return 2;
	}
	BfCompiler_Delete(compiler);
	BfSystem_Delete(system);
	IDEHelper_ProgramDone();
	return 0;
}

int main()
{
	try
	{
		return Run();
	}
	catch (const std::exception& error)
	{
		std::cerr << "Beef analysis startup failed: " << error.what() << "\n";
		return 2;
	}
}
