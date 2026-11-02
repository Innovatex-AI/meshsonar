#!/usr/bin/env python3
"""WP13 radio spikes S1/S3/S11/S12/S13 against ONE MeshCore companion radio over BLE (Nordic UART).

Needs: python3 -m venv v && v/bin/pip install bleak. Run from the Mac with the phone app CLOSED (a companion
radio accepts one BLE client). Frame layouts are from MeshCore commit 81dbae5 examples/companion_radio/MyMesh.cpp.
Writes every frame to chat-spike-capture-<spike>.json (copy into meshsonar/test/fixtures/chat/).

  scan                              list BLE devices (name filter MeshCore)
  contacts  <addr>                  list contacts with out_path_len byte
  s3        <addr> <name-prefix>    set a 2-byte x 2-hop path, read it back, reset it, restore the original
  s12       <addr> <name-prefix>    path discovery (CMD 52) and capture PUSH 0x8D
  s13       <addr> <name-prefix>    set a path, send a DM to an OFFLINE contact, read the path after each retry
  s11       <addr> <name-prefix>    CMD 27 status request to a companion (expect silence)
  s1        <addr> <name-prefix>    send a 160-byte and a 161-byte DM (161 must be refused)
  selftest                          offline frame-encoding checks, no radio

S3/S13 WRITE contact data on the radio: the script saves the original contact frame first and restores it.
"""
import asyncio, json, struct, sys, time

UART = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
RX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"  # write to radio
TX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"  # notify from radio


def path_len_byte(hash_size, hops):
    assert 1 <= hash_size <= 3 and 0 <= hops <= 63 and hash_size * hops <= 64
    return ((hash_size - 1) << 6) | hops


def decode_contact(f):
    assert f[0] == 3 and len(f) >= 148
    plen = f[35]
    nbytes = 0 if plen == 0xFF else (plen & 63) * ((plen >> 6) + 1)
    return dict(pub=f[1:33], type=f[33], flags=f[34], path_len=plen, path=f[36:36 + nbytes],
                name=f[100:132].split(b"\0")[0].decode(errors="replace"), raw=bytes(f))


def encode_add_update(c, path_len, path):
    raw = bytearray(c["raw"])
    raw[0] = 9
    raw[35] = path_len
    raw[36:100] = bytes(path).ljust(64, b"\0")
    return bytes(raw[:1 + 32 + 2 + 1 + 64 + 32 + 4 + 8 + 4]) if len(raw) >= 148 else bytes(raw)


class Radio:
    def __init__(self, addr):
        self.addr, self.q, self.log = addr, asyncio.Queue(), []

    async def __aenter__(self):
        from bleak import BleakClient
        self.c = BleakClient(self.addr)
        await self.c.connect()
        await self.c.start_notify(TX, lambda _, d: self._rx(bytes(d)))
        await self.send(bytes([1, 3, 0, 0, 0, 0, 0, 0]) + b"spike")  # APP_START, app ver 3
        await self.until(lambda f: f[0] == 5)
        return self

    async def __aexit__(self, *a):
        await self.c.disconnect()

    def _rx(self, d):
        self.log.append(("rx", time.time(), d.hex()))
        self.q.put_nowait(d)

    async def send(self, d):
        self.log.append(("tx", time.time(), d.hex()))
        await self.c.write_gatt_char(RX, d, response=False)

    async def until(self, pred, timeout=15):
        end = time.time() + timeout
        while time.time() < end:
            try:
                f = await asyncio.wait_for(self.q.get(), max(0.1, end - time.time()))
            except asyncio.TimeoutError:
                break
            if pred(f):
                return f
        return None

    async def contacts(self):
        await self.send(bytes([4]))
        out = []
        while True:
            f = await self.until(lambda f: f[0] in (2, 3, 4), 20)
            if f is None or f[0] == 4:
                return out
            if f[0] == 3:
                out.append(decode_contact(f))

    async def find(self, prefix):
        m = [c for c in await self.contacts() if c["name"].lower().startswith(prefix.lower())]
        assert len(m) == 1, f"{len(m)} contacts match {prefix!r}"
        return m[0]

    def dump(self, name):
        json.dump(self.log, open(f"chat-spike-capture-{name}.json", "w"), indent=1)


