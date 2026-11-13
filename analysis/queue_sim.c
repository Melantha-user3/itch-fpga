// What a parser slower than the link costs on a real day of Nasdaq ITCH.
// stdin: ITCH 5.0 day file (2-byte length + message, repeated).
//
// Sender model: messages become ready at their exchange timestamp; whenever
// the 10 GbE link is free, all ready messages (up to 1452 payload bytes after
// the 20-byte MoldUDP64 header) go out in one packet. Wire time per packet =
// preamble 8 + frame (min 60) + FCS 4 + IFG 12 bytes.
// Parser model (this design): 64-bit beats, one beat per clock, plus one idle
// clock per packet; a beat can be taken once its last byte has arrived.
// Extra delay of a message = (clock edge that takes the beat holding its last
// byte) - (time that beat finished arriving). Zero if the parser keeps up.
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LINK_BPS 10e9
#define MAX_PAYLOAD 1472            // 1500 MTU - IP 20 - UDP 8
#define NCLK 4
static const double CLK[NCLK] = {97.12e6, 100.84e6, 125.9e6, 156.25e6};
#define NBIN 400000                 // 1 ns bins up to 400 us
static uint64_t hist[NCLK][NBIN + 1];
static double maxd[NCLK], maxd_at[NCLK], start_free[NCLK];
static uint64_t over100ns[NCLK], over1us[NCLK];

typedef struct { double ts; uint16_t len; } msg_t;
#define QN (1u << 22)
static msg_t q[QN];
static uint64_t qh = 0, qt = 0;
static double link_free = 0;
static uint64_t npkt = 0, nmsg_sent = 0, payload_sum = 0;

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

static void send_packet(double now) {
    // take ready messages
    uint16_t ends[200]; int k = 0;
    int payload = 20;
    while (qh < qt && q[qh % QN].ts <= now && payload + 2 + q[qh % QN].len <= MAX_PAYLOAD && k < 200) {
        payload += 2 + q[qh % QN].len;
        ends[k++] = (uint16_t)(42 + payload - 1);   // frame offset of this message's last byte
        qh++;
    }
    if (k == 0) { fprintf(stderr, "empty packet\n"); exit(1); }
    int frame = 42 + payload; if (frame < 60) frame = 60;
    double bt = 8.0 / LINK_BPS;                     // seconds per byte
    double s = now > link_free ? now : link_free;
    link_free = s + (8 + frame + 4 + 12) * bt;
    npkt++; nmsg_sent += k; payload_sum += payload;
    int nbeats = (frame + 7) / 8;
    for (int c = 0; c < NCLK; c++) {
        double T = 1.0 / CLK[c];
        double a0 = s + (8 + (frame < 8 ? frame : 8)) * bt;
        double start = a0 > start_free[c] ? a0 : start_free[c];
        for (int i = 0; i < k; i++) {
            int j = ends[i] / 8;
            int last = 8 * j + 8 < frame ? 8 * j + 8 : frame;
            double avail = s + (8 + last) * bt;
            double take = start + j * T;
            double d = take > avail ? take - avail : 0;
            uint64_t b = (uint64_t)(d * 1e9);
            hist[c][b < NBIN ? b : NBIN]++;
            if (d > 100e-9) over100ns[c]++;
            if (d > 1e-6) over1us[c]++;
            if (d > maxd[c]) { maxd[c] = d; maxd_at[c] = q[(qh - k + i) % QN].ts; }
        }
        int jl = nbeats - 1;
        double avail_l = s + (8 + frame) * bt;
        double take_l = start + jl * T; if (take_l < avail_l) take_l = avail_l;
        start_free[c] = take_l + 2 * T;             // next beat one clock later + one idle clock
    }
}

static double pct(int c, uint64_t total, double p) {
    uint64_t target = (uint64_t)ceil(p * total), acc = 0;
    for (int b = 0; b <= NBIN; b++) { acc += hist[c][b]; if (acc >= target) return b; }
    return NBIN;
}

int main(void) {
    uint64_t total = 0;
    for (;;) {
        if (!fill(2)) break;
        uint32_t len = (buf[bpos] << 8) | buf[bpos + 1];
        if (!fill(2 + len)) break;
        const uint8_t *m = buf + bpos + 2;
        bpos += 2 + len;
        uint64_t ts = 0;
        for (int i = 5; i < 11; i++) ts = (ts << 8) | m[i];
        double t = ts * 1e-9;
        // send what can go out before this message is ready
        while (qh < qt) {
            double now = link_free > q[qh % QN].ts ? link_free : q[qh % QN].ts;
            if (now >= t) break;
            send_packet(now);
        }
        if (qt - qh >= QN) { fprintf(stderr, "queue overflow\n"); return 1; }
        q[qt % QN] = (msg_t){t, (uint16_t)len}; qt++;
        total++;
    }
    while (qh < qt) send_packet(link_free > q[qh % QN].ts ? link_free : q[qh % QN].ts);
    printf("messages %llu packets %llu mean_msgs_per_packet %.2f mean_payload %.1f\n",
           (unsigned long long)total, (unsigned long long)npkt, (double)nmsg_sent / npkt,
           (double)payload_sum / npkt);
    printf("clock_MHz | p50 ns | p99 ns | p99.9 ns | p99.99 ns | max ns (msg ts) | >100ns | >1us\n");
    for (int c = 0; c < NCLK; c++) {
        double at = maxd_at[c]; int hh = (int)(at / 3600), mm = (int)(fmod(at, 3600) / 60);
        double ss = fmod(at, 60);
        printf("%.2f | %.0f | %.0f | %.0f | %.0f | %.0f (%02d:%02d:%012.9f) | %.4f%% | %.4f%%\n",
               CLK[c] / 1e6, pct(c, total, .5), pct(c, total, .99), pct(c, total, .999),
               pct(c, total, .9999), maxd[c] * 1e9, hh, mm, ss,
               100.0 * over100ns[c] / total, 100.0 * over1us[c] / total);
    }
    return 0;
}
