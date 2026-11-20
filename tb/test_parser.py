"""cocotb testbench for itch_parser_top.

Each test builds packets with the Python model, pushes them into the DUT as
AXI-Stream beats, collects every decoded message, and compares it field by
field with what the Python reference parser says.
"""

import os
import random
import statistics

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb.utils import get_sim_time

from itch_model import (FIELDS, build_frame, build_mold, parse_frame,
                        random_message, to_beats)

PORT = 26477
CLK_NS = 4   # 250 MHz in simulation


def now_cycle():
    """Index of the current clock edge (from simulation time, so every coroutine agrees)."""
    return round(get_sim_time(unit="ns") / CLK_NS)
SEED = int(os.environ.get("SEED", "12345"))
# DONT_CARE=1: for decoders that do not zero the fields a message type lacks
# (see rtl/experiments/), compare only the fields the type defines.
DONT_CARE = os.environ.get("DONT_CARE", "0") == "1"
# SHOW=n: print the first n order messages the hardware decoded, in plain words.
SHOW = int(os.environ.get("SHOW", "0"))
COMMON = {"known", "seq", "type", "locate", "tracking", "timestamp"}
TYPE_FIELDS = {
    ord("A"): {"order_ref", "side", "shares", "stock", "price"},
    ord("F"): {"order_ref", "side", "shares", "stock", "price", "attribution"},
    ord("E"): {"order_ref", "shares", "match"},
    ord("C"): {"order_ref", "shares", "match", "printable", "price"},
    ord("X"): {"order_ref", "shares"},
    ord("D"): {"order_ref"},
    ord("U"): {"order_ref", "new_order_ref", "shares", "price"},
}


def describe(rec):
    """One decoded order message as a readable line (for SHOW=n)."""
    t = chr(rec["type"])
    ns = rec["timestamp"]
    s = ns // 10**9
    when = f"{s // 3600:02d}:{s // 60 % 60:02d}:{s % 60:02d}.{ns % 10**9:09d}"
    stock = rec["stock"].to_bytes(8, "big").decode("ascii", "replace").strip()
    px = rec["price"] / 1e4
    ref = rec["order_ref"]
    if t in "AF":
        side = "buy " if rec["side"] == ord("B") else "sell"
        what = f"add order {ref}: {side} {rec['shares']} {stock} @ {px:.4f}"
    elif t == "E":
        what = f"order {ref}: {rec['shares']} shares executed"
    elif t == "C":
        what = f"order {ref}: {rec['shares']} shares executed @ {px:.4f}"
    elif t == "X":
        what = f"order {ref}: {rec['shares']} shares cancelled"
    elif t == "D":
        what = f"order {ref}: deleted"
    else:
        what = f"order {ref} replaced by {rec['new_order_ref']}: {rec['shares']} @ {px:.4f}"
    return f"{when}  {t}  {what}"


def mask_unused(rec):
    keep = COMMON | (TYPE_FIELDS.get(rec["type"], set()) if rec["known"] else set())
    return {f: (v if f in keep else 0) for f, v in rec.items()}


