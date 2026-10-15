#!/usr/bin/env python3
"""Reconstruct a real Nix store closure from the public binary cache.

This exists so that NixImage can be tested against real Nix packages on a
machine where Nix cannot run at all (no /nix, no root, no namespaces). It asks
Hydra for the output store path of an attribute, walks the reference graph
through the cache's .narinfo files (which is what 'nix-store -qR' does), and
unpacks every path into a store layout of our own.

Every unpacked path is verified against the NarHash in its narinfo while it is
being unpacked, so what ends up on disk is what Nix would have put there.

    ./fetch-closure.py --attr htop --dest /workspace/store --closure-file c.txt

Needs python3 with the 'compression.zstd' module (3.14 or newer) for zstd
nars, and lzma for xz nars.
"""

import argparse
import concurrent.futures
import hashlib
import json
import lzma
import os
import shutil
import struct
import sys
import urllib.error
import urllib.request

try:
	from compression import zstd
except ImportError:  # pragma: no cover
	zstd = None

CACHE = "https://cache.nixos.org"
HYDRA = "https://hydra.nixos.org"
BASE32 = "0123456789abcdfghijklmnpqrsvwxyz"
CHUNK = 1 << 20


def nix_base32(data):
	"""The encoding Nix uses for hashes, in the order it uses for them."""
	out = ""
	bits = len(data) * 8
	length = (bits + 4) // 5
	for n in range(length - 1, -1, -1):
		b = n * 5
		i, j = b // 8, b % 8
		c = data[i] >> j
		if i + 1 < len(data):
			c |= data[i + 1] << (8 - j)
		out += BASE32[c & 0x1F]
	return out


class Reader:
	"""Reads a stream, hashing it as it goes."""

	def __init__(self, stream):
		self.stream = stream
		self.hash = hashlib.sha256()
		self.read_bytes = 0

	def read(self, n):
		buf = self.stream.read(n)
		if buf:
			self.hash.update(buf)
			self.read_bytes += len(buf)
		return buf

	def read_exact(self, n):
		buf = self.read(n)
		while len(buf) < n:
			more = self.read(n - len(buf))
			if not more:
				raise EOFError("nar ended early")
			buf += more
		return buf

	def string(self):
		n = struct.unpack("<Q", self.read_exact(8))[0]
		data = self.read_exact(n)
		pad = (8 - n % 8) % 8
		if pad:
			self.read_exact(pad)
		return data

	def token(self, expected):
		got = self.string()
		if got != expected:
			raise ValueError(f"expected {expected!r}, got {got!r} in nar")


def unpack_node(r, path, mode):
	"""Materialise one nar node at path."""
	r.token(b"(")
	r.token(b"type")
	kind = r.string()
	if kind == b"regular":
		executable = False
		nxt = r.string()
		if nxt == b"executable":
			r.token(b"")
			executable = True
			nxt = r.string()
		if nxt != b"contents":
			raise ValueError(f"unexpected {nxt!r}")
		size = struct.unpack("<Q", r.read_exact(8))[0]
		with open(path, "wb") as f:
			left = size
			while left:
				buf = r.read(min(CHUNK, left))
				if not buf:
					raise EOFError("nar contents ended early")
				f.write(buf)
				left -= len(buf)
		pad = (8 - size % 8) % 8
		if pad:
			r.read_exact(pad)
		if executable:
			mode |= 0o111
	elif kind == b"symlink":
		r.token(b"target")
		target = r.string().decode()
		os.symlink(target, path)
		# symlink permissions mean nothing on Linux, and resolving one
		# whose target has not been unpacked yet would fail
		r.token(b")")
		return
	elif kind == b"directory":
		# writable while we fill it, read only afterwards, like the store
		os.mkdir(path, 0o755)
		while True:
			tok = r.string()
			if tok == b")":
				os.chmod(path, 0o555)
				return
			if tok != b"entry":
				raise ValueError(f"unexpected {tok!r} in directory")
			r.token(b"(")
			r.token(b"name")
			name = r.string().decode()
			r.token(b"node")
			unpack_node(r, os.path.join(path, name), 0o644)
			r.token(b")")
	else:
		raise ValueError(f"unknown nar node type {kind!r}")

	os.chmod(path, mode)
	r.token(b")")


def unpack_nar(reader, path):
	r = Reader(reader)
	if r.string() != b"nix-archive-1":
		raise ValueError("not a nar")
	unpack_node(r, path, 0o644)
	return r.hash.digest()


def fetch(url, dest=None):
	with urllib.request.urlopen(url, timeout=120) as r:
		data = r.read()
	if dest is None:
		return data
	with open(dest, "wb") as f:
		f.write(data)
	return data


