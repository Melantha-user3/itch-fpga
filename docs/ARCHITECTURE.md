# Architecture

## 1. Scope

Input: Ethernet frames (FCS already stripped) on a 64-bit AXI-Stream.
Output: one decoded ITCH 5.0 message per valid pulse, as named fields.
Everything between is a fixed-latency pipeline with no output backpressure:
a market-data consumer must take every message, so the parser is designed to
never need to stall.

```
           64-bit AXI-Stream                64-bit AXI-Stream              message bus              fields
 frame ──► eth_ip_udp_rx ──────────────────► moldudp64_framer ────────────► itch_decoder ─────────► m_*
           filter + strip 42 B header         MoldUDP64 header, block        fixed-offset decode,
           realign payload to lane 0          boundaries, extract message    type/length check
           1 register stage                   1 register stage               1 register stage
```

## 2. Interfaces

| Port group | Signals | Notes |
|---|---|---|
| Input | `s_axis_tdata[63:0]`, `tkeep[7:0]`, `tvalid`, `tlast`, `tready` | Packet byte *k* of a beat is in lane *k* (`tdata[8k+7:8k]`). `tkeep` is all ones except on the last beat. |
| Config | `cfg_udp_port[15:0]` | Frames to any other UDP port are dropped. |
| Output | `m_valid`, `m_known`, `m_seq`, `m_type`, `m_locate`, `m_tracking`, `m_timestamp`, `m_order_ref`, `m_new_order_ref`, `m_side`, `m_shares`, `m_stock`, `m_price`, `m_match`, `m_attribution`, `m_printable` | Fields a message type does not have are 0. `m_known` = order-book type (A F E C X D U) with the right length. |
| Status | `stat_pkt_drop`, `stat_pkt_done`, `stat_pkt_err` | One-cycle pulses per packet. |

`s_axis_tready` drops for one cycle only when a packet's last beat leaves
bytes in lanes 2–7 that need an extra output beat after realignment.

## 3. Modules

**eth_ip_udp_rx.** With IHL = 5 every header field sits at a fixed beat and
lane, so checks are a beat counter plus comparators: EtherType 0x0800,
version/IHL 0x45, no fragmentation, protocol 17, UDP destination port. The
payload starts at byte 42 (beat 5, lane 2); a 6-byte holding register
realigns it so payload byte 0 is in lane 0.

**moldudp64_framer.** The core of the design, split into control and data.

- *Control* reads only the 2-byte length of each block and tracks where the
  current block ends as (beats from now, lane). Because the smallest block is
  14 bytes (2-byte length + 12-byte message) and a beat is 8 bytes, at most
  one block ends and at most one starts in any beat. The length field can
  start in 8 places (lanes 0–6, or split across two beats), so 8 adders and 8
  range checks run on the incoming data in parallel, and a register-driven
  mux picks one. Everything the next beat needs (is it the end beat, which
  lane the next block starts in, where the message will sit in the window) is
  registered a beat early.
- *Data* keeps the last 7 beats in a plain shift register. When a block ends
  in the current beat its message lies within the current beat plus those 7
  (64 bytes; a 50-byte message ending in lane 0 starts 49 bytes back). One
  shifter, whose amount was registered when the block started, extracts it.

**itch_decoder.** Every ITCH 5.0 message shares bytes 0–10 (type, stock
locate, tracking number, 6-byte timestamp). Type-specific fields are read
from fixed big-endian offsets.

## 4. Performance

| Metric | Value | How measured |
|---|---|---|
| Latency | 2–3 cycles | Clock edge that captures a message's last byte to the edge that registers its decoded fields; 3 when the last byte is in lanes 2–7 and waits for the next beat to be realigned. Measured per message in simulation. |
| Throughput | 1 beat/cycle inside the parser; 0.984 beats/cycle overall | The only bubble is the realignment flush at the end of some packets. |
| Fmax | 97.1 MHz (93.1–98.1 MHz across 3 placement seeds) | Yosys + nextpnr, Lattice ECP5 LFE5U-25F, speed grade 6 (slowest); 125.9 MHz at speed grade 8. Post-place-and-route estimate, not measured on a board. |
| Area | 4,476 LUT4-equivalent cells, 1,707 FFs, 0 block RAM | Includes the synthesis wrapper that registers inputs and folds the ~600 output bits into 16 pins. |

Line rate at 97 MHz × 64 bits ≈ 6.2 Gb/s: enough for 1GbE, not for 10GbE
(156.25 MHz at 64 bits, or a 128-bit datapath at ~80 MHz).

## 5. Design trade-offs

| Decision | Chosen | Alternative and why not |
|---|---|---|
| How to cut messages out | Track boundaries, extract from beat history | Byte window that pops a whole message (v1): 49.8 MHz, 16.8k LUTs, because both the pop and the append are variable shifts over 512 bits in one feedback loop. |
| Where the length mux sits | After 8 parallel adders, select by register | Mux then add (v3): the adder sat after the data-dependent mux inside the loop, 89.9 MHz. Parallel costs ~200 LUTs. |
| Length range check | One beat later, flags the packet | Same beat: put a 16-bit compare on every register's enable path. |
| Backpressure | None inside the parser | A consumer of market data cannot slow the exchange down; buffering would only add latency. |
| Decoder output | Registered | Combinational output saves a cycle but hands a long path to whatever consumes the fields. |

Current critical path: framer output → `known` (type and length match) in
the decoder → enable of ~370 output registers. Computing `known` a stage
earlier would raise Fmax at the cost of one more cycle of latency.

## 6. Verification

- `model/itch_model.py`: builds Ethernet/IPv4/UDP/MoldUDP64/ITCH packets and,
  separately, parses them with `struct` straight from the specs. The
  testbench compares every output field of every message against the parser.
- Seven cocotb tests: single message, 10k-message random traffic with
  random `tvalid` gaps, header filtering, malformed MoldUDP64 recovery,
  heartbeats and padding, latency/throughput at full rate, and every pair of
  the 23 message types back to back so blocks start and end in every lane.
- `test_real_nasdaq_replay`: 2,753,971 messages from Nasdaq's public sample
  day (2019-01-30, first 80 MB, pre-market), packed into MTU-sized MoldUDP64
  packets: all match. Details in the README.

## 7. Assumptions and limits

FCS removed upstream; IPv4 without options; no fragments; no sequence-gap
detection or retransmission; no order book; not yet run on a board.