class Harness:
    def __init__(self, dut):
        self.dut = dut
        self.cycle = 0
        self.outputs = []      # (cycle, fields)
        self.accepted = []     # (frame_index, beat_index, cycle)
        self.pkt_done = 0
        self.pkt_err = 0
        self.pkt_drop = 0
        self.expect = None     # optional iterator: check outputs as they come, keep none
        self.checked = 0
        self.shown = 0

    async def start(self):
        dut = self.dut
        Clock(dut.clk, CLK_NS, unit="ns").start()
        dut.rst.value = 1
        dut.cfg_udp_port.value = PORT
        dut.s_axis_tvalid.value = 0
        dut.s_axis_tdata.value = 0
        dut.s_axis_tkeep.value = 0
        dut.s_axis_tlast.value = 0
        for _ in range(4):
            await RisingEdge(dut.clk)
        dut.rst.value = 0
        cocotb.start_soon(self._monitor())

    async def _monitor(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.clk)
            self.cycle = now_cycle()
            if dut.m_valid.value == 1:
                raw = {f: getattr(dut, "m_" + f).value for f in FIELDS}
                if not all(v.is_resolvable for v in raw.values()):
                    raise AssertionError(f"X/Z on output at cycle {self.cycle}: {raw}")
                rec = {f: int(v) for f, v in raw.items()}
                if DONT_CARE:
                    rec = mask_unused(rec)
                if self.shown < SHOW and rec["known"]:
                    dut._log.info("hardware decoded: " + describe(rec))
                    self.shown += 1
                if self.expect is None:
                    self.outputs.append((self.cycle, rec))
                else:
                    e = next(self.expect, None)
                    if rec != e:
                        raise AssertionError(f"message {self.checked} mismatch: got {rec}, expected {e}")
                    self.checked += 1
            self.pkt_done += int(dut.stat_pkt_done.value)
            self.pkt_err += int(dut.stat_pkt_done.value) & int(dut.stat_pkt_err.value)
            self.pkt_drop += int(dut.stat_pkt_drop.value)

    async def send(self, frames, rng=None, gap_prob=0.0):
        """Drive frames back to back. With gap_prob > 0, tvalid randomly drops."""
        dut = self.dut
        for fi, frame in enumerate(frames):
            for bi, (data, keep, last) in enumerate(to_beats(frame)):
                while rng is not None and rng.random() < gap_prob:
                    dut.s_axis_tvalid.value = 0
                    await RisingEdge(dut.clk)
                dut.s_axis_tdata.value = data
                dut.s_axis_tkeep.value = keep
                dut.s_axis_tlast.value = int(last)
                dut.s_axis_tvalid.value = 1
                while True:
                    await RisingEdge(dut.clk)
                    if dut.s_axis_tready.value == 1:
                        break
                self.accepted.append((fi, bi, now_cycle()))
        dut.s_axis_tvalid.value = 0

    async def drain(self, n=200):
        for _ in range(n):
            await RisingEdge(self.dut.clk)


def expected_for(frames):
    exp, statuses = [], []
    for f in frames:
        msgs, status = parse_frame(f, PORT)
        exp.extend(msgs)
        statuses.append(status)
    return exp, statuses


def check(h, exp):
    got = [rec for _, rec in h.outputs]
    assert len(got) == len(exp), f"got {len(got)} messages, expected {len(exp)}"
    for i, (g, e) in enumerate(zip(got, exp)):
        if g != e:
            diff = {k: (hex(g[k]), hex(e[k])) for k in FIELDS if g[k] != e[k]}
            raise AssertionError(f"message {i} mismatch (got, expected): {diff}")


def random_packet(rng, seq, max_msgs=20, types=None):
    msgs = [random_message(rng, types) for _ in range(rng.randint(1, max_msgs))]
    return build_frame(build_mold(seq, msgs), PORT), len(msgs)


@cocotb.test()
async def test_single_add_order(dut):
    """One packet with one Add Order: the simplest possible case."""
    h = Harness(dut)
    await h.start()
    rng = random.Random(SEED)
    frame = build_frame(build_mold(1000, [random_message(rng, [b"A"])]), PORT)
    exp, _ = expected_for([frame])
    await h.send([frame])
    await h.drain(30)
    check(h, exp)
    assert h.pkt_done == 1 and h.pkt_err == 0


@cocotb.test()
async def test_random_traffic(dut):
    """Many random packets with all 23 ITCH message types, random tvalid gaps."""
    h = Harness(dut)
    await h.start()
    rng = random.Random(SEED + 1)
    n_target = int(os.environ.get("NUM_MSGS", "10000"))
    frames, seq, n = [], 1, 0
    while n < n_target:
        f, k = random_packet(rng, seq)
        frames.append(f)
        seq += k
        n += k
    exp, _ = expected_for(frames)
    await h.send(frames, rng, gap_prob=0.2)
    await h.drain()
    check(h, exp)
    assert h.pkt_done == len(frames) and h.pkt_err == 0
    known = sum(e["known"] for e in exp)
    dut._log.info(f"{len(frames)} packets, {len(exp)} messages ({known} order messages) all match")


