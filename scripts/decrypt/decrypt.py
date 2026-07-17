#!/usr/bin/env python3
"""
decrypt.py — Decrypt an IBKR TWS .ibgzenc encrypted log file.

Format (TWS 10.48.x, IbgzencVersion 3):

  File header:
    [u8  magic "IBGZENC\0"]
    [u4  writer version BE]
    [u4  reader version BE]
    [u16 IV]
    [u4  keyId length BE]
    [N   keyId bytes (ASCII)]

  Body (repeating):
    [u4  plaintext length BE]
    [L   AES-128-CBC ciphertext, where L = ceil(plaintextLen/16)*16]
    [u32 HMAC-SHA256(key, ciphertext)]

  Plaintext = zlib raw-deflate (nowrap=true) compressed log data.
  AES key is 16 bytes (AES-128). Encryption mode is AES/CBC/PKCS5Padding.

Usage:
  decrypt.py [-o OUT] [-k HEX_KEY] PATH
  decrypt.py -h

  PATH      Path to .ibgzenc file
  -o OUT    Output path (default: PATH with .ibgzenc stripped, .log appended)
  -k HEX    32-char hex string for the AES key. If omitted, auto-pick
            from /home/tws/jts/logs/keys/ based on the log file's mtime.
"""
import argparse
import glob
import hashlib
import hmac
import os
import struct
import sys

try:
    from Crypto.Cipher import AES
except ImportError:
    sys.exit("error: pycryptodome not installed (try: nix-shell -p python3Packages.pycryptodome --run '...')")

import zlib

MAGIC = b"IBGZENC\0"
DEFAULT_KEYS_DIR = "/home/tws/jts/logs/keys"


def parse_key(hex_string, source):
    try:
        key = bytes.fromhex(hex_string.strip())
    except ValueError:
        sys.exit(f"error: invalid hex key in {source}: {hex_string!r}")
    if len(key) not in (16, 24, 32):
        sys.exit(f"error: key in {source} has bad length {len(key)} "
                 f"(expected 16/24/32)")
    return key


def find_key_for_log(log_path, keys_dir):
    """Pick the best matching key for a given log file.

    Strategy: the key with the largest timestamp <= log mtime wins.
    Falls back to the most-recently-extracted key if no timestamp is
    <= mtime (the key may have been extracted after the log was
    written — the file could still be in-progress).

    Returns (key_bytes, source_path) or raises SystemExit on failure.
    """
    if not os.path.isdir(keys_dir):
        sys.exit(f"error: keys directory not found: {keys_dir}")

    log_mtime = os.path.getmtime(log_path)

    best = None  # (timestamp, path)
    for path in glob.glob(os.path.join(keys_dir, "key-*.hex")):
        name = os.path.basename(path)
        try:
            ts = int(name[4:-4])
        except ValueError:
            continue
        if ts <= log_mtime and (best is None or ts > best[0]):
            best = (ts, path)

    if best is None:
        # No key older than the log — try the most-recent key as fallback.
        candidates = sorted(glob.glob(os.path.join(keys_dir, "key-*.hex")))
        if not candidates:
            sys.exit(f"error: no key files in {keys_dir}")
        # Prefer the `current` symlink if it's a valid key.
        current = os.path.join(keys_dir, "current")
        if os.path.islink(current):
            target = os.readlink(current)
            target_path = os.path.join(keys_dir, target)
            if os.path.isfile(target_path):
                best = (os.path.getmtime(target_path), target_path)
        if best is None:
            most_recent = max(candidates, key=os.path.getmtime)
            best = (os.path.getmtime(most_recent), most_recent)

    src = best[1]
    with open(src) as f:
        raw = f.read()
    print(f"# key: {src}", file=sys.stderr)
    return parse_key(raw, src), src


def decrypt_file(path, key):
    with open(path, "rb") as f:
        data = f.read()

    if not data.startswith(MAGIC):
        sys.exit(f"error: not an ibgzenc file (bad magic): {path}")

    writer_ver = struct.unpack(">I", data[8:12])[0]
    reader_ver = struct.unpack(">I", data[12:16])[0]
    iv = data[16:32]
    keyid_len = struct.unpack(">I", data[32:36])[0]
    if 36 + keyid_len > len(data):
        sys.exit("error: truncated header (keyId length out of range)")
    keyid = data[36:36 + keyid_len]
    body = data[36 + keyid_len:]

    print(f"# ibgzenc v{writer_ver} iv={iv.hex()} keyId={keyid!r}",
          file=sys.stderr)

    out = bytearray()
    i = 0
    chunk_n = 0
    while i < len(body):
        if i + 4 > len(body):
            sys.exit(f"error: truncated chunk header at offset {i}")
        plain_len = struct.unpack(">I", body[i:i + 4])[0]
        i += 4
        cipher_len = ((plain_len + 15) // 16) * 16
        if i + cipher_len + 32 > len(body):
            sys.exit(
                f"error: truncated chunk body at offset {i} "
                f"(want {cipher_len + 32} bytes, have {len(body) - i})"
            )
        ct = body[i:i + cipher_len]
        i += cipher_len
        mac = body[i:i + 32]
        i += 32

        # HMAC over ciphertext only.
        expected = hmac.new(key, ct, hashlib.sha256).digest()
        if not hmac.compare_digest(expected, mac):
            sys.exit(
                f"error: HMAC mismatch on chunk {chunk_n} "
                f"(plaintextLen={plain_len}, ctLen={cipher_len}). "
                f"Wrong key, or file tampered."
            )

        cipher = AES.new(key, AES.MODE_CBC, iv)
        pt = cipher.decrypt(ct)
        # Strip PKCS5 padding.
        pad = pt[-1]
        if not (1 <= pad <= 16 and pt[-pad:] == bytes([pad]) * pad):
            sys.exit(f"error: invalid PKCS5 padding on chunk {chunk_n}")
        actual = pt[:-pad]

        # Raw deflate (nowrap=true): wbits = -15.
        try:
            d = zlib.decompressobj(-15)
            inflated = d.decompress(actual) + d.flush()
        except zlib.error as e:
            sys.exit(f"error: deflate failed on chunk {chunk_n}: {e}")

        out.extend(inflated)
        chunk_n += 1
        if chunk_n % 10 == 0:
            print(f"# chunk {chunk_n}, decrypted {len(out)} bytes so far",
                  file=sys.stderr)

    print(f"# done: {chunk_n} chunks, {len(out)} bytes plaintext", file=sys.stderr)
    return bytes(out)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("path", help="path to .ibgzenc file")
    p.add_argument("-o", "--output", help="output path (default: <path>.log)")
    p.add_argument("-k", "--key",
                   help=f"hex AES key (default: auto-pick from "
                        f"{DEFAULT_KEYS_DIR} based on file mtime)")
    p.add_argument("--keys-dir", default=DEFAULT_KEYS_DIR,
                   help=f"directory of timestamped key files (default: "
                        f"{DEFAULT_KEYS_DIR})")
    args = p.parse_args()

    if args.key:
        key = parse_key(args.key, "<command-line -k>")
    else:
        key, _src = find_key_for_log(args.path, args.keys_dir)

    plaintext = decrypt_file(args.path, key)

    out_path = args.output or (args.path.removesuffix(".ibgzenc") + ".log")
    with open(out_path, "wb") as f:
        f.write(plaintext)
    print(f"# wrote {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()