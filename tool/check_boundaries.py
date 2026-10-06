#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Check the few dependency rules that protect the shared application seams."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
errors = []
for source in (root / "lib/ui").rglob("*.dart"):
    text = source.read_text()
    for imported in re.findall(r"import\s+['\"]([^'\"]+)", text):
        if imported == "dart:ffi" or "/receiver/native/" in imported or "generated/receiver_bindings" in imported:
            errors.append(f"{source.relative_to(root)}: UI must use the receiver model or window controller")
    if "MethodChannel(" in text:
        errors.append(f"{source.relative_to(root)}: system channels belong in lib/platform")
for source in (root / "native/receiver").glob("*.*"):
    text = source.read_text()
    if re.search(r'#include\s*[<"][^>"\n]*(?:dart_|/ffi/)', text):
        errors.append(f"{source.relative_to(root)}: receiver control cannot include Dart transport")
for source in (root / "native/playback").glob("*.*"):
    if re.search(r'#include\s*[<"](?:raop|dnssd|raop_ntp)\.h', source.read_text()):
        errors.append(f"{source.relative_to(root)}: UxPlay integration belongs in native/protocol")
if errors:
    raise SystemExit("\n".join(errors))
print("PASS: UI, receiver control and protocol dependency rules")