@cocotb.test()
async def test_filtering(dut):
    """Packets that are not ours (wrong port, not UDP, fragments...) are dropped."""
    h = Harness(dut)
    await h.start()
    rng = random.Random(SEED + 2)
    payload = build_mold(1, [random_message(rng, [b"A"]) for _ in range(3)])
    bad = [
        build_frame(payload, PORT + 1),                 # other UDP port
        build_frame(payload, PORT, ethertype=0x86DD),   # IPv6
        build_frame(payload, PORT, protocol=6),         # TCP
        build_frame(payload, PORT, ver_ihl=0x46),       # IPv4 options
        build_frame(payload, PORT, flags_frag=0x2000),  # more fragments
        build_frame(payload, PORT, flags_frag=0x0010),  # later fragment
        bytes(range(30)),                               # runt frame
    ]
    good = build_frame(payload, PORT)
    frames = []
    for b in bad:
        frames += [b, good]
    exp, statuses = expected_for(frames)
    assert statuses.count("drop") == len(bad)
    await h.send(frames, rng, gap_prob=0.1)
    await h.drain()
    check(h, exp)
    assert h.pkt_drop == len(bad)
    assert h.pkt_done == len(bad) and h.pkt_err == 0   # only the good copies reach the framer


@cocotb.test()
async def test_bad_framing_recovers(dut):
    """Truncated or corrupt MoldUDP64 packets flag an error; the next packet still works."""
    h = Harness(dut)
    await h.start()
    rng = random.Random(SEED + 3)
    msgs = [random_message(rng, ORDER) for ORDER in [[b"A"], [b"E"], [b"U"]]]
    mold = build_mold(50, msgs)
    zero_len = build_mold(60, msgs[:1])[:20] + b"\x00\x00" + b"\x00" * 30
    too_long = build_mold(70, msgs[:1])[:20] + b"\x00\x40" + b"\x00" * 64
    bad = [
        build_frame(mold[:-5], PORT),                     # cut in the middle of a message
        build_frame(build_mold(80, msgs, count=5), PORT), # header says 5, only 3 present
        build_frame(zero_len, PORT),
        build_frame(too_long, PORT),
        build_frame(mold[:15], PORT),                     # shorter than the header
    ]
    good = build_frame(mold, PORT)
    frames = []
    for b in bad:
        frames += [b, good]
    exp, statuses = expected_for(frames)
    assert statuses.count("err") == len(bad)
    await h.send(frames)
    await h.drain()
    check(h, exp)
    assert h.pkt_err == len(bad) and h.pkt_done == len(frames)


@cocotb.test()
async def test_heartbeat_and_padding(dut):
    """Heartbeats (count 0), end of session (0xFFFF) and Ethernet padding give no messages."""
    h = Harness(dut)
    await h.start()
    rng = random.Random(SEED + 4)
    one = random_message(rng, [b"D"])
    frames = [
        build_frame(build_mold(5, []), PORT),
        build_frame(build_mold(5, [], count=0xFFFF), PORT),
        build_frame(build_mold(5, [one]), PORT),           # 63 bytes, no padding needed
        build_frame(build_mold(6, [one]) + b"\xAA" * 9, PORT),  # trailing junk after count reached
    ]
    exp, _ = expected_for(frames)
    await h.send(frames)
    await h.drain()
    check(h, exp)
    assert h.pkt_done == len(frames) and h.pkt_err == 0


