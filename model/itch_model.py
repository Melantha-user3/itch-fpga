"""Python golden model for the ITCH parser.

Two independent halves:
  * build_*  : make Ethernet/IPv4/UDP/MoldUDP64/ITCH packets (the stimulus)
  * parse_*  : read packets back into decoded messages (the expected answer)

The parser is written with `struct` straight from the specs and never looks
at how the packet was built, so a bug in one half shows up as a mismatch.
"""

import random
import struct

# Message lengths from the Nasdaq TotalView-ITCH 5.0 spec (type byte included)
ITCH_LEN = {
    b"S": 12, b"R": 39, b"H": 25, b"Y": 20, b"L": 26, b"V": 35, b"W": 12,
    b"K": 28, b"J": 35, b"h": 21, b"A": 36, b"F": 40, b"E": 31, b"C": 36,
    b"X": 23, b"D": 19, b"U": 35, b"P": 44, b"Q": 40, b"B": 19, b"I": 50,
    b"N": 20, b"O": 48,
}
ORDER_TYPES = [b"A", b"F", b"E", b"C", b"X", b"D", b"U"]

FIELDS = ["known", "seq", "type", "locate", "tracking", "timestamp", "order_ref",
          "new_order_ref", "side", "shares", "stock", "price", "match",
          "attribution", "printable"]


# ---------------------------------------------------------------- building

def _common(t, locate, tracking, ts):
    return t + struct.pack(">HH", locate, tracking) + ts.to_bytes(6, "big")


def random_message(rng, types=None):
    """One random ITCH message as raw bytes."""
    t = rng.choice(types or list(ITCH_LEN))
    head = _common(t, rng.randrange(1 << 16), rng.randrange(1 << 16),
                   rng.randrange(86_400 * 10**9))
    ref = rng.randrange(1 << 64)
    stock = "".join(rng.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
                    for _ in range(rng.randint(1, 8))).ljust(8).encode()
    shares = rng.randrange(1 << 32)
    price = rng.randrange(1 << 32)
    if t in (b"A", b"F"):
        body = struct.pack(">Q1sI8sI", ref, rng.choice([b"B", b"S"]), shares, stock, price)
        if t == b"F":
            body += rng.choice([b"GSCO", b"MSCO", b"NITE", b"VIRT"])
    elif t == b"E":
        body = struct.pack(">QIQ", ref, shares, rng.randrange(1 << 64))
    elif t == b"C":
        body = struct.pack(">QIQ1sI", ref, shares, rng.randrange(1 << 64),
                           rng.choice([b"Y", b"N"]), price)
    elif t == b"X":
        body = struct.pack(">QI", ref, shares)
    elif t == b"D":
        body = struct.pack(">Q", ref)
    elif t == b"U":
        body = struct.pack(">QQII", ref, rng.randrange(1 << 64), shares, price)
    else:
        # Not decoded by the hardware: right length, random contents
        body = bytes(rng.randrange(256) for _ in range(ITCH_LEN[t] - 11))
    msg = head + body
    assert len(msg) == ITCH_LEN[t]
    return msg


def build_mold(seq, msgs, session=b"TESTSESS01", count=None):
    hdr = session + struct.pack(">QH", seq, len(msgs) if count is None else count)
    return hdr + b"".join(struct.pack(">H", len(m)) + m for m in msgs)


def _ip_checksum(hdr):
    s = sum(struct.unpack(">10H", hdr))
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    return ~s & 0xFFFF


def build_frame(payload, dst_port, src_port=40000,
                src_ip=bytes([10, 0, 0, 1]), dst_ip=bytes([233, 54, 12, 111]),
                ethertype=0x0800, protocol=17, flags_frag=0x4000, ver_ihl=0x45):
    """Ethernet II + IPv4 + UDP around `payload`, padded to 60 bytes (no FCS)."""
    udp = struct.pack(">HHHH", src_port, dst_port, 8 + len(payload), 0) + payload
    ip = struct.pack(">BBHHHBBH4s4s", ver_ihl, 0, 20 + len(udp), 0, flags_frag,
                     64, protocol, 0, src_ip, dst_ip)
    ip = ip[:10] + struct.pack(">H", _ip_checksum(ip)) + ip[12:]
    dst_mac = bytes([0x01, 0x00, 0x5E]) + dst_ip[1:]   # IPv4 multicast MAC
    src_mac = bytes([0x02, 0, 0, 0, 0, 1])
    frame = dst_mac + src_mac + struct.pack(">H", ethertype) + ip + udp
    return frame.ljust(60, b"\x00")


# ---------------------------------------------------------------- parsing

