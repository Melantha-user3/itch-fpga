#!/usr/bin/env bash
# The full-day measurements of run_full_day.sh on two newer Nasdaq sample days,
# plus a probe of each day's worst burst. Each file is streamed twice and never
# stored: pass 2 needs the burst time that pass 1 (itch_stats) finds. Mostly
# download time, roughly 20-40 minutes per pass.
#   cd analysis && ./run_trend.sh
set -e -o pipefail
cd "$(dirname "$0")"
for t in itch_stats queue_sim book_size sym_probe; do cc -O2 -o $t $t.c -lm; done
BASE="https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH"
mkdir -p results
# day, file, symbol to probe, end of the worst 1-us burst (ns after midnight, from pass 1).
# NFLX is the 2025 burst's stock; SPCX is the 2026 day's largest book and its burst's stock.
# sym_probe prints the burst window's top symbols whichever symbol it is given.
while read -r day file sym t; do
    curl -sS "$BASE/$file" | gzip -dc | tee \
        >(./itch_stats > results/traffic_$day.txt) \
        >(./queue_sim > results/queue_10gbe_$day.txt) \
        | ./book_size > results/order_book_size_$day.txt
    curl -sS "$BASE/$file" | gzip -dc \
        | ./sym_probe "$sym" $((t - 1000)) "$t" > results/burst_probe_$day.txt
done <<'EOF'
2025-12-10 S121025-v50.txt.gz NFLX 38317273156756
2026-06-12 S061226-v50.txt.gz SPCX 55939938793178
EOF
sleep 2   # let the process substitutions finish writing
cat results/*_2025-12-10.txt results/*_2026-06-12.txt