def narinfo(store_hash):
	text = fetch(f"{CACHE}/{store_hash}.narinfo").decode()
	info = {}
	for line in text.splitlines():
		key, _, value = line.partition(":")
		info[key] = value.strip()
	info["References"] = info.get("References", "").split()
	return info


def open_nar(url, compression):
	stream = urllib.request.urlopen(url, timeout=120)
	if compression == "zstd":
		if zstd is None:
			raise RuntimeError("this nar is zstd compressed but python has no zstd module")
		return zstd.ZstdFile(stream)
	if compression == "xz":
		return lzma.LZMAFile(stream)
	if compression in ("none", ""):
		return stream
	raise RuntimeError(f"unsupported nar compression {compression!r}")


def hydra_output(attr, jobset):
	url = f"{HYDRA}/job/{jobset}/{attr}.x86_64-linux/latest"
	req = urllib.request.Request(url, headers={"Accept": "application/json"})
	with urllib.request.urlopen(req, timeout=60) as r:
		build = json.load(r)
	out = build.get("buildoutputs", {}).get("out", {})
	if "path" not in out:
		raise RuntimeError(f"hydra job {jobset}/{attr} has no output path")
	return out["path"]


def main():
	ap = argparse.ArgumentParser(description=__doc__)
	ap.add_argument("--attr", help="hydra attribute to resolve, e.g. htop")
	ap.add_argument("--jobset", default="nixpkgs/trunk")
	ap.add_argument("--store-path", help="a /nix/store path to start from")
	ap.add_argument("--list", action="store_true", help="only list the closure, download nothing")
	ap.add_argument("--dest", required=True, help="store layout to unpack into")
	ap.add_argument("--closure-file", help="write the closure here, one path per line")
	ap.add_argument("--jobs", type=int, default=8)
	ap.add_argument("--keep-going", action="store_true", help="warn instead of failing on a missing path")
	args = ap.parse_args()

	if not args.attr and not args.store_path:
		ap.error("give --attr or --store-path")

	root = args.store_path or hydra_output(args.attr, args.jobset)
	print(f"root: {root}")

	# walk the reference graph the way 'nix-store -qR' does
	closure, queue, seen = [], [root], set()
	infos = {}
	while queue:
		path = queue.pop()
		if path in seen:
			continue
		seen.add(path)
		store_hash = os.path.basename(path).split("-", 1)[0]
		info = narinfo(store_hash)
		if info["StorePath"] != path:
			raise RuntimeError(f"{store_hash}.narinfo is for {info['StorePath']}, not {path}")
		infos[path] = info
		closure.append(path)
		queue.extend(f"/nix/store/{ref}" for ref in info["References"])
	print(f"closure: {len(closure)} paths")

	def nar_size(path):
		return int(infos[path].get("NarSize", "0"))

	print(f"size: {sum(nar_size(p) for p in closure)} bytes unpacked")
	if args.list:
		for path in closure:
			print(f"{nar_size(path):>12} {path}")
		return 0

	failed = []
	def one(path):
		info = infos[path]
		name = os.path.basename(path)
		target = os.path.join(args.dest, name)
		if os.path.exists(target):
			return None
		url = f"{CACHE}/{info['URL']}"
		stream = open_nar(url, info.get("Compression", "xz"))
		try:
			got = unpack_nar(stream, target)
		finally:
			stream.close()
		want = info["NarHash"].split(":", 1)[1]
		# narinfo hashes are in Nix's own base32, not hex
		if nix_base32(got) != want:
			raise RuntimeError(
				f"nar hash mismatch for {name}: got {nix_base32(got)}, want {want}"
			)
		return int(info.get("NarSize", "0"))

	os.makedirs(args.dest, exist_ok=True)
	total = 0
	with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
		futures = {pool.submit(one, p): p for p in closure}
		for future in concurrent.futures.as_completed(futures):
			path = futures[future]
			try:
				size = future.result()
				if size:
					total += int(size)
			except Exception as exc:  # noqa: BLE001 - report and keep going if asked
				msg = f"{os.path.basename(path)}: {exc}"
				if not args.keep_going:
					failed.append(msg)
					continue
				print(f"warning: {msg}", file=sys.stderr)

	if failed:
		for msg in failed:
			print(f"error: {msg}", file=sys.stderr)
		return 1

	if args.closure_file:
		with open(args.closure_file, "w") as f:
			for path in closure:
				f.write(f"{path}\n")
	print(f"unpacked {total} bytes into {args.dest}")
	print(root)
	return 0


if __name__ == "__main__":
	sys.exit(main())
