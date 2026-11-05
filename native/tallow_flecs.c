// Flecs and Tallow's shim in one translation unit, so the shim can see Flecs's private structures (the world's table
// versions, for ComponentRef's fast path) without the vendored files being changed.
#include "flecs.c"
#include "tallow_ecs.c"
