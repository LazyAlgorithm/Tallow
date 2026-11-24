// Force-included when building the FSR 2 sources with GCC/clang on Linux (they were written for MSVC).
#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cwchar>
#include <cstdlib>
#include <cstdio>
#include <cmath>
#ifndef _countof
#define _countof(a) (sizeof(a) / sizeof((a)[0]))
#endif
#include <locale>
#include <codecvt>
#if !defined(_MSC_VER)
template <size_t N> static inline int wcscpy_s(wchar_t (&dst)[N], const wchar_t* src)
{
	size_t n = std::wcslen(src);
	if (n >= N) { dst[0] = 0; return 34; }
	std::wmemcpy(dst, src, n + 1);
	return 0;
}
#endif
