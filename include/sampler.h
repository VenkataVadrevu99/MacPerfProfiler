#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Per-process snapshot
typedef struct {
    int32_t  pid;
    char     name[256];
    double   cpuPercent;       // delta CPU% since last sample (0.0 first call)
    uint64_t residentBytes;    // RSS
    uint64_t virtualBytes;     // VSIZE
    uint32_t threadCount;
} ProcessSample;

// System-wide snapshot
typedef struct {
    double   systemCpuPercent;
    uint64_t freeMemoryBytes;
    uint64_t activeMemoryBytes;
    uint64_t wiredMemoryBytes;
    uint64_t compressedMemoryBytes;
    uint64_t totalMemoryBytes;
    int32_t  processCount;     // populated entries in processes[]
    ProcessSample processes[32];
} SystemSample;

// Opaque sampler — maintains state between calls for delta CPU calculation
typedef void* SamplerHandle;

SamplerHandle sampler_create(void);
void          sampler_destroy(SamplerHandle handle);

// Fills *out with a fresh snapshot. Returns 0 on success, -1 on error.
// topN: how many processes to include (sorted by RSS, max 32)
int           sampler_take(SamplerHandle handle, SystemSample* out, int topN);

// Returns total installed RAM in bytes
uint64_t      sampler_total_memory(void);

#ifdef __cplusplus
}
#endif
