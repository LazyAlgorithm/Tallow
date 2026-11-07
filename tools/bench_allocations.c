// Optional Linux/glibc EcsBench counter. Build with:
//   cc -std=c11 -O2 -shared -fPIC tools/bench_allocations.c -o /path/to/bench_allocations.so
// Run the benchmark with LD_PRELOAD=/path/to/bench_allocations.so. Counts successful malloc, calloc and
// realloc calls in the whole process, including graphics/worker threads; custom pools and aligned allocation
// APIs are not counted. No library is needed in normal engine builds. glibc entry points avoid dlsym recursion.
#define _GNU_SOURCE
#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>
#include <linux/perf_event.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

extern void* __libc_malloc(size_t);
extern void* __libc_calloc(size_t, size_t);
extern void* __libc_realloc(void*, size_t);

static _Atomic uint64_t allocations;

void* malloc(size_t size)
{
	void* result = __libc_malloc(size);
	if (result) atomic_fetch_add_explicit(&allocations, 1, memory_order_relaxed);
	return result;
}

void* calloc(size_t count, size_t size)
{
	void* result = __libc_calloc(count, size);
	if (result) atomic_fetch_add_explicit(&allocations, 1, memory_order_relaxed);
	return result;
}

void* realloc(void* pointer, size_t size)
{
	void* result = __libc_realloc(pointer, size);
	if (result) atomic_fetch_add_explicit(&allocations, 1, memory_order_relaxed);
	return result;
}

uint64_t tallow_bench_allocations(void)
{
	return atomic_load_explicit(&allocations, memory_order_relaxed);
}

// Optional current-thread user-mode hardware counters for --profile-scripts. These stages run on the
// calling thread; they do not include renderer workers or kernel activity. Unsupported/denied events give -1.
int tallow_bench_cache_start(int misses)
{
	struct perf_event_attr attr = {0};
	attr.type = PERF_TYPE_HARDWARE;
	attr.size = sizeof(attr);
	attr.config = misses ? PERF_COUNT_HW_CACHE_MISSES : PERF_COUNT_HW_CACHE_REFERENCES;
	attr.disabled = 1;
	attr.exclude_kernel = 1;
	attr.exclude_hv = 1;
	int fd = syscall(SYS_perf_event_open, &attr, 0, -1, -1, 0);
	if (fd >= 0 && ioctl(fd, PERF_EVENT_IOC_ENABLE, 0) != 0)
	{
		close(fd);
		return -1;
	}
	return fd;
}

int64_t tallow_bench_cache_stop(int fd)
{
	if (fd < 0) return -1;
	uint64_t count = 0;
	int ok = ioctl(fd, PERF_EVENT_IOC_DISABLE, 0) == 0 && read(fd, &count, sizeof(count)) == sizeof(count);
	close(fd);
	return ok ? (int64_t)count : -1;
}
