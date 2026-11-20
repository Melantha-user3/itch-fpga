// For one symbol: its R (stock directory) fields, all K (IPO quoting) messages,
// H (trading action) and Q (cross trade) messages, message counts by type; plus
// type counts and top symbols for messages with ts in (A, B] ns.
//   sym_probe SYMBOL A_ns B_ns < day.itch
// Used to find out what the worst bursts were (analysis/run_trend.sh).
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static uint64_t be(const uint8_t *p, int n) { uint64_t v = 0; for (int i = 0; i < n; i++) v = (v << 8) | p[i]; return v; }
static void hms(uint64_t ns, char *o) { uint64_t s = ns / 1000000000ULL; sprintf(o, "%02llu:%02llu:%02llu.%09llu", (unsigned long long)(s/3600), (unsigned long long)(s/60%60), (unsigned long long)(s%60), (unsigned long long)(ns%1000000000ULL)); }
static char names[65536][9];
static uint64_t win_loc[65536];
int main(int argc, char **argv) {
    if (argc != 4 || strlen(argv[1]) > 8) { fprintf(stderr, "usage: sym_probe SYMBOL A_ns B_ns < day.itch\n"); return 1; }
    char sym[9]; memset(sym, ' ', 8); sym[8] = 0; memcpy(sym, argv[1], strlen(argv[1]));
    uint64_t A = strtoull(argv[2], 0, 10), B = strtoull(argv[3], 0, 10);
    int loc = -1; uint64_t cnt[256] = {0}, wcnt[256] = {0}, wn = 0; char t[32];
    static uint8_t m[65536];
    for (;;) {
        uint8_t l[2];
        if (fread(l, 1, 2, stdin) != 2) break;
        uint32_t len = (l[0] << 8) | l[1];
        if (fread(m, 1, len, stdin) != len) break;
        uint16_t lc = be(m + 1, 2); uint64_t ts = be(m + 5, 6);
        if (m[0] == 'R') {
            memcpy(names[lc], m + 11, 8);
            if (!memcmp(m + 11, sym, 8)) {
                loc = lc; hms(ts, t);
                printf("R %s locate %u market %c fin %c roundlot %llu class %c subtype %.2s ipo_flag %c etp %c\n",
                       t, lc, m[19], m[20], (unsigned long long)be(m + 21, 4), m[26], (char *)m + 27, m[31], m[33]);
            }
        }
        if (m[0] == 'K') { hms(ts, t); printf("K %s stock %.8s release %llus qual %c ipo_price %.4f\n", t, (char *)m + 11,
                           (unsigned long long)be(m + 19, 4), m[23], be(m + 24, 4) / 10000.0); }
        if (lc == loc) {
            cnt[m[0]]++;
            if (m[0] == 'H') { hms(ts, t); printf("H %s state %c reason %.4s\n", t, m[19], (char *)m + 21); }
            if (m[0] == 'Q') { hms(ts, t); printf("Q %s shares %llu price %.4f type %c\n", t, (unsigned long long)be(m + 11, 8), be(m + 27, 4) / 10000.0, m[39]); }
        }
        if (ts > A && ts <= B) { wn++; wcnt[m[0]]++; win_loc[lc]++; }
    }
    printf("symbol %s locate %d messages by type:", sym, loc);
    for (int i = 0; i < 256; i++) if (cnt[i]) printf(" %c=%llu", i, (unsigned long long)cnt[i]);
    printf("\nwindow (%llu,%llu]: %llu msgs:", (unsigned long long)A, (unsigned long long)B, (unsigned long long)wn);
    for (int i = 0; i < 256; i++) if (wcnt[i]) printf(" %c=%llu", i, (unsigned long long)wcnt[i]);
    printf("\nwindow top symbols:");
    for (int k = 0; k < 3; k++) {
        int best = 0;
        for (int i = 0; i < 65536; i++) if (win_loc[i] > win_loc[best]) best = i;
        if (!win_loc[best]) break;
        printf(" %.8s=%llu", names[best], (unsigned long long)win_loc[best]);
        win_loc[best] = 0;
    }
    printf("\n");
    return 0;
}
