package org.tallowengine.player;

import org.libsdl.app.SDLActivity;

/**
 * The activity of every Tallow game on Android. SDL is linked into libmain.so (the engine and player), so that is
 * the only library to load; its SDL_main (native/android/tallow_android_main.c) unpacks the game and starts it.
 * The game's NativeAOT C# (libTallowGame.so) is loaded by the engine from the app's native library folder.
 */
public class TallowActivity extends SDLActivity {
    @Override
    protected String[] getLibraries() {
        return new String[] { "main" };
    }
}