def decode_message(seq, msg):
    """Fields the hardware should output for one message (missing fields = 0)."""
    out = dict.fromkeys(FIELDS, 0)
    t = msg[0:1]
    out["seq"] = seq
    out["type"] = msg[0]
    out["locate"], out["tracking"] = struct.unpack_from(">HH", msg, 1)
    out["timestamp"] = int.from_bytes(msg[5:11], "big")
    if t not in ORDER_TYPES or len(msg) != ITCH_LEN[t]:
        return out
    out["known"] = 1
    out["order_ref"] = struct.unpack_from(">Q", msg, 11)[0]
    if t in (b"A", b"F"):
        out["side"] = msg[19]
        out["shares"], = struct.unpack_from(">I", msg, 20)
        out["stock"] = int.from_bytes(msg[24:32], "big")
        out["price"], = struct.unpack_from(">I", msg, 32)
        if t == b"F":
            out["attribution"], = struct.unpack_from(">I", msg, 36)
    elif t in (b"E", b"C"):
        out["shares"], out["match"] = struct.unpack_from(">IQ", msg, 19)
        if t == b"C":
            out["printable"] = msg[31]
            out["price"], = struct.unpack_from(">I", msg, 32)
    elif t == b"X":
        out["shares"], = struct.unpack_from(">I", msg, 19)
    elif t == b"U":
        out["new_order_ref"], out["shares"], out["price"] = struct.unpack_from(">QII", msg, 19)
    return out


def parse_frame(frame, udp_port, max_msg=50):
    """Return (messages, status). status is 'ok', 'drop' (filtered) or 'err'."""
    if len(frame) < 42:
        return [], "drop"
    ethertype, = struct.unpack_from(">H", frame, 12)
    ver_ihl, flags_frag, proto = frame[14], struct.unpack_from(">H", frame, 20)[0], frame[23]
    dport, = struct.unpack_from(">H", frame, 36)
    if (ethertype != 0x0800 or ver_ihl != 0x45 or flags_frag & 0x3FFF
            or proto != 17 or dport != udp_port):
        return [], "drop"
    p = frame[42:]
    if len(p) < 20:
        return [], "err"
    seq, count = struct.unpack_from(">QH", p, 10)
    if count in (0, 0xFFFF):
        return [], "ok"
    out, pos = [], 20
    for _ in range(count):
        if pos + 2 > len(p):
            return out, "err"
        n, = struct.unpack_from(">H", p, pos)
        if n == 0 or n > max_msg or pos + 2 + n > len(p):
            return out, "err"
        out.append(decode_message(seq, p[pos + 2:pos + 2 + n]))
        seq += 1
        pos += 2 + n
    return out, "ok"


# ---------------------------------------------------------------- real data

def read_itch_file(path, max_msgs=None):
    """Messages from a Nasdaq sample file (e.g. 01302019.NASDAQ_ITCH50, gunzipped).

    The file is a plain stream of [2-byte big-endian length][message] blocks,
    the same block format MoldUDP64 carries. A cut-off block at the end is
    ignored.
    """
    with open(path, "rb") as fh:
        data = fh.read()
    msgs, pos = [], 0
    while pos + 2 <= len(data) and (max_msgs is None or len(msgs) < max_msgs):
        n, = struct.unpack_from(">H", data, pos)
        if pos + 2 + n > len(data):
            break
        msgs.append(data[pos + 2:pos + 2 + n])
        pos += 2 + n
    return msgs


def packetize(msgs, first_seq, max_payload=1472):
    """Pack messages into MoldUDP64 packets that fit a 1500-byte MTU
    (1500 - 20 IPv4 - 8 UDP = 1472 bytes of UDP payload)."""
    frames, batch, size, seq = [], [], 20, first_seq
    for m in msgs:
        if batch and size + 2 + len(m) > max_payload:
            frames.append(build_mold(seq, batch))
            seq += len(batch)
            batch, size = [], 20
        batch.append(m)
        size += 2 + len(m)
    if batch:
        frames.append(build_mold(seq, batch))
    return frames


# ---------------------------------------------------------------- AXI-Stream

def to_beats(frame):
    """Split a frame into 64-bit beats: (tdata, tkeep, tlast), byte 0 in lane 0."""
    beats = []
    for i in range(0, len(frame), 8):
        chunk = frame[i:i + 8]
        beats.append((int.from_bytes(chunk, "little"), (1 << len(chunk)) - 1,
                      i + 8 >= len(frame)))
    return beats


if __name__ == "__main__":
    # Self-check: build -> parse gives back exactly what was built
    rng = random.Random(1)
    for _ in range(2000):
        msgs = [random_message(rng) for _ in range(rng.randint(1, 20))]
        seq = rng.randrange(1 << 40)
        got, status = parse_frame(build_frame(build_mold(seq, msgs), 26477), 26477)
        assert status == "ok"
        assert got == [decode_message(seq + i, m) for i, m in enumerate(msgs)]
    print("model self-check passed")