async def main(argv):
    cmd = argv[1]
    if cmd == "selftest":
        assert path_len_byte(1, 2) == 0x02 and path_len_byte(2, 2) == 0x42 and path_len_byte(3, 2) == 0x82
        f = bytes([3]) + bytes(32) + bytes([1, 0, 0x42]) + bytes([0x11, 0x11, 0x22, 0x22]) + bytes(60) + b"Bob".ljust(32, b"\0") + bytes(16)
        c = decode_contact(f)
        assert c["path"] == bytes([0x11, 0x11, 0x22, 0x22]) and c["name"] == "Bob"
        e = encode_add_update(c, path_len_byte(3, 2), bytes(range(6)))
        assert e[0] == 9 and e[35] == 0x82 and e[36:42] == bytes(range(6))
        print("selftest ok")
        return
    if cmd == "scan":
        from bleak import BleakScanner
        for a, (d, adv) in (await BleakScanner.discover(timeout=10, return_adv=True)).items():
            print(a, adv.local_name or d.name, adv.rssi)
        return
    async with Radio(argv[2]) as r:
        if cmd == "contacts":
            for c in await r.contacts():
                print(c["name"], hex(c["path_len"]), c["path"].hex())
            return
        c = await r.find(argv[3])
        key = c["pub"]
        orig = (c["path_len"], c["path"])
        if cmd == "s3":
            for size in (1, 2, 3):
                pl = path_len_byte(size, 2)
                await r.send(encode_add_update(c, pl, bytes(range(1, 2 * size + 1))))
                await r.until(lambda f: f[0] in (0, 1))
                back = await r.find(argv[3])
                print(f"hash_size={size} wrote={pl:#x} read={back['path_len']:#x} path={back['path'].hex()}")
            await r.send(bytes([13]) + key)
            print("reset ->", (await r.find(argv[3]))["path_len"])
            await r.send(encode_add_update(c, *orig))  # restore
            await r.until(lambda f: f[0] in (0, 1))
        elif cmd == "s12":
            await r.send(bytes([52, 0]) + key)
            print("sent:", (await r.until(lambda f: f[0] in (6, 1))).hex())
            print("0x8D:", (lambda f: f.hex() if f else "NONE in 15 s")(await r.until(lambda f: f[0] == 0x8D, 30)))
        elif cmd == "s13":
            await r.send(encode_add_update(c, path_len_byte(1, 2), bytes([1, 2])))
            await r.until(lambda f: f[0] in (0, 1))
            for attempt in range(4):
                await r.send(bytes([2, 0, attempt]) + struct.pack("<I", int(time.time())) + key[:6] + b"s13 probe")
                print("send", (await r.until(lambda f: f[0] in (6, 1))).hex())
                await asyncio.sleep(25)
                back = await r.find(argv[3])
                print(f"after attempt {attempt}: path_len={back['path_len']:#x}")
            await r.send(encode_add_update(c, *orig))
        elif cmd == "s11":
            await r.send(bytes([27]) + key)
            print("sent:", (await r.until(lambda f: f[0] in (6, 1))).hex())
            print("0x87:", (lambda f: f.hex() if f else "NONE in 30 s (companion does not answer)")(await r.until(lambda f: f[0] == 0x87, 30)))
        elif cmd == "s1":
            for n in (160, 161):
                await r.send(bytes([2, 0, 0]) + struct.pack("<I", int(time.time())) + key[:6] + b"x" * n)
                f = await r.until(lambda f: f[0] in (6, 1))
                print(n, "bytes ->", f.hex() if f else "no reply")
        r.dump(cmd)


if __name__ == "__main__":
    asyncio.run(main(sys.argv))
