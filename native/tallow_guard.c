// What the anti-cheat asks the operating system: is a debugger attached, has a library been forced into the
// process, and do two independent clocks agree (a "speed hack" stretches the one games read). User-mode checks:
// they catch the common tools and nothing that runs in the kernel. See docs/anti-cheat.md.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define TN_GUARD_DEBUGGER 1u
#define TN_GUARD_INJECTED 2u

#ifdef _WIN32
#include <windows.h>

unsigned tn_guard_environment(void)
{
	unsigned flags = 0;
	BOOL remote = FALSE;
	if (IsDebuggerPresent()) flags |= TN_GUARD_DEBUGGER;
	if (CheckRemoteDebuggerPresent(GetCurrentProcess(), &remote) && remote) flags |= TN_GUARD_DEBUGGER;
	return flags;
}

#include <tlhelp32.h>
#include <aclapi.h>
#include <ctype.h>

// Closes the game's memory to other programs run by the same user: opening the process to read, write or start
// threads in it is denied. A program running as administrator can still take the right; nothing in user mode
// stops that.
static PSECURITY_DESCRIPTOR originalProcessSecurity;
static PACL originalProcessDacl;

int tn_guard_harden(void)
{
	EXPLICIT_ACCESSA deny;
	PACL acl = NULL;
	SID_IDENTIFIER_AUTHORITY world = SECURITY_WORLD_SID_AUTHORITY;
	PSID everyone = NULL;
	int done = 0;
	// Keep the original allow entries. A deny-only DACL implicitly denies even
	// query/synchronization access, which Steam and other runtime services need.
	// Reuse the baseline on maintenance ticks so deny entries never accumulate.
	if (originalProcessSecurity == NULL)
	{
		if (GetSecurityInfo(GetCurrentProcess(), SE_KERNEL_OBJECT, DACL_SECURITY_INFORMATION,
			NULL, NULL, &originalProcessDacl, NULL, &originalProcessSecurity) != ERROR_SUCCESS)
			return 0;
		// A null DACL grants everyone access; it cannot be merged safely with a
		// deny entry without changing the permissions of all other operations.
		if (originalProcessDacl == NULL)
		{
			LocalFree(originalProcessSecurity);
			originalProcessSecurity = NULL;
			return 0;
		}
	}
	if (!AllocateAndInitializeSid(&world, 1, SECURITY_WORLD_RID, 0, 0, 0, 0, 0, 0, 0, &everyone)) return 0;
	memset(&deny, 0, sizeof(deny));
	deny.grfAccessPermissions = PROCESS_VM_READ | PROCESS_VM_WRITE | PROCESS_VM_OPERATION | PROCESS_CREATE_THREAD | PROCESS_DUP_HANDLE | PROCESS_SUSPEND_RESUME;
	deny.grfAccessMode = DENY_ACCESS;
	deny.grfInheritance = NO_INHERITANCE;
	deny.Trustee.TrusteeForm = TRUSTEE_IS_SID;
	deny.Trustee.TrusteeType = TRUSTEE_IS_WELL_KNOWN_GROUP;
	deny.Trustee.ptstrName = (LPSTR)everyone;
	if (SetEntriesInAclA(1, &deny, originalProcessDacl, &acl) == ERROR_SUCCESS)
	{
		done = SetSecurityInfo(GetCurrentProcess(), SE_KERNEL_OBJECT, DACL_SECURITY_INFORMATION, NULL, NULL, acl, NULL) == ERROR_SUCCESS;
		LocalFree(acl);
	}
	FreeSid(everyone);
	return done;
}

void tn_guard_release(void)
{
	if (originalProcessSecurity == NULL) return;
	if (SetSecurityInfo(GetCurrentProcess(), SE_KERNEL_OBJECT, DACL_SECURITY_INFORMATION,
		NULL, NULL, originalProcessDacl, NULL) != ERROR_SUCCESS) return;
	LocalFree(originalProcessSecurity);
	originalProcessSecurity = NULL;
	originalProcessDacl = NULL;
}

