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
| Fmax (ECP5 LFE5U-25F, speed 6) | **89.9 MHz** (seeds 1–3: 89.9 / 90.2 / 93.3 MHz); 120 MHz at speed grade 8 |
| Area | 4,279 LUT4-equivalent cells (17 %), 1,719 FFs (7 %), 0 block RAM, including the synthesis wrapper |
| Verification | 14,700+ randomized messages across all 23 ITCH 5.0 message types, every block alignment in the 8-byte beat, malformed and filtered packets; zero mismatches |

Optimization history (same tests pass at every step, see `git log`):

| Version | Framer design | Fmax | LUT4 cells | Latency |
|---|---|---|---|---|
| v1 | 64-byte byte window: pop a message with a 512-bit barrel shift, append the beat at a variable position | 49.8 MHz | 16,789 | 3–4 cycles |
| v2 | Track block boundaries separately; extract each message from a 7-beat history with one shifter | 52.0 MHz | 4,016 | 2–3 cycles |
| v3 | Positions relative to the current beat, next-beat decisions precomputed in registers, length range check moved one beat later | 89.9 MHz | 4,279 | 2–3 cycles |

The remaining critical path is the framer's per-beat loop: incoming data →
8:1 lane mux for the 2-byte length → 6-bit add → next block position. It
cannot be pipelined without look-ahead because the next block can start in
the very next beat.

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
- Not yet run on a board or on a recorded Nasdaq capture.
- 90 MHz × 64 bits ≈ 5.8 Gb/s, below 10GbE line rate on this low-cost FPGA.
