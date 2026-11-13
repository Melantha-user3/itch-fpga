#!/bin/sh
# Place and route one configuration with seeds 1, 2 and 3 in parallel and
# print Fmax and size for each. nextpnr's result moves a few MHz with the
# placement seed, so compare designs on all three, not on one run.
#   cd syn && ./seeds.sh
#   cd syn && ./seeds.sh DECODER=../rtl/experiments/itch_decoder_nozero.sv
# Builds go to ../build/seed1..3 (git-ignored).
set -e
cd "$(dirname "$0")"
root=$(cd .. && pwd)
for s in 1 2 3; do
    d="$root/build/seed$s"
    rm -rf "$d"
    mkdir -p "$d"
    cp -r "$root/syn" "$d/syn"
    ln -s "$root/rtl" "$d/rtl"
    (cd "$d/syn" && make clean >/dev/null && make SEED=$s "$@" >/dev/null 2>&1) &
done
wait
for s in 1 2 3; do
    log="$root/build/seed$s/syn/pnr.log"
    f=$(grep 'Max frequency for clock' "$log" | tail -1 | sed -E 's/.*: ([0-9.]+) MHz.*/\1/')
    lut=$(grep 'TRELLIS_COMB:' "$log" | tail -1 | awk '{print $3}')
    ff=$(grep 'TRELLIS_FF:' "$log" | tail -1 | awk '{print $3}')
    echo "seed $s: $f MHz, LUT4 cells $lut, FFs $ff"
done