static char baseFolder[MAX_PATH];
static char windowsFolder[MAX_PATH];

static void lower(char* text) { for (; *text; text++) *text = (char)tolower((unsigned char)*text); }

// Libraries that load into games for honest reasons after they have started: overlays, recorders, drivers.
static int harmless_module(const char* path)
{
	static const char* known[] = { "steam", "gameoverlay", "discord", "obs", "nvidia", "nvapi", "amd", "atio", "igd", "intel", "overlay", "rtss", "msi", "vulkan", "openxr", "wine", "easyanticheat", "battleye" };
	if (windowsFolder[0] != 0 && strncmp(path, windowsFolder, strlen(windowsFolder)) == 0) return 1;
	if (baseFolder[0] != 0 && strncmp(path, baseFolder, strlen(baseFolder)) == 0) return 1;
	for (size_t k = 0; k < sizeof(known) / sizeof(known[0]); k++)
	{
		if (strstr(path, known[k]) != NULL) return 1;
	}
	return 0;
}

typedef void (*TnModuleVisitor)(const char* path, void* context);

static void each_module(TnModuleVisitor visit, void* context)
{
	HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, GetCurrentProcessId());
	MODULEENTRY32 entry;
	if (snapshot == INVALID_HANDLE_VALUE) return;
	entry.dwSize = sizeof(entry);
	if (Module32First(snapshot, &entry))
	{
		do
		{
			char path[MAX_PATH];
			strncpy(path, entry.szExePath, MAX_PATH - 1);
			path[MAX_PATH - 1] = 0;
			lower(path);
			visit(path, context);
		} while (Module32Next(snapshot, &entry));
	}
	CloseHandle(snapshot);
}

static void prepare_folders(void)
{
	char* slash;
	if (baseFolder[0] != 0) return;
	GetModuleFileNameA(NULL, baseFolder, MAX_PATH);
	slash = strrchr(baseFolder, '\\');
	if (slash != NULL) slash[1] = 0;
	lower(baseFolder);
	GetWindowsDirectoryA(windowsFolder, MAX_PATH);
	lower(windowsFolder);
}

// The game's own code, as loaded: the executable section of the program's image.
static int code_range(const unsigned char** start, size_t* size)
{
	unsigned char* base = (unsigned char*)GetModuleHandleA(NULL);
	IMAGE_DOS_HEADER* dos = (IMAGE_DOS_HEADER*)base;
	IMAGE_NT_HEADERS* nt;
	IMAGE_SECTION_HEADER* section;
	if (base == NULL || dos->e_magic != IMAGE_DOS_SIGNATURE) return 0;
	nt = (IMAGE_NT_HEADERS*)(base + dos->e_lfanew);
	section = IMAGE_FIRST_SECTION(nt);
	for (int i = 0; i < nt->FileHeader.NumberOfSections; i++, section++)
	{
		if ((section->Characteristics & IMAGE_SCN_MEM_EXECUTE) != 0 && (section->Characteristics & IMAGE_SCN_MEM_WRITE) == 0)
		{
			*start = base + section->VirtualAddress;
			*size = section->Misc.VirtualSize;
			return 1;
		}
	}
	return 0;
}

static int make_writable(void* address, size_t size, int writable)
{
	DWORD old;
	return VirtualProtect(address, size, writable ? PAGE_EXECUTE_READWRITE : PAGE_EXECUTE_READ, &old) != 0;
}

// The clock the engine runs on (the performance counter) and one that speed hacks rarely reach (the system time).
void tn_guard_clocks(double* engine, double* independent)
{
	LARGE_INTEGER counter, frequency;
	FILETIME now;
	ULARGE_INTEGER wide;
	QueryPerformanceCounter(&counter);
	QueryPerformanceFrequency(&frequency);
	*engine = (double)counter.QuadPart / (double)frequency.QuadPart;
	GetSystemTimePreciseAsFileTime(&now);
	wide.LowPart = now.dwLowDateTime;
	wide.HighPart = now.dwHighDateTime;
	*independent = (double)wide.QuadPart / 10000000.0;
}

