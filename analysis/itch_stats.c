// Burst statistics for a Nasdaq TotalView-ITCH 5.0 day file on stdin
// (format: 2-byte big-endian length, then the message; repeated).
// For sliding windows of 1 s .. 1 us (by the exchange timestamp) it reports
// the most messages, message bytes (incl. the 2-byte length) and parser
// cycles needed if every message came in its own packet (worst case).
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RING (1u << 24)
typedef struct { uint64_t ts; uint32_t bytes; uint32_t cyc1; } ent;
static ent ring[RING];

#define NW 5
static const uint64_t W[NW] = {1000000000ULL, 1000000ULL, 100000ULL, 10000ULL, 1000ULL};
static const char *WN[NW] = {"1 s", "1 ms", "100 us", "10 us", "1 us"};

static uint8_t buf[1 << 22];
static size_t blen = 0, bpos = 0;
static int fill(size_t need) {
    if (blen - bpos >= need) return 1;
    memmove(buf, buf + bpos, blen - bpos);
    blen -= bpos; bpos = 0;
    while (blen < need) {
        size_t n = fread(buf + blen, 1, sizeof(buf) - blen, stdin);
        if (n == 0) return 0;
        blen += n;
    }
    return 1;
}

static void hms(uint64_t ns, char *out) {
    uint64_t s = ns / 1000000000ULL;
    sprintf(out, "%02llu:%02llu:%02llu.%09llu", (unsigned long long)(s / 3600),
            (unsigned long long)(s / 60 % 60), (unsigned long long)(s % 60),
            (unsigned long long)(ns % 1000000000ULL));
}

static uint64_t per_sec_msgs[86400], per_sec_bytes[86400];

int main(int argc, char **argv) {
    FILE *csv = argc > 1 ? fopen(argv[1], "w") : NULL;
    uint64_t type_count[256] = {0}, len_hist[65536] = {0};
    uint64_t total = 0, total_bytes = 0, nonmono = 0, last_ts = 0;
    uint64_t head[NW] = {0}, sm[NW] = {0}, sb[NW] = {0}, sc[NW] = {0};
    uint64_t mx_m[NW] = {0}, mx_b[NW] = {0}, mx_c[NW] = {0};
    uint64_t at_m[NW] = {0}, at_b[NW] = {0}, at_c[NW] = {0};
    uint64_t tail = 0;
    for (;;) {
        if (!fill(2)) break;
        uint32_t len = (buf[bpos] << 8) | buf[bpos + 1];
        if (!fill(2 + len)) { fprintf(stderr, "truncated at message %llu\n", (unsigned long long)total); break; }
        const uint8_t *m = buf + bpos + 2;
        bpos += 2 + len;
        if (len < 11) { fprintf(stderr, "short message len %u\n", len); continue; }
        uint64_t ts = 0;
        for (int i = 5; i < 11; i++) ts = (ts << 8) | m[i];
        if (ts < last_ts) { nonmono++; ts = last_ts; }
        last_ts = ts;
        type_count[m[0]]++;
        len_hist[len]++;
        total++;
        uint32_t bytes = 2 + len;
        total_bytes += bytes;
        uint32_t frame = 42 + 20 + 2 + len;
        if (frame < 60) frame = 60;
        uint32_t cyc1 = (frame + 7) / 8 + 1;
        uint64_t sec = ts / 1000000000ULL;
        if (sec < 86400) { per_sec_msgs[sec]++; per_sec_bytes[sec] += bytes; }

        ring[tail % RING] = (ent){ts, bytes, cyc1};
        tail++;
        for (int w = 0; w < NW; w++) {
            sm[w]++; sb[w] += bytes; sc[w] += cyc1;
            while (ring[head[w] % RING].ts + W[w] <= ts) {   // keep window (ts - W, ts]
                ent *e = &ring[head[w] % RING];
                sm[w]--; sb[w] -= e->bytes; sc[w] -= e->cyc1;
                head[w]++;
            }
            if (tail - head[w] >= RING) { fprintf(stderr, "ring overflow\n"); return 1; }
            if (sm[w] > mx_m[w]) { mx_m[w] = sm[w]; at_m[w] = ts; }
            if (sb[w] > mx_b[w]) { mx_b[w] = sb[w]; at_b[w] = ts; }
            if (sc[w] > mx_c[w]) { mx_c[w] = sc[w]; at_c[w] = ts; }
        }
    }
    char t1[32], t2[32], t3[32];
    printf("messages %llu\nmessage_bytes_incl_len %llu\nnon_monotonic_timestamps %llu\n",
           (unsigned long long)total, (unsigned long long)total_bytes, (unsigned long long)nonmono);
    printf("mean_message_bytes_incl_len %.3f\n", (double)total_bytes / total);
    printf("types:");
    for (int t = 0; t < 256; t++) if (type_count[t]) printf(" %c=%llu", t, (unsigned long long)type_count[t]);
    printf("\nlengths:");
    for (int l = 0; l < 65536; l++) if (len_hist[l]) printf(" %d=%llu", l, (unsigned long long)len_hist[l]);
    printf("\n\nwindow | max msgs (ends at) | max bytes (ends at) | max worst-case cycles (ends at)\n");
    for (int w = 0; w < NW; w++) {
        hms(at_m[w], t1); hms(at_b[w], t2); hms(at_c[w], t3);
        printf("%s | %llu (%s) | %llu (%s) | %llu (%s)\n", WN[w],
               (unsigned long long)mx_m[w], t1, (unsigned long long)mx_b[w], t2,
               (unsigned long long)mx_c[w], t3);
    }
    if (csv) {
        fprintf(csv, "second,messages,bytes\n");
        for (int s = 0; s < 86400; s++)
            if (per_sec_msgs[s]) fprintf(csv, "%d,%llu,%llu\n", s, (unsigned long long)per_sec_msgs[s],
                                          (unsigned long long)per_sec_bytes[s]);
        fclose(csv);
    }
    return 0;
}
