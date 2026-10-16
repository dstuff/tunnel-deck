#!/usr/bin/env python3
"""Reproducible DB-IP country data: Xray GeoIP protobuf + mmap-friendly UI index.

No external Python dependencies. The source is CC BY 4.0, not a user profile.
"""
import csv
import gzip
import hashlib
import ipaddress
import io
from pathlib import Path
import struct
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
VERSION = "2026-10"
URL = f"https://download.db-ip.com/free/dbip-country-lite-{VERSION}.csv.gz"
SOURCE_SHA256 = "097426b8ddae89157d444a59ac1847e873f7943c32d52becc4371c8b0273af80"


def varint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def message(field, value):
    return varint((field << 3) | 2) + varint(len(value)) + value


def build(source, target):
    groups = {}
    ranges = {4: [], 6: []}
    with gzip.open(source, "rt", newline="") as stream:
        for start, end, country in csv.reader(stream):
            lo, hi = ipaddress.ip_address(start), ipaddress.ip_address(end)
            if lo.version != hi.version or int(lo) > int(hi) or len(country) != 2 or not country.isascii() or not country.isalpha():
                raise ValueError("Invalid country range")
            country = country.upper()
            ranges[lo.version].append((lo.packed, hi.packed, country.encode("ascii")))
            bucket = groups.setdefault(country, bytearray())
            for network in ipaddress.summarize_address_range(lo, hi):
                bucket.extend(message(2, message(1, network.network_address.packed) + varint(16) + varint(network.prefixlen)))
    target.mkdir(parents=True, exist_ok=True)
    result = bytearray()
    for country, cidrs in sorted(groups.items()):
        result.extend(message(1, message(1, country.encode("ascii")) + cidrs))
    (target / "geoip.dat").write_bytes(result)
    with (target / "countries.bin").open("wb") as out:
        out.write(b"TDGEO001" + VERSION.encode("ascii") + b"\x00" + struct.pack("!II", len(ranges[4]), len(ranges[6])))
        for family in (4, 6):
            previous = None
            for lo, hi, country in sorted(ranges[family]):
                if previous is not None and previous >= lo:
                    raise ValueError("Overlapping country ranges")
                out.write(lo + hi + country)
                previous = hi
    for name in ("geoip.dat", "countries.bin"):
        print(name, hashlib.sha256((target / name).read_bytes()).hexdigest())


if __name__ == "__main__":
    source = ROOT / ".runtime-sources" / f"dbip-country-lite-{VERSION}.csv.gz"
    source.parent.mkdir(parents=True, exist_ok=True)
    if not source.exists():
        with urllib.request.urlopen(URL, timeout=120) as response:
            data = response.read(32_000_001)
        if hashlib.sha256(data).hexdigest() != SOURCE_SHA256:
            raise SystemExit("DB-IP source checksum mismatch")
        source.write_bytes(data)
    if hashlib.sha256(source.read_bytes()).hexdigest() != SOURCE_SHA256:
        raise SystemExit("DB-IP source checksum mismatch")
    build(source, ROOT / "Runtime" / "geoip")
