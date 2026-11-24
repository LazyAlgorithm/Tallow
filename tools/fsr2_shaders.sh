#!/bin/bash
# Regenerates third_party/fsr2/shaders_vk (see third_party/fsr2/README.tallow).
# usage: tools/fsr2_shaders.sh <path to a FidelityFX-FSR2 v2.2.1 checkout>   (needs wine on Linux; runs the .exe directly on Windows)
set -e
SDK="$(cd "$1" && pwd)"
OUT="$(cd "$(dirname "$0")/.." && pwd)/third_party/fsr2/shaders_vk"
SHADERS="$(cd "$(dirname "$0")/.." && pwd)/third_party/fsr2/ffx-fsr2-api/shaders"
RUN=""; [ "$(uname)" = Linux ] && RUN="wine"
export WINEDEBUG=-all
mkdir -p "$OUT"
cd "$SHADERS"
# The tool wants relative paths.
REL_SC="$(python3 -c "import os,sys;print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$SDK/tools/sc/FidelityFX_SC.exe" "$SHADERS")"
REL_OUT="$(python3 -c "import os,sys;print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$OUT" "$SHADERS")"
BASE="-reflection -deps=gcc -DFFX_GPU=1 -DFFX_FSR2_OPTION_UPSAMPLE_SAMPLERS_USE_DATA_HALF=0 -DFFX_FSR2_OPTION_ACCUMULATE_SAMPLERS_USE_DATA_HALF=0 -DFFX_FSR2_OPTION_REPROJECT_SAMPLERS_USE_DATA_HALF=1 -DFFX_FSR2_OPTION_POSTPROCESSLOCKSTATUS_SAMPLERS_USE_DATA_HALF=0 -DFFX_FSR2_OPTION_UPSAMPLE_USE_LANCZOS_TYPE=2 -compiler=glslang -e main --target-env vulkan1.1 -S comp -Os -DFFX_GLSL=1"
for p in ffx_fsr2_tcr_autogen_pass ffx_fsr2_autogen_reactive_pass ffx_fsr2_accumulate_pass ffx_fsr2_compute_luminance_pyramid_pass ffx_fsr2_depth_clip_pass ffx_fsr2_lock_pass ffx_fsr2_reconstruct_previous_depth_pass ffx_fsr2_rcas_pass; do
	H='{0,1}'; [ $p = ffx_fsr2_compute_luminance_pyramid_pass ] && H=0
	# {1,1} / {0,0}: the key keeps its field (the engine's backend code sets it), both values build the same shader.
	$RUN "$REL_SC" $BASE '-DFFX_FSR2_OPTION_REPROJECT_USE_LANCZOS_TYPE={1,1}' '-DFFX_FSR2_OPTION_HDR_COLOR_INPUT={0,1}' '-DFFX_FSR2_OPTION_LOW_RESOLUTION_MOTION_VECTORS={1,1}' '-DFFX_FSR2_OPTION_JITTERED_MOTION_VECTORS={0,0}' '-DFFX_FSR2_OPTION_INVERTED_DEPTH={0,1}' '-DFFX_FSR2_OPTION_APPLY_SHARPENING={0,1}' "-DFFX_HALF=$H" -name=$p -I. -output="$REL_OUT" $p.glsl > /dev/null
done
rm -f "$OUT"/*.h.d
