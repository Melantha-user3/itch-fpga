// How big would an order book have to be? Replays a full ITCH 5.0 day file
// (stdin) and tracks every live order: A/F add, E/C execute (shares down),
// X cancel (shares down), D delete, U replace (old out, new in). An order
// whose shares reach 0 is removed. Reports the peak number of live orders,
// overall and for the busiest single stock.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TBITS 26
#define TSIZE (1ull << TBITS)          // 64M slots, linear probing
typedef struct { uint64_t ref; uint32_t shares; uint16_t loc; uint16_t used; } slot_t;
static slot_t *tab;
static uint64_t live = 0, peak = 0, peak_ts = 0, missing = 0, dup = 0;
static uint32_t loc_live[65536], loc_peak[65536];
static char names[65536][9];

static inline uint64_t h(uint64_t x) { x ^= x >> 33; x *= 0xff51afd7ed558ccdULL; x ^= x >> 33; return x & (TSIZE - 1); }
static slot_t *find(uint64_t ref) {
    for (uint64_t i = h(ref);; i = (i + 1) & (TSIZE - 1)) {
        if (!tab[i].used) return NULL;
        if (tab[i].ref == ref) return &tab[i];
    }
}
static void insert(uint64_t ref, uint32_t shares, uint16_t loc, uint64_t ts) {
    uint64_t i = h(ref);
    while (tab[i].used) {
        if (tab[i].ref == ref) { dup++; return; }
        i = (i + 1) & (TSIZE - 1);
    }
    tab[i] = (slot_t){ref, shares, loc, 1};
    if (++live > peak) { peak = live; peak_ts = ts; }
    if (live > TSIZE / 2) { fprintf(stderr, "table too full\n"); exit(1); }
    if (++loc_live[loc] > loc_peak[loc]) loc_peak[loc] = loc_live[loc];
}
static void erase(slot_t *s) {                 // backward-shift deletion
    uint64_t i = s - tab;
    loc_live[s->loc]--; live--;
    tab[i].used = 0;
    for (uint64_t j = (i + 1) & (TSIZE - 1); tab[j].used; j = (j + 1) & (TSIZE - 1)) {
        uint64_t k = h(tab[j].ref);
        // move j back to i if its home k is not cyclically in (i, j]
        int in = (i <= j) ? (i < k && k <= j) : (i < k || k <= j);
        if (!in) { tab[i] = tab[j]; tab[j].used = 0; i = j; }
    }
}
static void reduce(uint64_t ref, uint32_t n) {
    slot_t *s = find(ref);
    if (!s) { missing++; return; }
    if (n >= s->shares) erase(s); else s->shares -= n;
}

static uint64_t be(const uint8_t *p, int n) { uint64_t v = 0; for (int i = 0; i < n; i++) v = (v << 8) | p[i]; return v; }

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

int main(void) {
    tab = calloc(TSIZE, sizeof(slot_t));
    if (!tab) return 1;
    uint64_t adds = 0;
    for (;;) {
        if (!fill(2)) break;
        uint32_t len = (buf[bpos] << 8) | buf[bpos + 1];
        if (!fill(2 + len)) break;
        const uint8_t *m = buf + bpos + 2;
        bpos += 2 + len;
        uint16_t loc = be(m + 1, 2);
        uint64_t ts = be(m + 5, 6);
        switch (m[0]) {
            case 'R': memcpy(names[loc], m + 11, 8); break;
            case 'A': case 'F': insert(be(m + 11, 8), be(m + 20, 4), loc, ts); adds++; break;
            case 'E': case 'C': reduce(be(m + 11, 8), be(m + 19, 4)); break;
            case 'X': reduce(be(m + 11, 8), be(m + 19, 4)); break;
            case 'D': { slot_t *s = find(be(m + 11, 8)); if (s) erase(s); else missing++; break; }
            case 'U': {
                slot_t *s = find(be(m + 11, 8));
                uint16_t l = loc;
                if (s) erase(s); else missing++;
                insert(be(m + 19, 8), be(m + 27, 4), l, ts); adds++;
                break;
            }
        }
    }
    uint32_t best = 0; int best_loc = 0;
    for (int l = 0; l < 65536; l++) if (loc_peak[l] > best) { best = loc_peak[l]; best_loc = l; }
    uint64_t s = peak_ts / 1000000000ULL;
    printf("orders added (A/F/U) %llu\npeak live orders %llu at %02llu:%02llu:%02llu\n"
           "live at end of file %llu\nbusiest stock: locate %d (%s), peak %u live orders\n"
           "references not found %llu, duplicate adds %llu\n",
           (unsigned long long)adds, (unsigned long long)peak, (unsigned long long)(s / 3600),
           (unsigned long long)(s / 60 % 60), (unsigned long long)(s % 60), (unsigned long long)live,
           best_loc, names[best_loc], best, (unsigned long long)missing, (unsigned long long)dup);
    // how many stocks would fit if each needs its own peak
    return 0;
}