#else
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif
#ifdef __APPLE__
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <sys/sysctl.h>
#endif

// Closes the game's memory to other programs run by the same user: they can no longer attach to it or open its
// memory (memory editors and debuggers both work that way). A program run as root still can.
int tn_guard_harden(void)
{
#ifdef __linux__
	return prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) == 0;
#else
	return 0;
#endif
}

// Opens the process up again, for shutting down: libraries that are closing (graphics drivers among them) look
// at the process through the system, and wait for ever if they are refused.
void tn_guard_release(void)
{
#ifdef __linux__
	prctl(PR_SET_DUMPABLE, 1, 0, 0, 0);
#endif
}

static char baseFolder[1024];

static void prepare_folders(void)
{
	if (baseFolder[0] != 0) return;
#ifdef __APPLE__
	uint32_t capacity = sizeof(baseFolder);
	if (_NSGetExecutablePath(baseFolder, &capacity) != 0) { baseFolder[0] = '?'; baseFolder[1] = 0; return; }
#else
	ssize_t length = readlink("/proc/self/exe", baseFolder, sizeof(baseFolder) - 1);
	if (length <= 0) { baseFolder[0] = '?'; baseFolder[1] = 0; return; }
	baseFolder[length] = 0;
#endif
	char* slash = strrchr(baseFolder, '/');
	if (slash != NULL) slash[1] = 0;
}

// Where libraries live that the system, its drivers and honest tools load, also after the game has started.
static int harmless_module(const char* path)
{
	static const char* places[] = { "/usr/", "/lib", "/opt/", "/System/", "/Library/Apple/", "/nix/", "/run/host/", "/app/", "/snap/", "/var/lib/flatpak/", "/memfd:", "/dev/", "/SYSV", "/tmp/.gl", "/home/deck/.steam" };
	static const char* known[] = { "steam", "Steam", "MangoHud", "mangohud", "gamemode", "obs", "vkbasalt", "nvidia", "mesa", "pressure-vessel" };
	for (size_t k = 0; k < sizeof(places) / sizeof(places[0]); k++)
	{
		if (strncmp(path, places[k], strlen(places[k])) == 0) return 1;
	}
	if (baseFolder[0] != 0 && strncmp(path, baseFolder, strlen(baseFolder)) == 0) return 1;
	for (size_t k = 0; k < sizeof(known) / sizeof(known[0]); k++)
	{
		if (strstr(path, known[k]) != NULL) return 1;
	}
	return 0;
}

typedef void (*TnModuleVisitor)(const char* path, void* context);

// Every file mapped into the process as code.
static void each_module(TnModuleVisitor visit, void* context)
{
#ifdef __APPLE__
	// The libraries dyld loaded (the system's come from its shared cache under /usr/lib and /System).
	for (uint32_t i = 0; i < _dyld_image_count(); i++)
	{
		const char* path = _dyld_get_image_name(i);
		if (path != NULL && path[0] == '/') visit(path, context);
	}
#else
	FILE* maps = fopen("/proc/self/maps", "r");
	char line[1400];
	if (maps == NULL) return;
	while (fgets(line, sizeof(line), maps) != NULL)
	{
		char permissions[8] = "";
		int offset = 0;
		if (sscanf(line, "%*s %7s %*s %*s %*s %n", permissions, &offset) < 1 || offset <= 0) continue;
		if (permissions[2] != 'x' || line[offset] != '/') continue;
		char* path = line + offset;
		path[strcspn(path, "\n")] = 0;
		visit(path, context);
	}
	fclose(maps);
#endif
}

