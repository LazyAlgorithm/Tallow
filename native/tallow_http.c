// HTTP and HTTPS GET for tools such as a launcher or an updater, with nothing extra to install or link: WinHTTP on
// Windows and the system's libcurl elsewhere (libcurl ships with macOS and practically every Linux), both loaded
// the first time they are needed, so a program that never downloads anything does not depend on them at all.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Called as data arrives: bytes so far and the total (or -1 when the server does not say). Return nonzero to stop.
typedef int (*tn_http_progress)(void* user, int64_t done, int64_t total);

typedef struct {
    FILE* file;
    char* data;
    int64_t size;
    int64_t capacity;
    tn_http_progress progress;
    void* user;
    int cancelled;
} TnSink;

static int sinkWrite(TnSink* sink, const void* bytes, size_t count) {
    if (sink->file != NULL)
        return fwrite(bytes, 1, count, sink->file) == count;
    if (sink->size + (int64_t)count + 1 > sink->capacity) {
        int64_t capacity = sink->capacity < 65536 ? 65536 : sink->capacity;
        while (capacity < sink->size + (int64_t)count + 1) capacity *= 2;
        char* grown = (char*)realloc(sink->data, (size_t)capacity);
        if (grown == NULL) return 0;
        sink->data = grown;
        sink->capacity = capacity;
    }
    memcpy(sink->data + sink->size, bytes, count);
    sink->size += (int64_t)count;
    sink->data[sink->size] = 0;
    return 1;
}

static void setError(char* error, int errorSize, const char* text) {
    if (error != NULL && errorSize > 0) {
        strncpy(error, text, (size_t)errorSize - 1);
        error[errorSize - 1] = 0;
    }
}

#ifdef _WIN32
#include <windows.h>
#include <winhttp.h>

typedef HINTERNET (WINAPI *PFN_Open)(LPCWSTR, DWORD, LPCWSTR, LPCWSTR, DWORD);
typedef HINTERNET (WINAPI *PFN_Connect)(HINTERNET, LPCWSTR, INTERNET_PORT, DWORD);
typedef HINTERNET (WINAPI *PFN_OpenRequest)(HINTERNET, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR*, DWORD);
typedef BOOL (WINAPI *PFN_SendRequest)(HINTERNET, LPCWSTR, DWORD, LPVOID, DWORD, DWORD, DWORD_PTR);
typedef BOOL (WINAPI *PFN_ReceiveResponse)(HINTERNET, LPVOID);
typedef BOOL (WINAPI *PFN_QueryHeaders)(HINTERNET, DWORD, LPCWSTR, LPVOID, LPDWORD, LPDWORD);
typedef BOOL (WINAPI *PFN_ReadData)(HINTERNET, LPVOID, DWORD, LPDWORD);
typedef BOOL (WINAPI *PFN_CloseHandle)(HINTERNET);
typedef BOOL (WINAPI *PFN_CrackUrl)(LPCWSTR, DWORD, DWORD, LPURL_COMPONENTS);
typedef BOOL (WINAPI *PFN_SetOption)(HINTERNET, DWORD, LPVOID, DWORD);

static struct {
    int loaded;
    PFN_Open open; PFN_Connect connect; PFN_OpenRequest openRequest; PFN_SendRequest sendRequest;
    PFN_ReceiveResponse receiveResponse; PFN_QueryHeaders queryHeaders; PFN_ReadData readData;
    PFN_CloseHandle closeHandle; PFN_CrackUrl crackUrl; PFN_SetOption setOption;
} gWin;

