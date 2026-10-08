#!/usr/bin/env python3
"""Generate vectors.svh for tb_sha512_path.sv using hashlib as the golden model.
Lengths cover the SHA-512 padding edge cases (111/112/113/127/128 bytes), empty,
single/multi block, and non-multiple-of-8 sizes."""
import hashlib, random

random.seed(2026)
LENS = [0, 1, 3, 7, 8, 9, 55, 64, 111, 112, 113, 120, 127, 128, 129, 200, 255]
MAXB = 256

lines = []
for i, n in enumerate(LENS):
    msg = bytes(random.randrange(256) for _ in range(n))
    if n == 3:
        msg = b"abc"
    dig = hashlib.sha512(msg).digest()
    pad = msg + bytes(MAXB - n)
    mhex = int.from_bytes(pad, "little")          # byte i = bits [8i+:8]
    dhex = int.from_bytes(dig, "big")
    lines.append(
        f"    do_doc(16'd{i+1}, 16'd{n}, {MAXB*8}'h{mhex:0{MAXB*2}x}, 512'h{dhex:0128x});"
    )

with open("vectors.svh", "w") as f:
    f.write(f"localparam NDOCS = {len(LENS)};\n")
    f.write("task run_all_docs;\n  begin\n")
    f.write("\n".join(lines))
    f.write("\n  end\nendtask\n")
print(f"wrote vectors.svh with {len(LENS)} documents")