// The game's own code, as loaded: the executable mapping of the program's file.
static int code_range(const unsigned char** start, size_t* size)
{
#ifdef __APPLE__
	// Image 0 is the program; its __TEXT,__text section is its code as loaded (slid).
	unsigned long length = 0;
	const unsigned char* text = getsectiondata((const struct mach_header_64*)_dyld_get_image_header(0), "__TEXT", "__text", &length);
	if (text == NULL || length == 0) return 0;
	*start = text;
	*size = (size_t)length;
	return 1;
#else
	char exe[1024];
	ssize_t length = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
	FILE* maps = fopen("/proc/self/maps", "r");
	char line[1400];
	int found = 0;
	if (maps == NULL || length <= 0) { if (maps != NULL) fclose(maps); return 0; }
	exe[length] = 0;
	while (!found && fgets(line, sizeof(line), maps) != NULL)
	{
		unsigned long from = 0, to = 0;
		char permissions[8] = "";
		int offset = 0;
		if (sscanf(line, "%lx-%lx %7s %*s %*s %*s %n", &from, &to, permissions, &offset) < 3 || offset <= 0) continue;
		line[strcspn(line, "\n")] = 0;
		if (permissions[2] == 'x' && strcmp(line + offset, exe) == 0)
		{
			*start = (const unsigned char*)from;
			*size = (size_t)(to - from);
			found = 1;
		}
	}
	fclose(maps);
	return found;
#endif
}

static int make_writable(void* address, size_t size, int writable)
{
	long page = sysconf(_SC_PAGESIZE);
	uintptr_t from = (uintptr_t)address & ~(uintptr_t)(page - 1);
	uintptr_t to = ((uintptr_t)address + size + (uintptr_t)page - 1) & ~(uintptr_t)(page - 1);
	return mprotect((void*)from, to - from, PROT_READ | PROT_EXEC | (writable ? PROT_WRITE : 0)) == 0;
}

// Libraries that are preloaded into games for honest reasons: overlays, recorders, performance tools.
static int harmless(const char* name, size_t length)
{
	static const char* known[] = { "gameoverlayrenderer", "libgamemode", "MangoHud", "mangohud", "obs", "libstrangle", "libvkbasalt", "libSDL", "steam" };
	for (size_t k = 0; k < sizeof(known) / sizeof(known[0]); k++)
	{
		size_t wanted = strlen(known[k]);
		for (size_t i = 0; i + wanted <= length; i++)
		{
			if (memcmp(name + i, known[k], wanted) == 0) return 1;
		}
	}
	return 0;
}

