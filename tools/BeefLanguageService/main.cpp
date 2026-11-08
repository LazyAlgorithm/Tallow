// A process boundary around Beef's own resolve compiler. The editor supplies a snapshot;
// no source files are written, and a compiler failure cannot take the editor down.
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include <unordered_map>
#include <cstdlib>
#include <cctype>

#ifdef _WIN32
#include <windows.h>
#define BF_API(result, name, parameters) static result (__stdcall *name) parameters;
#else
#define BF_API(result, name, parameters) extern "C" result name parameters;
#endif
#include "api.inc"
#undef BF_API

static void LoadCompiler()
{
#ifdef _WIN32
	const char* directory = std::getenv("BEEF_IDE_DIR");
	if (!directory) throw std::runtime_error("Beef IDE directory is not set");
	SetDllDirectoryA(directory);
	HMODULE module = LoadLibraryA((std::string(directory) + "\\IDEHelper64.dll").c_str());
	if (!module) throw std::runtime_error("Could not load the installed Beef IDE compiler");
#define BF_API(result, name, parameters) name = (decltype(name))GetProcAddress(module, #name); if (!name) throw std::runtime_error("Beef compiler API unavailable: " #name);
#include "api.inc"
#undef BF_API
#endif
}

static std::vector<std::string> Split(const std::string& text, char separator)
{
	std::vector<std::string> result;
	std::istringstream input(text);
	std::string part;
	while (std::getline(input, part, separator))
	{
		if (separator == '\n' && !part.empty() && part.back() == '\r') part.pop_back();
		result.push_back(part);
	}
	return result;
}

static std::string Read(const std::string& path)
{
	std::ifstream input(path, std::ios::binary);
	if (!input) throw std::runtime_error("Cannot read " + path);
	return std::string(std::istreambuf_iterator<char>(input), {});
}

static std::string Clean(std::string value)
{
	for (char& c : value) if (c == '\t' || c == '\r' || c == '\n') c = ' ';
	return value;
}

static void Diagnostics(void* pass, const std::string& output)
{
	std::ofstream out(output);
	for (int i = 0; i < BfPassInstance_GetErrorCount(pass); i++)
	{
		int code, start, end, line, column, more;
		bool warning, after, deferred, persistent;
		signed char specializing;
		const char *project = nullptr, *file = nullptr;
		const char* message = BfPassInstance_GetErrorData(pass, i, &code, &warning, &after, &deferred,
			&specializing, &persistent, &project, &file, &start, &end, &line, &column, &more);
		if (message && file)
			out << "diagnostic\t" << file << '\t' << line << '\t' << column << '\t'
				<< (warning ? "warning" : "error") << '\t' << Clean(message) << '\n';
	}
}

// Only member-prefix typing can bypass the full declaration update. Other source changes
// may add/remove a member or change inference, so the compiler must process them first.
static bool OnlyCompletionPrefixChanged(const std::string& before, const std::string& after, int cursor)
{
	if (cursor < 0 || cursor > (int)after.size()) return false;
	size_t start = (size_t)cursor;
	while (start > 0 && (isalnum((unsigned char)after[start - 1]) || after[start - 1] == '_')) start--;
	if (start == 0 || after[start - 1] != '.') return false;
	size_t end = (size_t)cursor;
	while (end < after.size() && (isalnum((unsigned char)after[end]) || after[end] == '_')) end++;
	if (before.size() < start || before.compare(0, start, after, 0, start) != 0) return false;
	size_t oldEnd = start;
	while (oldEnd < before.size() && (isalnum((unsigned char)before[oldEnd]) || before[oldEnd] == '_')) oldEnd++;
	return before.compare(oldEnd, std::string::npos, after, end, std::string::npos) == 0;
}

struct Workspace
{
	void* system = nullptr;
	void* compiler = nullptr;
	std::vector<void*> projects;
	std::unordered_map<std::string, void*> parsers;
	std::unordered_map<std::string, std::string> sources;
	std::string graph;
	int revision = 0;
};