@cocotb.test()
async def test_latency_and_throughput(dut):
    """Full-rate input (tvalid always 1): measure latency and check no stalls are needed."""
    h = Harness(dut)
    await h.start()
    rng = random.Random(SEED + 5)
    frames, msg_meta, seq = [], [], 1
    for _ in range(300):
        msgs = [random_message(rng, [b"A", b"E", b"X", b"D", b"U"]) for _ in range(rng.randint(1, 20))]
        frames.append(build_frame(build_mold(seq, msgs), PORT))
        pos = 42 + 20
        for m in msgs:
            pos += 2 + len(m)
            msg_meta.append((len(frames) - 1, (pos - 1) // 8))   # beat holding the last byte
        seq += len(msgs)
    exp, _ = expected_for(frames)
    start = now_cycle()
    await h.send(frames)
    in_cycles = now_cycle() - start
    await h.drain()
    check(h, exp)

    accept_cycle = {(fi, bi): c for fi, bi, c in h.accepted}
    # Latency = clock edges from the edge that captures the message's last byte
    # to the edge that loads the decoded result into the output registers.
    lat = [out_c - 1 - accept_cycle[meta] for (out_c, _), meta in zip(h.outputs, msg_meta)]
    total_beats = sum(len(to_beats(f)) for f in frames)
    dut._log.info(f"latency (cycles): min {min(lat)}, max {max(lat)}, "
                  f"mean {statistics.mean(lat):.2f}")
    dut._log.info(f"{total_beats} beats took {in_cycles} cycles "
                  f"({total_beats / in_cycles:.3f} beats/cycle)")
    with open(os.environ.get("LATENCY_REPORT", "latency.txt"), "w") as fh:
        fh.write(f"messages {len(lat)}\nmin {min(lat)}\nmax {max(lat)}\n"
                 f"mean {statistics.mean(lat):.3f}\n"
                 f"beats_per_cycle {total_beats / in_cycles:.4f}\n")


@cocotb.test()
async def test_every_alignment(dut):
    """Every pair of message types back to back, so blocks start and end in every lane
    (including the length field split across two beats and a 50-byte message ending in lane 0)."""
    from itch_model import ITCH_LEN
    h = Harness(dut)
    await h.start()
    rng = random.Random(SEED + 6)
    frames, seq, starts, ends = [], 1, set(), set()
    for t1 in ITCH_LEN:
        for t2 in ITCH_LEN:
            msgs = [random_message(rng, [t1]), random_message(rng, [t2]), random_message(rng, [t1])]
            frames.append(build_frame(build_mold(seq, msgs), PORT))
            pos = 20
            for m in msgs:
                starts.add(pos % 8)
                pos += 2 + len(m)
                ends.add((pos - 1) % 8)
            seq += 3
    assert starts == set(range(8)) and ends == set(range(8))
    exp, _ = expected_for(frames)
    await h.send(frames)
    await h.drain()
    check(h, exp)
    assert h.pkt_done == len(frames) and h.pkt_err == 0


ITCH_FILE = os.environ.get("ITCH_FILE")


@cocotb.test(skip=not ITCH_FILE)
async def test_real_nasdaq_replay(dut):
    """Replay real Nasdaq messages (sample day file, see model/fetch_nasdaq_sample.sh),
    packed into MTU-sized MoldUDP64 packets. Run with ITCH_FILE=<path> [NUM_REAL=n]."""
    from collections import Counter
    from itch_model import decode_message, packetize, read_itch_file
    h = Harness(dut)
    await h.start()
    msgs = read_itch_file(ITCH_FILE, int(os.environ.get("NUM_REAL", "100000")))
    frames = [build_frame(p, PORT) for p in packetize(msgs, 1)]

    def expected():
        # Reference parser on the same frames, one frame at a time; it must
        # get back exactly the messages that were packed
        i = 0
        for f in frames:
            got, status = parse_frame(f, PORT)
            assert status == "ok"
            for e in got:
                assert e == decode_message(1 + i, msgs[i])
                i += 1
                yield e

    h.expect = expected()
    await h.send(frames)
    await h.drain()
    assert h.checked == len(msgs), f"checked {h.checked} of {len(msgs)} messages"
    assert next(h.expect, None) is None
    assert h.pkt_done == len(frames) and h.pkt_err == 0
    types = Counter(chr(m[0]) for m in msgs)
    known = sum(types[t] for t in "AFECXDU")
    dut._log.info(f"real data: {len(frames)} packets, {len(msgs)} messages "
                  f"({known} order messages) all match; types {dict(types.most_common())}")