unsigned tn_guard_environment(void)
{
	unsigned flags = 0;
#ifdef __linux__
	FILE* status = fopen("/proc/self/status", "r");
	if (status != NULL)
	{
		char line[256];
		while (fgets(line, sizeof(line), status) != NULL)
		{
			if (strncmp(line, "TracerPid:", 10) == 0 && atoi(line + 10) != 0) flags |= TN_GUARD_DEBUGGER;
		}
		fclose(status);
	}
#endif
#ifdef __APPLE__
	struct kinfo_proc info;
	size_t infoSize = sizeof(info);
	int query[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
	memset(&info, 0, sizeof(info));
	if (sysctl(query, 4, &info, &infoSize, NULL, 0) == 0 && (info.kp_proc.p_flag & P_TRACED) != 0) flags |= TN_GUARD_DEBUGGER;
#endif
	// A library forced in ahead of the system's: the usual way to hook a game on Linux and macOS.
	const char* names[] = { "LD_PRELOAD", "DYLD_INSERT_LIBRARIES" };
	for (int n = 0; n < 2; n++)
	{
		const char* preload = getenv(names[n]);
		while (preload != NULL && *preload != 0)
		{
			size_t length = strcspn(preload, ": ");
			if (length > 0 && !harmless(preload, length)) flags |= TN_GUARD_INJECTED;
			preload += length;
			while (*preload == ':' || *preload == ' ') preload++;
		}
	}
	return flags;
}

void tn_guard_clocks(double* engine, double* independent)
{
	struct timespec a, b;
	clock_gettime(CLOCK_MONOTONIC, &a);
#ifdef CLOCK_MONOTONIC_RAW
	clock_gettime(CLOCK_MONOTONIC_RAW, &b);
#else
	clock_gettime(CLOCK_REALTIME, &b);
#endif
	*engine = (double)a.tv_sec + (double)a.tv_nsec / 1e9;
	*independent = (double)b.tv_sec + (double)b.tv_nsec / 1e9;
}
#endif

// ---- the same on every system ----

// Libraries: the ones present when the watch began are the game's own company. One that turns up later from
// somewhere a system library or the game's own would not come from was put there by something else.
#define TN_GUARD_MAX_MODULES 2048
static uint32_t moduleHashes[TN_GUARD_MAX_MODULES];
static int moduleCount = 0;
static int modulesReady = 0;
static char foreignModule[512];

static uint32_t hash_text(const char* text)
{
	uint32_t hash = 2166136261u;
	for (; *text; text++) hash = (hash ^ (unsigned char)*text) * 16777619u;
	return hash;
}

static int known_module(uint32_t hash)
{
	for (int i = 0; i < moduleCount; i++)
	{
		if (moduleHashes[i] == hash) return 1;
	}
	return 0;
}

static void remember_module(const char* path, void* context)
{
	uint32_t hash = hash_text(path);
	(void)context;
	if (!known_module(hash) && moduleCount < TN_GUARD_MAX_MODULES) moduleHashes[moduleCount++] = hash;
}

static void judge_module(const char* path, void* context)
{
	uint32_t hash = hash_text(path);
	(void)context;
	if (known_module(hash)) return;
	if (moduleCount < TN_GUARD_MAX_MODULES) moduleHashes[moduleCount++] = hash;
	if (!harmless_module(path) && foreignModule[0] == 0)
	{
		strncpy(foreignModule, path, sizeof(foreignModule) - 1);
		foreignModule[sizeof(foreignModule) - 1] = 0;
	}
}

// Returns the path of a library that was loaded into the game since the last call from somewhere it should not
// have come from, or NULL. The first call only takes stock.
const char* tn_guard_new_module(void)
{
	prepare_folders();
	if (!modulesReady)
	{
		modulesReady = 1;
		each_module(remember_module, NULL);
		return NULL;
	}
	foreignModule[0] = 0;
	each_module(judge_module, NULL);
	return foreignModule[0] != 0 ? foreignModule : NULL;
}

// Code: a sum over the program's own instructions as they sit in memory. Hooks and patches written into them
// (and a debugger's breakpoints) change it.
static uint64_t codeSum = 0;
static int codeReady = 0;

static uint64_t sum_code(void)
{
	const unsigned char* start = NULL;
	size_t size = 0;
	uint64_t hash = 1469598103934665603ull;
	if (!code_range(&start, &size)) return 0;
	// Eight bytes at a stride: quick enough to repeat every few seconds over tens of megabytes.
	for (size_t i = 0; i + 8 <= size; i += 8)
	{
		uint64_t word;
		memcpy(&word, start + i, 8);
		hash = (hash ^ word) * 1099511628211ull;
	}
	return hash != 0 ? hash : 1;
}

// 1 if the program's code has changed since the first call, 0 if not (or if it cannot be looked at).
int tn_guard_code_changed(void)
{
	uint64_t now = sum_code();
	if (now == 0) return 0;
	if (!codeReady)
	{
		codeReady = 1;
		codeSum = now;
		return 0;
	}
	return now != codeSum;
}

// For tests: writes over one byte of the program's own code (in a function that is never run), as a patching tool
// would, or puts it back. Returns 0 if the system would not allow it.
static void never_run(void) { volatile int filler = 12345; (void)filler; }

int tn_guard_test_patch(int patch)
{
	static unsigned char saved;
	static int patched = 0;
	unsigned char* target = (unsigned char*)(uintptr_t)&never_run;
	const unsigned char* start = NULL;
	size_t size = 0;
	// Only inside what is watched (on some systems the function is reached through a jump table elsewhere).
	if (!code_range(&start, &size) || target < start || target >= start + size) return 0;
	target = (unsigned char*)start + (((size_t)(target - start)) & ~(size_t)7);
	if (patch == patched) return 1;
	if (!make_writable(target, 8, 1)) return 0;
	if (patch) { saved = *target; *target = (unsigned char)(saved ^ 0xFF); }
	else *target = saved;
	patched = patch;
	make_writable(target, 8, 0);
	return 1;
}
