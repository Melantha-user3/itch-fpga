# Low-latency ITCH 5.0 market-data parser (SystemVerilog)

A hardware pipeline that takes raw Ethernet frames carrying Nasdaq
TotalView-ITCH 5.0 over MoldUDP64 and outputs decoded order-book messages.
Verified with a Python golden model and cocotb; synthesized with the
open-source Yosys + nextpnr flow for a Lattice ECP5. A full trading day of
real Nasdaq data was used to find out where the design stops being good
enough.

```
Ethernet frame          UDP payload             one message             decoded fields
64-bit AXI-Stream  -->  eth_ip_udp_rx  -->  moldudp64_framer  -->  itch_decoder  -->  type, order ref,
                        filter + strip      find block bounds       fixed-offset        side, shares,
                        headers, realign    extract message         field decode        stock, price ...
```

**In short:** 2–3 clock cycles from a message's last byte to its decoded
fields, about 97 MHz on the slowest ECP5, zero mismatches on 4.07 million real
messages. Its main limit: at 97 MHz × 64 bits it parses 6.2 Gb/s, slower than
a 10 GbE link. On a real day that adds about 50 ns to a typical message and
up to 11.4 µs during the worst burst (a model, see below). On newer days the
cost grows: up to 467 µs on 2026-06-12, SpaceX's first trading day. Three different
paths all sit at about 10 ns, so fixing any one of them alone does not help
(tried and measured, see Tuning experiments).

## Measured results

