#!/usr/bin/env bash
# Streams Nasdaq's full-day sample (2019-01-30, 4.8 GB gzip, 11.2 GB raw)
# through the analysis tools without storing it. Takes about 5 minutes.
#   cd analysis && ./run_full_day.sh               # download and analyse
#   cd analysis && ./run_full_day.sh day.itch      # or an already unpacked file
set -e
cd "$(dirname "$0")"
for t in itch_stats queue_sim window_dump book_size; do cc -O2 -o $t $t.c -lm; done
URL="https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/01302019.NASDAQ_ITCH50.gz"
T=53189281943123   # 14:46:29.281943123, end of the worst 1-us burst found by itch_stats
mkdir -p results
if [ -n "$1" ]; then src() { cat "$1"; }; else src() { curl -sS "$URL" | gzip -dc; }; fi
src "$1" | tee \
    >(./itch_stats > results/traffic_full_day.txt) \
    >(./queue_sim > results/queue_10gbe_full_day.txt) \
    >(./window_dump $((T - 1000)) $T > results/worst_burst_1us.txt) \
    >(./window_dump $((T - 100000)) $T > results/worst_burst_100us.txt) \
    | ./book_size > results/order_book_size.txt
sleep 2   # let the process substitutions finish writing
cat results/*.txt
