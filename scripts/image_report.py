#!/usr/bin/env python3
"""Split a WR1204S factory image into kernel and rootfs and check both layouts.

factory.bin is `uImage (lzma, padded to 64 KiB) || squashfs`. Two partition
layouts exist for this board and the flash step depends on which one wins:

  stock DTB  kernel 0x330000 (3.34 MiB)  rootfs 0x3C5000 (3.77 MiB)
  our DTB    one "firmware" partition @0xb0000, 0xF40000 (15.25 MiB),
             split at boot by mtdsplit_uimage

Exit status is 0 when the image fits our layout, 1 otherwise. The stock-layout
figures are printed but never fatal: that layout belongs to the vendor firmware.
"""

import os
import struct
import sys

KERNEL_PART = 0x330000     # stock mtd4
ROOTFS_PART = 0x3C5000     # stock mtd5
FIRMWARE_PART = 0xF40000   # our DTS: partition@b0000, 15.25 MiB
BLOCK = 0x10000            # 64 KiB, the pad-to value in sf19a2890.mk
SQSH_MAGIC = b"hsqs"


def uimage_len(blob):
    """Return the uImage length, or None when the magic is not there."""
    if blob[:4] != b"\x27\x05\x19\x56":
        return None
    # 64-byte header; size counts everything after the header
    (size,) = struct.unpack(">I", blob[12:16])
    return 64 + size


def main(outdir):
    rc = 0
    for name in sorted(os.listdir(outdir)):
        if not name.endswith("factory.bin"):
            continue
        path = os.path.join(outdir, name)
        blob = open(path, "rb").read()
        total = len(blob)

        klen = uimage_len(blob)
        if klen is None:
            print("  %s: not a uImage -- first 4 bytes are %r" % (name, blob[:4]))
            rc = 1
            continue
        kpad = (klen + BLOCK - 1) // BLOCK * BLOCK
        rootfs = blob[kpad:]

        print("  %s" % name)
        print("    total      %9d B  (%.2f MiB)" % (total, total / 1048576.0))
        print("    kernel     %9d B  uImage payload, padded to %d" % (klen, kpad))
        print("    rootfs     %9d B  magic=%r" % (len(rootfs), rootfs[:4]))

        if rootfs[:4] != SQSH_MAGIC:
            print("    FAIL rootfs does not start with the squashfs magic")
            rc = 1
        if klen > KERNEL_PART:
            print("    note kernel exceeds the stock 0x330000 partition")
        if len(rootfs) > ROOTFS_PART:
            print("    note rootfs exceeds the stock 0x3C5000 partition")
        if total > FIRMWARE_PART:
            print("    FAIL image exceeds the 0xF40000 firmware partition")
            rc = 1
        if rc == 0:
            print("    OK   fits the 15.25 MiB firmware partition")
            headroom = FIRMWARE_PART - total
            print("    free %9d B  (%.2f MiB) left for the jffs2 overlay"
                  % (headroom, headroom / 1048576.0))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "out"))
