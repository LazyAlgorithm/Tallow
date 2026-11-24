// Android start-up for the Tallow player (libmain.so).
//
// SDL's Java activity (org.tallowengine.player.TallowActivity, an SDLActivity) loads libmain.so and calls SDL_main on
// a thread of its own. Before the Beef player's Main (compiled as BeefMain) runs, this:
//  - sends stdout and stderr to logcat (tag "Tallow"), since an app has no console;
//  - unpacks the game's files from the APK's assets into the app's internal storage (files/game), once per build:
//    the engine reads files from a folder, and APK assets are not files. assets/tallow-files.txt lists them, its
//    first line naming the build, so an updated app unpacks again;
//  - names the app's native library folder in TALLOW_ANDROID_LIBRARIES: Android runs code only from there, so the
//    game's NativeAOT library (libTallowGame.so) is in the APK's lib/<abi>, not with the other files;
//  - starts the player with --game <that folder>.
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <SDL3/SDL_system.h>

#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <android/log.h>
#include <jni.h>

#include <dirent.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern int BeefMain(int argc, char** argv);

#define TAG "Tallow"

static int sLogPipe[2];

static void* PumpLog(void* unused)
{
	(void)unused;
	char buffer[2048];
	size_t used = 0;
	for (;;)
	{
		ssize_t got = read(sLogPipe[0], buffer + used, sizeof(buffer) - 1 - used);
		if (got <= 0)
			break;
		used += (size_t)got;
		// Whole lines to logcat; a line longer than the buffer goes out in pieces.
		size_t start = 0;
		for (size_t i = 0; i < used; i++)
		{
			if (buffer[i] == '\n')
			{
				buffer[i] = 0;
				__android_log_write(ANDROID_LOG_INFO, TAG, buffer + start);
				start = i + 1;
			}
		}
		if (start == 0 && used == sizeof(buffer) - 1)
		{
			buffer[used] = 0;
			__android_log_write(ANDROID_LOG_INFO, TAG, buffer);
			used = 0;
		}
		else if (start > 0)
		{
			memmove(buffer, buffer + start, used - start);
			used -= start;
		}
	}
	return NULL;
}

static void LogToLogcat(void)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);
	if (pipe(sLogPipe) != 0)
		return;
	dup2(sLogPipe[1], STDOUT_FILENO);
	dup2(sLogPipe[1], STDERR_FILENO);
	pthread_t thread;
	if (pthread_create(&thread, NULL, PumpLog, NULL) == 0)
		pthread_detach(thread);
}

static void MakeFolders(char* path)
{
	for (char* at = path + 1; *at; at++)
	{
		if (*at == '/')
		{
			*at = 0;
			mkdir(path, 0700);
			*at = '/';
		}
	}
}

static void RemoveTree(const char* path)
{
	DIR* folder = opendir(path);
	if (folder == NULL)
	{
		unlink(path);
		return;
	}
	struct dirent* entry;
	while ((entry = readdir(folder)) != NULL)
	{
		if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
			continue;
		char child[4096];
		snprintf(child, sizeof(child), "%s/%s", path, entry->d_name);
		struct stat info;
		if (lstat(child, &info) == 0 && S_ISDIR(info.st_mode))
			RemoveTree(child);
		else
			unlink(child);
	}
	closedir(folder);
	rmdir(path);
}

static char* ReadAsset(AAssetManager* assets, const char* name, size_t* outSize)
{
	AAsset* asset = AAssetManager_open(assets, name, AASSET_MODE_BUFFER);
	if (asset == NULL)
		return NULL;
	size_t size = (size_t)AAsset_getLength64(asset);
	char* data = (char*)malloc(size + 1);
	if (data != NULL)
	{
		if (AAsset_read(asset, data, size) != (int)size)
		{
			free(data);
			data = NULL;
		}
		else
			data[size] = 0;
	}
	AAsset_close(asset);
	if (outSize != NULL)
		*outSize = size;
	return data;
}

static int CopyAsset(AAssetManager* assets, const char* name, const char* destination)
{
	AAsset* asset = AAssetManager_open(assets, name, AASSET_MODE_STREAMING);
	if (asset == NULL)
		return 0;
	char path[4096];
	snprintf(path, sizeof(path), "%s", destination);
	MakeFolders(path);
	FILE* file = fopen(destination, "wb");
	int ok = file != NULL;
	char buffer[65536];
	int got;
	while (ok && (got = AAsset_read(asset, buffer, sizeof(buffer))) > 0)
		ok = fwrite(buffer, 1, (size_t)got, file) == (size_t)got;
	if (file != NULL && fclose(file) != 0)
		ok = 0;
	AAsset_close(asset);
	return ok;
}

