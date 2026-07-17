#!/usr/bin/env python3
"""
decrypt.py — Decrypt IBKR TWS .ibgzenc encrypted log file(s).

Format (TWS 10.48.x, IbgzencVersion 3):

  File header:
    [u8  magic "IBGZENC\\0"]
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
  decrypt.py [-o OUT] [-k HEX_KEY] PATH [PATH ...]
  decrypt.py --all [--root DIR]
  decrypt.py -h

  PATH      One or more .ibgzenc files
  --all     Find and decrypt every *.ibgzenc under --root
  --root    Search root for --all (default: /home/tws/jts)
  -o OUT    Output path (only valid with a single PATH)
  -k HEX    32-char hex AES key. If omitted, auto-pick from
            keys dir based on each log file's mtime.
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
    sys.exit(
        "error: pycryptodome not installed "
        "(try: nix-shell -p python3Packages.pycryptodome --run '...')"
    )

import zlib

MAGIC = b"IBGZENC\0"
DEFAULT_KEYS_DIR = "/home/tws/jts/logs/keys"
DEFAULT_ROOT = "/home/tws/jts"


class DecryptError(Exception):
    """Recoverable per-file decrypt failure."""


def parse_key(hex_string, source):
    try:
        key = bytes.fromhex(hex_string.strip())
    except ValueError as e:
        raise DecryptError(f"invalid hex key in {source}: {hex_string!r}") from e
    if len(key) not in (16, 24, 32):
        raise DecryptError(
            f"key in {source} has bad length {len(key)} (expected 16/24/32)"
        )
    return key


def find_key_for_log(log_path, keys_dir):
    """Pick the best matching key for a given log file.

    Strategy: the key with the largest timestamp <= log mtime wins.
    Falls back to the most-recently-extracted key if no timestamp is
    <= mtime (the key may have been extracted after the log was
    written — the file could still be in-progress).

    Returns (key_bytes, source_path).
    """
    if not os.path.isdir(keys_dir):
        raise DecryptError(f"keys directory not found: {keys_dir}")

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
        candidates = sorted(glob.glob(os.path.join(keys_dir, "key-*.hex")))
        if not candidates:
            raise DecryptError(f"no key files in {keys_dir}")
        current = os.path.join(keys_dir, "current")
        if os.path.islink(current):
            target = os.readlink(current)
            target_path = (
                target if os.path.isabs(target)
                else os.path.join(keys_dir, target)
            )
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


def decrypt_file(path, key, tolerate_truncation=True):
    """Decrypt one .ibgzenc file. Returns plaintext bytes.

    If tolerate_truncation is True (default), stop at the last complete
    chunk when the file is still being written. That is the normal case
    for the active TWS log.
    """
    with open(path, "rb") as f:
        data = f.read()

    if not data.startswith(MAGIC):
        raise DecryptError(f"not an ibgzenc file (bad magic): {path}")

    writer_ver = struct.unpack(">I", data[8:12])[0]
    # reader_ver unused but kept for format documentation
    _reader_ver = struct.unpack(">I", data[12:16])[0]
    iv = data[16:32]
    keyid_len = struct.unpack(">I", data[32:36])[0]
    if 36 + keyid_len > len(data):
        raise DecryptError("truncated header (keyId length out of range)")
    keyid = data[36:36 + keyid_len]
    body = data[36 + keyid_len:]

    print(f"# ibgzenc v{writer_ver} iv={iv.hex()} keyId={keyid!r}",
          file=sys.stderr)

    out = bytearray()
    i = 0
    chunk_n = 0
    while i < len(body):
        if i + 4 > len(body):
            if tolerate_truncation and chunk_n > 0:
                print(f"# trailing partial header at offset {i}; stopping",
                      file=sys.stderr)
                break
            raise DecryptError(f"truncated chunk header at offset {i}")
        plain_len = struct.unpack(">I", body[i:i + 4])[0]
        i += 4
        cipher_len = ((plain_len + 15) // 16) * 16
        if i + cipher_len + 32 > len(body):
            if tolerate_truncation and chunk_n > 0:
                print(
                    f"# trailing partial chunk at offset {i - 4}; "
                    f"stopping ({chunk_n} complete chunks)",
                    file=sys.stderr,
                )
                break
            raise DecryptError(
                f"truncated chunk body at offset {i} "
                f"(want {cipher_len + 32} bytes, have {len(body) - i})"
            )
        ct = body[i:i + cipher_len]
        i += cipher_len
        mac = body[i:i + 32]
        i += 32

        expected = hmac.new(key, ct, hashlib.sha256).digest()
        if not hmac.compare_digest(expected, mac):
            raise DecryptError(
                f"HMAC mismatch on chunk {chunk_n} "
                f"(plaintextLen={plain_len}, ctLen={cipher_len}). "
                f"Wrong key, or file tampered."
            )

        cipher = AES.new(key, AES.MODE_CBC, iv)
        pt = cipher.decrypt(ct)
        pad = pt[-1]
        if not (1 <= pad <= 16 and pt[-pad:] == bytes([pad]) * pad):
            raise DecryptError(f"invalid PKCS5 padding on chunk {chunk_n}")
        actual = pt[:-pad]

        try:
            d = zlib.decompressobj(-15)
            inflated = d.decompress(actual) + d.flush()
        except zlib.error as e:
            raise DecryptError(f"deflate failed on chunk {chunk_n}: {e}") from e

        out.extend(inflated)
        chunk_n += 1
        if chunk_n % 10 == 0:
            print(f"# chunk {chunk_n}, decrypted {len(out)} bytes so far",
                  file=sys.stderr)

    if chunk_n == 0 and len(body) > 0:
        raise DecryptError("no complete chunks in file (still empty/truncated?)")

    print(f"# done: {chunk_n} chunks, {len(out)} bytes plaintext",
          file=sys.stderr)
    return bytes(out)


def default_out_path(path):
    if path.endswith(".ibgzenc"):
        return path[: -len(".ibgzenc")] + ".log"
    return path + ".log"


def should_skip(path, out_path, force):
    if force or not os.path.isfile(out_path):
        return False
    # Skip only when the decrypted file is at least as new as the source.
    try:
        return os.path.getmtime(out_path) >= os.path.getmtime(path)
    except OSError:
        return False


def find_all_ibgzenc(root):
    found = []
    for dirpath, _dirnames, filenames in os.walk(root):
        # Skip the keys/decrypted bookkeeping trees if present.
        base = os.path.basename(dirpath)
        if base in ("keys", "decrypted"):
            continue
        for name in filenames:
            if name.endswith(".ibgzenc"):
                found.append(os.path.join(dirpath, name))
    found.sort()
    return found


def decrypt_one(path, key_hex, keys_dir, out_path, force):
    out_path = out_path or default_out_path(path)
    if should_skip(path, out_path, force):
        print(f"# skip (up to date): {path}", file=sys.stderr)
        return "skipped"

    if key_hex:
        key = parse_key(key_hex, "<command-line -k>")
    else:
        key, _src = find_key_for_log(path, keys_dir)

    plaintext = decrypt_file(path, key)

    # Atomic-ish write: write to temp then rename so readers never see
    # a half-written .log while we re-decrypt a growing source file.
    tmp_path = out_path + ".tmp"
    with open(tmp_path, "wb") as f:
        f.write(plaintext)
    os.replace(tmp_path, out_path)
    print(f"# wrote {out_path}", file=sys.stderr)
    return "ok"


def main():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "paths",
        nargs="*",
        help="path(s) to .ibgzenc file(s)",
    )
    p.add_argument(
        "--all",
        action="store_true",
        help=f"decrypt every *.ibgzenc under --root (default {DEFAULT_ROOT})",
    )
    p.add_argument(
        "--root",
        default=DEFAULT_ROOT,
        help=f"search root for --all (default: {DEFAULT_ROOT})",
    )
    p.add_argument(
        "-o", "--output",
        help="output path (only with a single input file)",
    )
    p.add_argument(
        "-k", "--key",
        help=f"hex AES key (default: auto-pick from {DEFAULT_KEYS_DIR})",
    )
    p.add_argument(
        "--keys-dir",
        default=DEFAULT_KEYS_DIR,
        help=f"directory of timestamped key files (default: {DEFAULT_KEYS_DIR})",
    )
    p.add_argument(
        "-f", "--force",
        action="store_true",
        help="re-decrypt even when output is newer than input",
    )
    args = p.parse_args()

    if args.output and (args.all or len(args.paths) != 1):
        p.error("-o/--output requires exactly one input PATH")

    if args.all:
        paths = find_all_ibgzenc(args.root)
        if not paths:
            print(f"# no .ibgzenc files under {args.root}", file=sys.stderr)
            return 0
    else:
        paths = list(args.paths)
        if not paths:
            p.error("PATH required (or pass --all)")

    ok = skipped = failed = 0
    for path in paths:
        if not os.path.isfile(path):
            print(f"# error: not found: {path}", file=sys.stderr)
            failed += 1
            continue
        print(f"# decrypting {path}", file=sys.stderr)
        try:
            result = decrypt_one(
                path,
                args.key,
                args.keys_dir,
                args.output if len(paths) == 1 else None,
                args.force,
            )
            if result == "skipped":
                skipped += 1
            else:
                ok += 1
        except DecryptError as e:
            print(f"# error: {path}: {e}", file=sys.stderr)
            failed += 1
        except OSError as e:
            print(f"# error: {path}: {e}", file=sys.stderr)
            failed += 1

    if len(paths) > 1 or args.all:
        print(
            f"# summary: ok={ok} skipped={skipped} failed={failed} "
            f"total={len(paths)}",
            file=sys.stderr,
        )

    return 1 if failed and not ok else 0


if __name__ == "__main__":
    sys.exit(main())
