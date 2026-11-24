// iOS start-up for the Tallow player. SDL_main.h turns this main into SDL_main and supplies the real main, which
// starts UIKit (SDL_RunApp) and calls this on its main thread once the app has launched. The game's files are in
// the app bundle itself (SDL_GetBasePath), so unlike Android nothing is unpacked; the game's NativeAOT C# is
// Frameworks/TallowGame.framework in the bundle. The Beef player's Main is compiled as BeefMain.
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>

extern int BeefMain(int argc, char** argv);

int main(int argc, char* argv[])
{
	const char* bundle = SDL_GetBasePath();
	char* args[] = { argc > 0 ? argv[0] : (char*)"TallowPlayer", (char*)"--game", (char*)(bundle != NULL ? bundle : "."), NULL };
	return BeefMain(3, args);
}
