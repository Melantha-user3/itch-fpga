#!/bin/sh
# Download the first 80 MB (about 2.75 million messages) of Nasdaq's public
# TotalView-ITCH 5.0 sample day 2019-01-30, without fetching the whole 4.8 GB.
# Source listing: https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/
set -e
OUT=${1:-01302019_head80MB.itch}
curl -sS "https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/01302019.NASDAQ_ITCH50.gz" \
    | gunzip 2>/dev/null | head -c 80000000 > "$OUT" || true
ls -l "$OUT"