static int loadWinHttp(void) {
    if (gWin.loaded) return gWin.loaded > 0;
    HMODULE module = LoadLibraryA("winhttp.dll");
    gWin.loaded = -1;
    if (module == NULL) return 0;
    gWin.open = (PFN_Open)GetProcAddress(module, "WinHttpOpen");
    gWin.connect = (PFN_Connect)GetProcAddress(module, "WinHttpConnect");
    gWin.openRequest = (PFN_OpenRequest)GetProcAddress(module, "WinHttpOpenRequest");
    gWin.sendRequest = (PFN_SendRequest)GetProcAddress(module, "WinHttpSendRequest");
    gWin.receiveResponse = (PFN_ReceiveResponse)GetProcAddress(module, "WinHttpReceiveResponse");
    gWin.queryHeaders = (PFN_QueryHeaders)GetProcAddress(module, "WinHttpQueryHeaders");
    gWin.readData = (PFN_ReadData)GetProcAddress(module, "WinHttpReadData");
    gWin.closeHandle = (PFN_CloseHandle)GetProcAddress(module, "WinHttpCloseHandle");
    gWin.crackUrl = (PFN_CrackUrl)GetProcAddress(module, "WinHttpCrackUrl");
    gWin.setOption = (PFN_SetOption)GetProcAddress(module, "WinHttpSetOption");
    if (!gWin.open || !gWin.connect || !gWin.openRequest || !gWin.sendRequest || !gWin.receiveResponse ||
        !gWin.queryHeaders || !gWin.readData || !gWin.closeHandle || !gWin.crackUrl)
        return 0;
    gWin.loaded = 1;
    return 1;
}

static int requestWin(const char* url, const char* userAgent, TnSink* sink, int* status, char* error, int errorSize) {
    if (!loadWinHttp()) { setError(error, errorSize, "WinHTTP is not available"); return 0; }
    wchar_t wideUrl[4096], wideAgent[256];
    MultiByteToWideChar(CP_UTF8, 0, url, -1, wideUrl, 4096);
    MultiByteToWideChar(CP_UTF8, 0, userAgent, -1, wideAgent, 256);
    URL_COMPONENTS parts;
    memset(&parts, 0, sizeof(parts));
    parts.dwStructSize = sizeof(parts);
    wchar_t host[512], path[3584];
    parts.lpszHostName = host; parts.dwHostNameLength = 512;
    parts.lpszUrlPath = path; parts.dwUrlPathLength = 3584;
    wchar_t extra[2048]; parts.lpszExtraInfo = extra; parts.dwExtraInfoLength = 2048;
    if (!gWin.crackUrl(wideUrl, 0, 0, &parts)) { setError(error, errorSize, "Not a valid address"); return 0; }
    if (parts.dwExtraInfoLength > 0) wcsncat(path, extra, 3583 - wcslen(path));
    int ok = 0;
    HINTERNET session = gWin.open(wideAgent, 4 /* WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY */, NULL, NULL, 0);
    if (session == NULL) session = gWin.open(wideAgent, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, NULL, NULL, 0);
    if (session == NULL) { setError(error, errorSize, "Could not start WinHTTP"); return 0; }
    if (gWin.setOption) {
        DWORD protocols = 0x00000800 | 0x00002000; // TLS 1.2 and 1.3
        gWin.setOption(session, 84 /* WINHTTP_OPTION_SECURE_PROTOCOLS */, &protocols, sizeof(protocols));
    }
    HINTERNET connection = gWin.connect(session, host, parts.nPort, 0);
    HINTERNET request = connection ? gWin.openRequest(connection, L"GET", path, NULL, NULL, NULL,
        parts.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0) : NULL;
    if (request == NULL) { setError(error, errorSize, "Could not reach the server"); goto done; }
    if (!gWin.sendRequest(request, NULL, 0, NULL, 0, 0, 0) || !gWin.receiveResponse(request, NULL)) {
        setError(error, errorSize, "The server did not answer");
        goto done;
    }
    DWORD code = 0, size = sizeof(code);
    gWin.queryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, NULL, &code, &size, NULL);
    *status = (int)code;
    wchar_t lengthText[32]; DWORD lengthSize = sizeof(lengthText);
    int64_t total = -1;
    if (gWin.queryHeaders(request, WINHTTP_QUERY_CONTENT_LENGTH, NULL, lengthText, &lengthSize, NULL))
        total = _wtoi64(lengthText);
    char buffer[65536];
    for (;;) {
        DWORD read = 0;
        if (!gWin.readData(request, buffer, sizeof(buffer), &read)) { setError(error, errorSize, "The download was interrupted"); goto done; }
        if (read == 0) break;
        if (!sinkWrite(sink, buffer, read)) { setError(error, errorSize, "Could not write what was downloaded"); goto done; }
        if (sink->progress != NULL && sink->progress(sink->user, sink->size > 0 ? sink->size : 0, total) != 0) {
            sink->cancelled = 1;
            setError(error, errorSize, "Cancelled");
            goto done;
        }
    }
    ok = 1;
