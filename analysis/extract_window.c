// Copy the messages with timestamp in [A, B) ns (ITCH day file on stdin) to stdout.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    uint64_t A = strtoull(argv[1], 0, 10), B = strtoull(argv[2], 0, 10);
    static uint8_t m[65538];
    for (;;) {
        if (fread(m, 1, 2, stdin) != 2) break;
        uint32_t len = (m[0] << 8) | m[1];
        if (fread(m + 2, 1, len, stdin) != len) break;
        uint64_t ts = 0;
        for (int i = 7; i < 13; i++) ts = (ts << 8) | m[i];
        if (ts >= A && ts < B) fwrite(m, 1, 2 + len, stdout);
    }
    return 0;
}
