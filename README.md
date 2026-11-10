# Low-latency ITCH 5.0 market-data parser (SystemVerilog)

A hardware pipeline that takes raw Ethernet frames carrying Nasdaq
TotalView-ITCH 5.0 over MoldUDP64 and outputs decoded order-book messages.
Verified with a Python golden model and cocotb; synthesized with the
open-source Yosys + nextpnr flow for a Lattice ECP5.

```
Ethernet frame          UDP payload             one message             decoded fields
64-bit AXI-Stream  -->  eth_ip_udp_rx  -->  moldudp64_framer  -->  itch_decoder  -->  type, order ref,
                        filter + strip      find block bounds       fixed-offset        side, shares,
                        headers, realign    extract message         field decode        stock, price ...
```

## Results

| | |
|---|---|
| Latency | **2–3 clock cycles** from the edge that captures a message's last byte to the edge that registers its decoded fields |
| Throughput | Never stalls inside the parser; 0.984 beats/cycle at full input rate (the loss is at most one idle cycle per packet in the header stripper) |
| Fmax (ECP5 LFE5U-25F, speed 6) | **97.1 MHz** post-place-and-route (seeds 1–3: 97.1 / 93.1 / 98.1 MHz); 125.9 MHz at speed grade 8. Not measured on a board. |
| Area | 4,476 LUT4-equivalent cells (18 %), 1,707 FFs (7 %), 0 block RAM, including the synthesis wrapper |
| Verification | **2,753,971 real Nasdaq messages** from a public sample day, plus 14,700+ randomized messages across all 23 ITCH 5.0 message types, every block alignment in the 8-byte beat, malformed and filtered packets; zero mismatches |

Optimization history (same tests pass at every step, see `git log`):

| Version | Framer design | Fmax | LUT4 cells | Latency |
|---|---|---|---|---|
| v1 | 64-byte byte window: pop a message with a 512-bit barrel shift, append the beat at a variable position | 49.8 MHz | 16,789 | 3–4 cycles |
| v2 | Track block boundaries separately; extract each message from a 7-beat history with one shifter | 52.0 MHz | 4,016 | 2–3 cycles |
| v3 | Positions relative to the current beat, next-beat decisions precomputed in registers, length range check moved one beat later | 89.9 MHz | 4,279 | 2–3 cycles |
| v4 | One length adder and range check per lane, run in parallel; a registered lane index picks the result | 97.1 MHz | 4,476 | 2–3 cycles |

The framer's per-beat loop (length → next block position) must close in one
cycle because the next block can start in the very next beat; v4 moves the
lane mux after the adders so the loop is short. The critical path is now in
the decoder: the type/length check (`known`) fans out to ~370 output
registers. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design
and its trade-offs.

## Real-data replay

Nasdaq publishes full-day TotalView-ITCH 5.0 sample files at
<https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/>. The replay test takes the first
80 MB of `01302019.NASDAQ_ITCH50.gz` (2019-01-30, about 03:04 to 06:05 ET,
i.e. the start of pre-market), packs the messages into 1500-byte-MTU
MoldUDP64/UDP frames, and compares every decoded field with the reference
parser.

| | |
|---|---|
| Messages | 2,753,971 in 55,700 packets, all matched |
| Order-book messages | 2,533,769 (A 1,006,677 · D 996,878 · X 418,371 · U 109,057 · E 2,737 · F 49; no C in this window) |
| Other types | L 193,665 · R 8,714 · H 8,712 · Y 8,712 · P 397 · S 2 |
| Simulation | 36 minutes of Icarus Verilog wall time |

The file stores messages back to back with their 2-byte lengths, not the
original UDP packets, so the packet boundaries are ours; the message
contents are Nasdaq's.

```
model/fetch_nasdaq_sample.sh /path/to/sample.itch     # streams only the first 80 MB
cd tb && ITCH_FILE=/path/to/sample.itch NUM_REAL=3000000 make COCOTB_TEST_FILTER=test_real_nasdaq_replay
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
model/itch_model.py      packet builder + independent reference parser
tb/test_parser.py        cocotb tests
syn/                     Yosys + nextpnr flow for ECP5
docs/ARCHITECTURE.md     architecture, performance and trade-offs
```

## Running

Tools: Icarus Verilog 12, Python 3 with `cocotb` (2.x), Yosys, nextpnr-ecp5.
On macOS the simplest install is YosysHQ's OSS CAD Suite, plus `pip install cocotb`.

```
cd tb  && make                 # all tests; NUM_MSGS=20000 SEED=7 make for more
cd tb  && make WAVES=1         # waveform in tb/sim_build/itch_parser_top.fst
cd syn && make                 # synthesis + place & route, prints Fmax and usage
python3 model/itch_model.py    # golden-model self-check
```

## Assumptions and limits

- The MAC has removed the FCS; `tkeep` is all ones except on the last beat.
- IPv4 without options (IHL = 5), no fragments. Filtering is by UDP destination port.
- No sequence-gap detection or retransmission request, no order book yet.
- Not yet run on a board. Real Nasdaq data has been replayed in simulation only, and only a pre-market window.
- 97 MHz × 64 bits ≈ 6.2 Gb/s, below 10GbE line rate on this low-cost FPGA.