done:
    if (request) gWin.closeHandle(request);
    if (connection) gWin.closeHandle(connection);
    gWin.closeHandle(session);
    return ok;
}
#else
#include <dlfcn.h>

typedef void* (*PFN_curl_easy_init)(void);
typedef int (*PFN_curl_easy_setopt)(void*, int, ...);
typedef int (*PFN_curl_easy_perform)(void*);
typedef int (*PFN_curl_easy_getinfo)(void*, int, ...);
typedef void (*PFN_curl_easy_cleanup)(void*);

static struct {
    int loaded;
    PFN_curl_easy_init init; PFN_curl_easy_setopt setopt; PFN_curl_easy_perform perform;
    PFN_curl_easy_getinfo getinfo; PFN_curl_easy_cleanup cleanup;
} gCurl;

static int loadCurl(void) {
    if (gCurl.loaded) return gCurl.loaded > 0;
    gCurl.loaded = -1;
    const char* names[] = {"libcurl.so.4", "libcurl.so", "libcurl-gnutls.so.4", "libcurl.4.dylib", "/usr/lib/libcurl.4.dylib", "libcurl.dylib"};
    void* library = NULL;
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]) && library == NULL; i++)
        library = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) return 0;
    gCurl.init = (PFN_curl_easy_init)dlsym(library, "curl_easy_init");
    gCurl.setopt = (PFN_curl_easy_setopt)dlsym(library, "curl_easy_setopt");
    gCurl.perform = (PFN_curl_easy_perform)dlsym(library, "curl_easy_perform");
    gCurl.getinfo = (PFN_curl_easy_getinfo)dlsym(library, "curl_easy_getinfo");
    gCurl.cleanup = (PFN_curl_easy_cleanup)dlsym(library, "curl_easy_cleanup");
    if (!gCurl.init || !gCurl.setopt || !gCurl.perform || !gCurl.getinfo || !gCurl.cleanup) return 0;
    gCurl.loaded = 1;
    return 1;
}

static size_t curlWrite(char* bytes, size_t size, size_t count, void* user) {
    TnSink* sink = (TnSink*)user;
    return sinkWrite(sink, bytes, size * count) ? size * count : 0;
}

static int curlProgress(void* user, int64_t total, int64_t done, int64_t upTotal, int64_t upDone) {
    (void)upTotal; (void)upDone;
    TnSink* sink = (TnSink*)user;
    if (sink->progress != NULL && sink->progress(sink->user, done, total > 0 ? total : -1) != 0) {
        sink->cancelled = 1;
        return 1;
    }
    return 0;
}

