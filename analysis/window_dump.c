// Type counts, distinct stock locates and timestamp span for messages with ts in (A, B] ns.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    uint64_t A = strtoull(argv[1], 0, 10), B = strtoull(argv[2], 0, 10);
    uint64_t cnt[256] = {0}, n = 0, tmin = ~0ULL, tmax = 0, bytes = 0;
    static uint8_t seen[65536]; int nloc = 0; uint16_t top_loc = 0; static uint32_t loc_cnt[65536];
    uint8_t m[65536];
    for (;;) {
        uint8_t l[2];
        if (fread(l, 1, 2, stdin) != 2) break;
        uint32_t len = (l[0] << 8) | l[1];
        if (fread(m, 1, len, stdin) != len) break;
        uint64_t ts = 0;
        for (int i = 5; i < 11; i++) ts = (ts << 8) | m[i];
        if (ts > B) continue;
        if (ts <= A) continue;
        n++; cnt[m[0]]++; bytes += 2 + len;
        if (ts < tmin) tmin = ts;
        if (ts > tmax) tmax = ts;
        uint16_t loc = (m[1] << 8) | m[2];
        if (!seen[loc]) { seen[loc] = 1; nloc++; }
        if (++loc_cnt[loc] > loc_cnt[top_loc]) top_loc = loc;
    }
    printf("window (%llu, %llu]: %llu msgs, %llu bytes, ts span %llu ns, %d stock locates (top locate %u: %u msgs)\n",
           (unsigned long long)A, (unsigned long long)B, (unsigned long long)n, (unsigned long long)bytes,
           (unsigned long long)(n ? tmax - tmin : 0), nloc, top_loc, loc_cnt[top_loc]);
    for (int t = 0; t < 256; t++) if (cnt[t]) printf(" %c=%llu", t, (unsigned long long)cnt[t]);
    printf("\n");
    return 0;
}