Every number here can be reproduced with the commands under
[Running](#running). Nothing has been run on a board.

### The parser

| | Result | How it was measured |
|---|---|---|
| Latency | **2–3 clock cycles** (20.6–30.9 ns at 97.1 MHz) | Per message in simulation: from the edge that captures a message's last byte to the edge that registers its fields. 3 when the last byte waits for the next beat to be realigned. |
| Throughput | Never stalls inside the parser; 0.984 beats/cycle at full input rate | Full-rate simulation; the loss is at most one idle cycle per packet in the header stripper. |
| Fmax (ECP5 LFE5U-25F, speed 6) | **97.1 MHz** (seeds 1–3: 97.1 / 93.1 / 98.1); 125.9 MHz at speed grade 8 | Post-place-and-route estimate from nextpnr (`syn/seeds.sh`). |
| Area | 4,476 LUT4-equivalent cells (18 %), 1,707 FFs (7 %), 0 block RAM | Includes the synthesis wrapper. By module (unflattened synthesis): framer ≈ 81 %, decoder ≈ 13 %, header stripper ≈ 2 %, wrapper ≈ 4 %. |
| Correctness | **4,065,640 real Nasdaq messages** (pre-market and the minute of the day's worst burst) plus 14,700+ randomized messages (all 23 ITCH 5.0 types, every block alignment, malformed and filtered packets): zero mismatches | Every field of every message compared with an independent Python parser. |

Optimization history (same tests pass at every step, see `git log`):

| Version | Framer design | Fmax | LUT4 cells | Latency |
|---|---|---|---|---|
| v1 | 64-byte byte window: pop a message with a 512-bit barrel shift, append the beat at a variable position | 49.8 MHz | 16,789 | 3–4 cycles |
| v2 | Track block boundaries separately; extract each message from a 7-beat history with one shifter | 52.0 MHz | 4,016 | 2–3 cycles |
| v3 | Positions relative to the current beat, next-beat decisions precomputed in registers, length range check moved one beat later | 89.9 MHz | 4,279 | 2–3 cycles |
| v4 | One length adder and range check per lane, run in parallel; a registered lane index picks the result | 97.1 MHz | 4,476 | 2–3 cycles |

### Where the clock period goes

nextpnr reports only the worst path. Removing it (experiments below) exposes
two more at nearly the same delay, and 60–80 % of each is routing:

1. Decoder: the type/length check (`known`) clears ~370 output registers.
   10.3 ns in v4 (2.8 ns logic, 7.5 ns routing).
2. Framer loop: length bytes → per-lane adders → message offset → `rel`
   register. 10.4–10.5 ns in variant A (3.5 ns logic, 7.0 ns routing).
3. Framer data: `rel` → 64-byte message shifter → message register.
   10.0–10.1 ns in variants B and A + C (2.1–2.3 ns logic, 7.8–7.9 ns routing).

### Tuning experiments

Variants are in `rtl/experiments/`; all pass the same tests (A with
`DONT_CARE=1`, which ignores the fields a message type lacks).

| Change | Fmax, seeds 1 / 2 / 3 | LUT4 | Latency | Result |
|---|---|---|---|---|
| v4 as shipped | 97.1 / 93.1 / 98.1 MHz | 4,476 | 2–3 | |
| A. Decoder does not zero the fields a type lacks, so `known` drives one register | 95.4 / 98.8 / 95.8 | 4,050 | 2–3 | No gain: path 2 takes over |
| B. Extra register stage in front of the decoder | 105.0 / 99.7 / 99.0 | 4,096 | 3–4 | Faster clock, slower message: 4 × 9.5 ns = 38 ns vs 3 × 10.3 ns = 31 ns |
| C. Framer offset with one adder less (same function) | 95.6 / 86.0 / 96.6 | 4,356 | 2–3 | No gain: path 1 still there |
| A + C | 102.6 / 98.6 / 97.1 | 3,915 | 2–3 | About +4 % on average, the same size as the seed-to-seed spread; path 3 and the loop remain |

None of them was adopted. A + C saves 12 % of the area but changes the output
contract (fields a type lacks are no longer 0) for a speed gain I cannot
separate from placement noise: the same A + C logic placed from differently
named source files gave 101.7 / 100.8 / 100.3 MHz. On this part the design is
balanced at about 100 MHz; a real step up needs a structural change (see
[Next steps](#next-steps)).

### A full real trading day

Nasdaq's sample file for 2019-01-30 (4.8 GB gzip) was streamed through the C
tools in `analysis/` (results in `analysis/results/`).

| | |
|---|---|
| Messages | 368,366,634 (11.2 GB); 98.6 % are the 7 order-book types decoded here |
| Busiest second | 1,080,489 messages, 23.1 MB, ending 16:00:01.4 (the close): 3 % of the parser's 777 MB/s |
| Worst burst | 682 messages, 22.5 KB, within 0.44 µs of exchange time at 14:46:29.28; 681 of them in one stock (AAPL), 679 executions |
| Peak live orders | 1,742,866 (15:57:46); one stock (AAPL) peaks at 42,774 |

On average the load is tiny; the problem is bursts. A 10 GbE link needs at
least 18 µs to deliver that 22.5 KB burst, and this parser needs about 30 µs.

**What the speed gap costs** (`analysis/queue_sim.c`). The model sends each
message on a 10 GbE link as soon as it is ready (exchange timestamp) and the
link is free, packing ready messages into MTU-sized packets. It then feeds the
parser 8 bytes per clock and measures how long each message's last beat waits
because the parser is slower than the wire. The constant 2–3-cycle pipeline
latency comes on top.

| Parser clock | median | 99 % | 99.9 % | 99.99 % | worst | messages delayed > 1 µs |
|---|---|---|---|---|---|---|
| 97.1 MHz (this design) | 49 ns | 59 ns | 342 ns | 1.4 µs | 11.4 µs | 0.025 % (~91k) |
| 100.8 MHz (A + C) | 45 ns | 54 ns | 309 ns | 1.3 µs | 10.3 µs | 0.020 % |
| 125.9 MHz (speed grade 8) | 21 ns | 26 ns | 135 ns | 549 ns | 4.5 µs | 0.0004 % |
| 156.25 MHz (10 GbE line rate) | 3 ns | 4 ns | 4 ns | 5 ns | 6 ns | 0 |

So at 10 GbE a typical message spends about 50 ns waiting for this parser,
more than its 21–31 ns pipeline latency. That median depends on my packing:
the model sends as soon as the link is free, so most packets carry one
message. In a full 1,514-byte frame the last message would wait about
0.74 µs (190 beats take 1.95 µs to parse, 1.22 µs to arrive). On a 1 GbE link
nothing waits: the parser (6.2 Gb/s) is faster than the wire.

### Three days, 2019 to 2026

The same C tools on two newer Nasdaq sample days (`analysis/run_trend.sh`,
results in `analysis/results/*_2025-12-10.txt` and `*_2026-06-12.txt`). The
RTL has not been run on these days. One day per year shows a direction, not a
statistic.

| | 2019-01-30 | 2025-12-10 | 2026-06-12 |
|---|---|---|---|
| Messages | 368 M | 847 M | 1,305 M |
| Busiest second (all at the close) | 23.1 MB, 3 % of 777 MB/s | 37.7 MB, 5 % | 40.7 MB, 5 % |
| Worst 1 µs burst | 682 msgs, 22.5 KB | 4,108 msgs, 136 KB | 27,928 msgs, 922 KB |
| Its stock | AAPL: 679 executions | NFLX: 4,076 executions + 32 hidden-order trades | SPCX: 27,928 executions |
| 10 GbE wait at 97.1 MHz: 99.99 % / worst | 1.4 µs / 11.4 µs | 1.7 µs / 69 µs | 35 µs / 467 µs |
| 10 GbE wait at 156.25 MHz: worst | 6 ns | 6 ns | 6 ns |
| Peak live orders | 1.74 M | 5.24 M | 6.68 M |
| Largest single-stock book | AAPL 42,774 | NVDA 216,489 | SPCX 2,307,617 |

2026-06-12 was SpaceX's first trading day, and the feed itself shows it
(`burst_probe_2026-06-12.txt`): SPCX's stock-directory entry has the IPO flag
set, an IPO quoting message at 07:00 gives a $135 IPO price, the IPO cross at
11:46:45 matched 58,206,084 shares at $150, and the closing cross was at
$160.95. SPCX was only 19.6 M of that day's messages, so the growth in volume
is not that one stock.

What this changes:

- **Bursts grow much faster than volume.** Volume grew 3.5× from 2019 to
  2026. The worst burst grew 6× from 2019 to 2025 and another 7× on
  the IPO day. Each worst burst is one stock's executions within a
  microsecond, which fits one large order taking out hundreds to tens of
  thousands of resting orders (an inference: ITCH does not say who traded).
- **The 10 GbE gap now costs up to half a millisecond.** On the IPO day it is
  not one event: 0.01 % of messages (at least 130,000) waited 35 µs or more,
  more than one 28,000-message burst can account for. At 156.25 MHz every
  wait stays at 6 ns or less.
- **The order book is further from fitting on chip.** 6.68 M live orders is
  about 127 MB at 19 bytes each; one stock alone reached 2.3 M (about 44 MB).

## Limitations

Each item says what breaks and how I know.

- **Slower than 10 GbE line rate.** 97 MHz × 64 bits ≈ 6.2 Gb/s. Cost on a
  real day (model): table above.
- **Fmax is a tool estimate** for the slowest ECP5 speed grade, not a board
  measurement. It moves by several MHz with the placement seed (93.1–98.1 MHz
  for v4), and even with source edits that leave the logic unchanged (A + C
  above).
- **Narrow input format.** IPv4 with no options and no fragments, filtered by
  UDP destination port only. Anything else is dropped and counted
  (`test_filtering`: IPv6, TCP, IP options, fragments, other port, runt
  frame). VLAN-tagged frames would be dropped by the same EtherType check;
  that case is not separately tested.
- **No sequence-gap detection or retransmission.** A lost UDP packet goes
  unnoticed, and anything built on the output would silently go wrong.
- **No order book.** Output is decoded messages only.
- **Real-data coverage of the RTL.** Simulated on the first 80 MB of the day
  (03:04–06:05 ET, pre-market) and on the minute 14:46–14:47 ET that holds the
  worst burst: 4.07 million of the day's 368 million messages. The full-day
  numbers above come from the C tools, not from RTL simulation.
- **Packet boundaries are mine.** The sample file has messages, not the
  original UDP packets, so both the RTL replay and the 10 GbE model use my own
  packing. Exchange timestamps are matching-engine times, not wire times.

## Next steps

In order of what the measurements say matters most:

1. **Reach 10 GbE line rate.** Fixing one path at a time does not work here
   (experiments above), so this needs a structural change. Options:
   a 64-bit datapath at ≥ 156.25 MHz on a faster FPGA; or a 128-bit datapath
   at ≥ 78 MHz plus margin, where up to two messages can end per beat (the
   smallest block is 14 bytes) and the framer needs two extraction ports.
   Success criterion: the 10 GbE model shows ~0 waiting, as in the 156.25 MHz
   row, on all three days including the 2026-06-12 IPO-day burst.
2. **Sequence-gap detection.** One 64-bit compare per packet against the
   expected sequence number, plus a gap flag. Small, and it is about
   correctness, not speed.
3. **Order book.** The day peaks at 1.74 million live orders; at ~19 bytes per
   order (reference 8, shares 4, price 4, locate 2, side 1) that is ~33 MB,
   so it needs external memory. Even AAPL alone (42,774 orders, ~0.8 MB) is
   6× the 126 KB of block RAM in this ECP5-25F. On 2026-06-12 the peak is
   6.68 million (~127 MB). That decides the hardware before the design.
4. **Board bring-up.** Replace the Fmax estimate with a measurement and time
   wire-to-output latency with a hardware counter.

## Real-data replay (RTL)

Nasdaq publishes full-day TotalView-ITCH 5.0 sample files at
<https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/>. The replay test reads messages
from `01302019.NASDAQ_ITCH50.gz` (2019-01-30), packs them into
1500-byte-MTU MoldUDP64/UDP frames, and compares every decoded field with the
reference parser. Two windows were replayed:

| | First 80 MB (03:04–06:05 ET, pre-market) | 14:46:00–14:47:00 ET (holds the worst burst) |
|---|---|---|
| Messages | 2,753,971 in 55,700 packets, all matched | 1,311,669 in 27,754 packets, all matched |
| Order-book messages | 2,533,769 (A 1,006,677 · D 996,878 · X 418,371 · U 109,057 · E 2,737 · F 49) | 1,306,809 (A 585,364 · D 563,708 · U 103,924 · E 37,327 · X 12,536 · F 3,382 · C 568) |
| Other types | L 193,665 · R 8,714 · H 8,712 · Y 8,712 · P 397 · S 2 | P 4,800 · I 60 (50 bytes, the longest message) |
| Icarus Verilog wall time | 36 minutes | 20 minutes |

Quick try, about a minute: the first minute of pre-market trading
(04:00:00–04:01:00 ET, 29,777 messages, 29,770 of them order messages). `SHOW=12`
prints the first 12 orders as the hardware decoded them. Downloading takes a
few seconds and the simulation 26 seconds on the machine used here. The
download script stops after 80 MB, so a `curl: (23) Failure writing output`
line at that point is expected.

```
cc -O2 -o analysis/extract_window analysis/extract_window.c
model/fetch_nasdaq_sample.sh sample.itch
analysis/extract_window 14400000000000 14460000000000 < sample.itch > open60s.itch
cd tb && ITCH_FILE=../open60s.itch SHOW=12 make COCOTB_TEST_FILTER=test_real_nasdaq_replay
```

```
hardware decoded: 04:00:00.000565835  A  add order 9005: sell 600 ARGX @ 107.2600
hardware decoded: 04:00:00.001106902  A  add order 9245: buy  500 ASML @ 175.8400
...
real data: 627 packets, 29777 messages (29770 order messages) all match; types {'A': 14132, 'D': 10325, 'X': 4205, 'U': 1050, ...}
```

The two full windows:

```
model/fetch_nasdaq_sample.sh /path/to/sample.itch     # streams only the first 80 MB
cd tb && ITCH_FILE=/path/to/sample.itch NUM_REAL=3000000 make COCOTB_TEST_FILTER=test_real_nasdaq_replay

# the 14:46 minute (streams the whole 4.8 GB file once, keeps 40 MB)
cc -O2 -o analysis/extract_window analysis/extract_window.c
curl -sS "https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/01302019.NASDAQ_ITCH50.gz" | gzip -dc \
    | analysis/extract_window 53160000000000 53220000000000 > minute1446.itch
cd tb && ITCH_FILE=../minute1446.itch NUM_REAL=2000000 make COCOTB_TEST_FILTER=test_real_nasdaq_replay
```

## Decoded messages

`A` Add Order, `F` Add Order with MPID, `E` Order Executed, `C` Order
Executed with Price, `X` Order Cancel, `D` Order Delete, `U` Order Replace.
Every other ITCH 5.0 message is framed correctly and output with its common
fields (type, stock locate, tracking number, timestamp) and `known = 0`.

## Layout

```
rtl/eth_ip_udp_rx.sv     Ethernet/IPv4/UDP filter and header strip, 2-byte realign
rtl/moldudp64_framer.sv  MoldUDP64 header, message boundaries, message extraction
rtl/itch_decoder.sv      ITCH field decode (registered)
rtl/itch_parser_top.sv   top level
rtl/experiments/         tuning variants A, B, C (not used by default)
model/itch_model.py      packet builder + independent reference parser
tb/test_parser.py        cocotb tests
syn/                     Yosys + nextpnr flow for ECP5; seeds.sh runs seeds 1-3
analysis/                full-day traffic, 10 GbE waiting model, order-book size, window extract, symbol probe (C)
docs/ARCHITECTURE.md     architecture, performance and trade-offs
```

## Running

Tools: Icarus Verilog 12, Python 3 with `cocotb` (2.x), Yosys, nextpnr-ecp5, a
C compiler. On macOS the simplest install is YosysHQ's OSS CAD Suite, plus
`pip install cocotb`.

```
cd tb  && make                 # all tests; NUM_MSGS=20000 SEED=7 make for more
cd tb  && make WAVES=1         # waveform in tb/sim_build/itch_parser_top.fst
cd syn && make                 # synthesis + place & route, prints Fmax and usage
cd syn && ./seeds.sh           # same with seeds 1-3; add DECODER=... / FRAMER=... for a variant
cd syn && make area            # LUT4 / carry / FF per module (unflattened synthesis)
cd tb  && make DECODER=../rtl/experiments/itch_decoder_nozero.sv DONT_CARE=1   # variant A
cd analysis && ./run_full_day.sh   # streams the 4.8 GB sample day, ~6 minutes
cd analysis && ./run_trend.sh      # the 2025-12-10 and 2026-06-12 days, each streamed twice, ~1-2 hours
python3 model/itch_model.py    # golden-model self-check
```
