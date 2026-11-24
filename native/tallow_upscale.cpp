// Upscalers that need the graphics API itself (tallowengine.com/docs/quality): NVIDIA DLSS (NGX) and AMD FidelityFX
// Super Resolution 3. FSR 1 is a plain shader pass in the engine and is not here.
//
// kind: 1 DLSS, 2 FSR 3.
#include <cstdio>
#include <cstring>

extern "C" {

// 1 when the upscaler can run on this machine and renderer right now, else 0 with the reason (for the settings
// screen) written into `reason` (NUL-terminated, at most reasonLength bytes including the NUL).
int tn_upscale_supported(int kind, char* reason, int reasonLength)
{
	if (reason != nullptr && reasonLength > 0)
		std::snprintf(reason, (size_t)reasonLength, "%s", kind == 1 ? "DLSS is not built into this engine yet" : "FSR 3 is not built into this engine yet");
	return 0;
}

}