// The game's files, unpacked into <internal storage>/game unless that already holds this build.
static int UnpackGame(AAssetManager* assets, const char* folder)
{
	char* list = ReadAsset(assets, "tallow-files.txt", NULL);
	if (list == NULL)
	{
		__android_log_write(ANDROID_LOG_ERROR, TAG, "This app has no assets/tallow-files.txt: it was not built by Tallow.Build export.");
		return 0;
	}
	char* firstEnd = strchr(list, '\n');
	if (firstEnd != NULL)
		*firstEnd = 0;
	const char* build = list;

	char stampPath[4096];
	snprintf(stampPath, sizeof(stampPath), "%s/.tallow-build", folder);
	size_t stampSize = 0;
	FILE* stamp = fopen(stampPath, "rb");
	char current[256] = { 0 };
	if (stamp != NULL)
	{
		stampSize = fread(current, 1, sizeof(current) - 1, stamp);
		fclose(stamp);
		current[stampSize] = 0;
	}
	if (stamp != NULL && strcmp(current, build) == 0)
	{
		free(list);
		return 1;
	}

	__android_log_print(ANDROID_LOG_INFO, TAG, "Unpacking the game (build %s) into %s", build, folder);
	RemoveTree(folder);
	mkdir(folder, 0700);
	int ok = 1;
	char* line = firstEnd != NULL ? firstEnd + 1 : NULL;
	while (ok && line != NULL && *line)
	{
		char* end = strchr(line, '\n');
		if (end != NULL)
			*end = 0;
		size_t length = strlen(line);
		if (length > 0 && line[length - 1] == '\r')
			line[length - 1] = 0;
		if (*line)
		{
			char asset[4096], destination[4096];
			snprintf(asset, sizeof(asset), "game/%s", line);
			snprintf(destination, sizeof(destination), "%s/%s", folder, line);
			ok = CopyAsset(assets, asset, destination);
			if (!ok)
				__android_log_print(ANDROID_LOG_ERROR, TAG, "Could not unpack %s", asset);
		}
		line = end != NULL ? end + 1 : NULL;
	}
	if (ok)
	{
		stamp = fopen(stampPath, "wb");
		if (stamp != NULL)
		{
			fputs(build, stamp);
			fclose(stamp);
		}
	}
	free(list);
	return ok;
}

// The activity's AssetManager and ApplicationInfo.nativeLibraryDir, through JNI.
static AAssetManager* FindAssets(char* libraries, size_t librariesSize)
{
	JNIEnv* env = (JNIEnv*)SDL_GetAndroidJNIEnv();
	jobject activity = (jobject)SDL_GetAndroidActivity();
	if (env == NULL || activity == NULL)
		return NULL;
	jclass activityClass = (*env)->GetObjectClass(env, activity);
	jmethodID getAssets = (*env)->GetMethodID(env, activityClass, "getAssets", "()Landroid/content/res/AssetManager;");
	jobject javaAssets = (*env)->CallObjectMethod(env, activity, getAssets);
	// Kept: the AAssetManager is valid while its Java object is.
	jobject keptAssets = (*env)->NewGlobalRef(env, javaAssets);
	AAssetManager* assets = AAssetManager_fromJava(env, keptAssets);

	jmethodID getInfo = (*env)->GetMethodID(env, activityClass, "getApplicationInfo", "()Landroid/content/pm/ApplicationInfo;");
	jobject info = (*env)->CallObjectMethod(env, activity, getInfo);
	jclass infoClass = (*env)->GetObjectClass(env, info);
	jfieldID field = (*env)->GetFieldID(env, infoClass, "nativeLibraryDir", "Ljava/lang/String;");
	jstring dir = (jstring)(*env)->GetObjectField(env, info, field);
	const char* text = (*env)->GetStringUTFChars(env, dir, NULL);
	snprintf(libraries, librariesSize, "%s", text);
	(*env)->ReleaseStringUTFChars(env, dir, text);

	(*env)->DeleteLocalRef(env, dir);
	(*env)->DeleteLocalRef(env, infoClass);
	(*env)->DeleteLocalRef(env, info);
	(*env)->DeleteLocalRef(env, javaAssets);
	(*env)->DeleteLocalRef(env, activityClass);
	(*env)->DeleteLocalRef(env, activity);
	return assets;
}

int SDL_main(int argc, char* argv[])
{
	(void)argc;
	LogToLogcat();

	char libraries[4096] = { 0 };
	AAssetManager* assets = FindAssets(libraries, sizeof(libraries));
	const char* storage = SDL_GetAndroidInternalStoragePath();
	if (assets == NULL || storage == NULL)
	{
		__android_log_write(ANDROID_LOG_ERROR, TAG, "Could not reach the app's assets or storage.");
		return 1;
	}
	setenv("TALLOW_ANDROID_LIBRARIES", libraries, 1);

	char folder[4096];
	snprintf(folder, sizeof(folder), "%s/game", storage);
	if (!UnpackGame(assets, folder))
	{
		SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "Tallow", "The game's files could not be unpacked (is the device full?).", NULL);
		return 1;
	}

	char* args[] = { argv != NULL && argv[0] != NULL ? argv[0] : (char*)"app_process", (char*)"--game", folder, NULL };
	return BeefMain(3, args);
}