static int requestCurl(const char* url, const char* userAgent, TnSink* sink, int* status, char* error, int errorSize) {
    if (!loadCurl()) { setError(error, errorSize, "libcurl was not found on this system"); return 0; }
    void* curl = gCurl.init();
    if (curl == NULL) { setError(error, errorSize, "Could not start libcurl"); return 0; }
    char message[256] = {0};
    gCurl.setopt(curl, 10002 /* URL */, url);
    gCurl.setopt(curl, 10018 /* USERAGENT */, userAgent);
    gCurl.setopt(curl, 52 /* FOLLOWLOCATION */, 1L);
    gCurl.setopt(curl, 20011 /* WRITEFUNCTION */, curlWrite);
    gCurl.setopt(curl, 10001 /* WRITEDATA */, sink);
    gCurl.setopt(curl, 43 /* NOPROGRESS */, 0L);
    gCurl.setopt(curl, 20219 /* XFERINFOFUNCTION */, curlProgress);
    gCurl.setopt(curl, 10057 /* XFERINFODATA */, sink);
    gCurl.setopt(curl, 10010 /* ERRORBUFFER */, message);
    gCurl.setopt(curl, 78 /* CONNECTTIMEOUT */, 30L);
    gCurl.setopt(curl, 19 /* LOW_SPEED_LIMIT */, 1L);
    gCurl.setopt(curl, 20 /* LOW_SPEED_TIME */, 60L);
    const int result = gCurl.perform(curl);
    long code = 0;
    gCurl.getinfo(curl, 0x200002 /* RESPONSE_CODE */, &code);
    *status = (int)code;
    gCurl.cleanup(curl);
    if (result != 0) {
        setError(error, errorSize, sink->cancelled ? "Cancelled" : (message[0] ? message : "The download failed"));
        return 0;
    }
    return 1;
}
#endif

// Downloads url. With path, the body goes to that file (written to path + ".part" first and renamed when complete);
// otherwise into *outData (free it with tn_http_free), *outSize bytes, followed by a zero byte. Redirects are
// followed. Returns 1 on a 2xx answer; *status is the HTTP status (0 if there was none) and error says why not.
int tn_http_get(const char* url, const char* userAgent, const char* path, char** outData, int64_t* outSize,
    tn_http_progress progress, void* user, int* status, char* error, int errorSize) {
    TnSink sink;
    memset(&sink, 0, sizeof(sink));
    sink.progress = progress;
    sink.user = user;
    *status = 0;
    if (outData) *outData = NULL;
    if (outSize) *outSize = 0;
    setError(error, errorSize, "");
    char partial[4096];
    if (path != NULL) {
        snprintf(partial, sizeof(partial), "%s.part", path);
        sink.file = fopen(partial, "wb");
        if (sink.file == NULL) { setError(error, errorSize, "Could not create the file to download into"); return 0; }
    }
#ifdef _WIN32
    int ok = requestWin(url, userAgent ? userAgent : "Tallow", &sink, status, error, errorSize);
#else
    int ok = requestCurl(url, userAgent ? userAgent : "Tallow", &sink, status, error, errorSize);
#endif
    if (ok && (*status < 200 || *status >= 300)) {
        char text[64];
        snprintf(text, sizeof(text), "The server answered %d", *status);
        setError(error, errorSize, text);
        ok = 0;
    }
    if (sink.file != NULL) {
        fclose(sink.file);
        if (ok) {
            remove(path);
            if (rename(partial, path) != 0) { setError(error, errorSize, "Could not move the downloaded file into place"); ok = 0; }
        } else
            remove(partial);
    } else if (ok) {
        if (sink.data == NULL) { sink.data = (char*)malloc(1); if (sink.data) sink.data[0] = 0; }
        *outData = sink.data;
        *outSize = sink.size;
        sink.data = NULL;
    }
    free(sink.data);
    return ok;
}

void tn_http_free(char* data) { free(data); }

// Inflates deflate data (raw, as in a zip file, or with a zlib header). Returns a buffer to free with
// tn_http_free, or null if the data is damaged.
extern char* stbi_zlib_decode_malloc_guesssize_headerflag(const char* buffer, int len, int initial_size, int* outlen, int parse_header);

char* tn_inflate(const char* data, int length, int expectedSize, int zlibHeader, int* outLength) {
    return stbi_zlib_decode_malloc_guesssize_headerflag(data, length, expectedSize > 0 ? expectedSize : length * 4, outLength, zlibHeader);
}