static int Query(Workspace& workspace, const std::vector<std::string>& args)
{
	try
	{
		const std::string mode = args.at(1), target = args.at(2), output = args.at(4);
		const int cursor = std::stoi(args.at(3));
		auto lines = Split(Read(args.at(0)), '\n');
		std::string graph;
		for (const auto& line : lines)
		{
			auto fields = Split(line, '\t');
			if (fields.empty()) continue;
			if (fields.at(0) == "project") graph += line + "\n";
			else if (fields.at(0) == "source") graph += fields.at(1) + "\t" + fields.at(2) + "\n";
		}
		if (workspace.system && graph != workspace.graph) return 2;
		const bool first = workspace.system == nullptr;
		workspace.graph = graph;
		if (first) workspace.system = BfSystem_Create();
		void* system = workspace.system;
		if (first)
		{
			BfSystem_Lock(system, 0);
			workspace.compiler = BfSystem_CreateCompiler(system, true);
		}
		void* compiler = workspace.compiler;
		#ifdef _WIN32
		const char* triple = "x86_64-pc-windows-msvc";
#else
		const char* triple = "x86_64-unknown-linux-gnu";
#endif
		if (first) BfCompiler_SetOptions(compiler, nullptr, 0, triple, "", 0, 0, 0, 1, 0, "malloc", "free");
		void* pass = BfSystem_CreatePassInstance(system);
		auto& projects = workspace.projects;
		auto& parsers = workspace.parsers;
		bool needsCompile = first || mode == "diagnostics" || mode == "references" || mode == "rename";
		const bool interactive = mode == "completion" || mode == "signature" || mode == "symbol" || mode == "definition";
		void* targetProject = nullptr;
		std::string targetSource;
		for (const auto& line : lines)
		{
			auto fields = Split(line, '\t');
			if (fields.empty()) continue;
			if (fields[0] == "project" && first)
			{
				void* project = BfSystem_CreateProject(system, fields.at(1).c_str(), fields.at(2).c_str());
				std::string defines = fields.at(3);
				for (char& c : defines) if (c == '|') c = '\n';
				BfProject_SetOptions(project, 0, "", defines.c_str(), 0, 0, 0, 0, 0);
				if (fields.size() > 4 && fields[4] != "-")
				{
					for (const auto& index : Split(fields[4], ','))
						BfProject_AddDependency(project, projects.at(std::stoi(index)));
				}
				projects.push_back(project);
			}
			else if (fields[0] == "source")
			{
				const std::string& path = fields.at(2);
				std::string text = Read(fields.at(3));
				void* project = projects.at(std::stoi(fields.at(1)));
				if (path == target) { targetSource = text; targetProject = project; }
				if (!first && interactive && path == target &&
					(workspace.sources[path] == text || (mode == "completion" && OnlyCompletionPrefixChanged(workspace.sources[path], text, cursor)))) continue;
				if (!first && workspace.sources[path] == text) continue;
				needsCompile = true;
				workspace.sources[path] = text;
				void* parser = BfSystem_CreateParser(system, project);
				if (parsers.count(path)) BfParser_SetNextRevision(parsers[path], parser);
				BfParser_SetSource(parser, text.c_str(), (int)text.size(), path.c_str(), ++workspace.revision);
				BfParser_Parse(parser, pass, false);
				BfParser_Reduce(parser, pass);
				BfParser_BuildDefs(parser, pass, nullptr, false);
				parsers[path] = parser;
				if (path == target) { targetSource = text; targetProject = project; }
			}
		}
		void* initialResolve = BfParser_CreateResolvePassData(nullptr, 1, false);
		if (needsCompile) BfCompiler_ClassifySource(compiler, pass, initialResolve);
		Diagnostics(pass, output + ".diagnostics");
		BfResolvePassData_Delete(initialResolve);
		BfPassInstance_Delete(pass);
		BfSystem_RemoveOldData(system);
		if (mode == "diagnostics") return 0;
		if (!targetProject) throw std::runtime_error("Source is outside the workspace");
		pass = BfSystem_CreatePassInstance(system);
		void* parser = BfSystem_CreateParser(system, targetProject);
		BfParser_SetIsClassifying(parser);
		BfParser_SetSource(parser, targetSource.c_str(), (int)targetSource.size(), target.c_str(), ++workspace.revision);
		BfParser_SetAutocomplete(parser, cursor);
		int kind = (mode == "completion" || mode == "signature") ? 3 : mode == "definition" ? 5 : mode == "symbol" ? 14 : 6;
		void* resolve = BfParser_CreateResolvePassData(parser, kind, false);
		BfParser_Parse(parser, pass, false);
		BfParser_Reduce(parser, pass);
		BfParser_BuildDefs(parser, pass, resolve, false);
		// CharData is four bytes in Beef's source classifier (character, display pass, display type, flags).
		std::vector<unsigned char> classification((targetSource.size() + 1) * 4);
		for (size_t i = 0; i < targetSource.size(); i++) classification[i * 4] = targetSource[i];
		BfParser_CreateClassifier(parser, pass, resolve, classification.data());
		BfCompiler_ClassifySource(compiler, pass, resolve);
		BfParser_FinishClassifier(parser, resolve);
		if (!needsCompile) Diagnostics(pass, output + ".diagnostics");
		std::string info = BfCompiler_GetAutocompleteInfo(compiler);
		std::ofstream(output) << info;
		if (mode == "references" || mode == "rename")
		{
			bool local = info.find("localId\t") != std::string::npos;
			void* refs = BfParser_CreateResolvePassData(local ? parsers.at(target) : nullptr, 7, false);
			bool found = false;
			int localId = -1;
			for (const auto& line : Split(info, '\n'))
			{
				auto f = Split(line, '\t');
				if (f.size() < 2) continue;
				if (f[0] == "localId") { localId = std::stoi(f[1]); found = true; }
				if (f[0] == "namespaceRef") { BfResolvePassData_SetSymbolReferenceNamespace(refs, f[1].c_str()); found = true; }
				if (f[0] == "typeRef" || f[0] == "fieldRef" || f[0] == "methodRef" || f[0] == "propertyRef")
				{
					BfResolvePassData_SetSymbolReferenceTypeDef(refs, f[1].c_str()); found = true;
					if (f[0] == "fieldRef") BfResolvePassData_SetSymbolReferenceFieldIdx(refs, std::stoi(f.at(2)));
					if (f[0] == "methodRef") BfResolvePassData_SetSymbolReferenceMethodIdx(refs, std::stoi(f.at(2)));
					if (f[0] == "propertyRef") BfResolvePassData_SetSymbolReferencePropertyIdx(refs, std::stoi(f.at(2)));
				}
				if (f[0] == "typeGenericParam") BfResolvePassData_SetTypeGenericParamIdx(refs, std::stoi(f[1]));
				if (f[0] == "methodGenericParam") BfResolvePassData_SetMethodGenericParamIdx(refs, std::stoi(f[1]));
			}
			if (localId >= 0) BfResolvePassData_SetLocalId(refs, localId);
			if (!found) throw std::runtime_error("No renameable symbol at the cursor");
			std::ofstream(output + ".references") << BfCompiler_GetSymbolReferences(compiler, pass, refs);
			BfResolvePassData_Delete(refs);
		}
		BfResolvePassData_Delete(resolve);
		BfPassInstance_Delete(pass);
		BfSystem_DeleteParser(system, parser);
		BfSystem_RemoveOldData(system);
		return 0;
	}
	catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}

int main(int argc, char** argv)
{
	LoadCompiler();
	Workspace workspace;
	if (argc == 2 && std::string(argv[1]) == "--serve")
	{
		std::string command;
		while (std::getline(std::cin, command))
		{
			int result = Query(workspace, Split(command, '\t'));
			std::cout << "TALLOW_RESULT\t" << result << std::endl;
			if (result == 2) break;
		}
		return 0;
	}
	if (argc != 6) return 2;
	return Query(workspace, std::vector<std::string>(argv + 1, argv + argc));
}
