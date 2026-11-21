#!/usr/bin/env python3
# =============================================================================
#                  SP BOUCHER | SOFTWARE & RESEARCH
#             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
# =============================================================================
#
# PROJECT METADATA
# -----------------------------------------------------------------------------
# Project          : ORIX OS Automation
# File             : Scripts/localize.py
# Description      : Builds App/Resources/Localizable.xcstrings (English
#                    source, French Canada) from every Localization/fr.json,
#                    and reports user-facing strings found in the sources that
#                    have no translation.
# Module           : Scripts
# Repository       : https://git.spboucher.ai/orix-automation
# Created          : 2026-11-21
# Last Modified    : 2026-11-21
#
# =============================================================================
# AUTHOR & PROFESSIONAL AFFILIATION
# =============================================================================
#
# Author           : Simon-Pierre Boucher
# Position         : Professor of Finance
# Institution      : Université du Québec en Outaouais (UQO)
# Department       : Département des sciences administratives
# Organization     : SP Boucher
#
# Website          : https://spboucher.ai
# Git              : https://git.spboucher.ai
#
# =============================================================================
# OFFICIAL CONTACT DIRECTORY
# =============================================================================
#
# General          : info@spboucher.ai
# Professional     : contact@spboucher.ai
# Direct           : simon@spboucher.ai
# Research         : research@spboucher.ai
# Development      : dev@spboucher.ai
# Support          : support@spboucher.ai
# Security/Admin   : admin@spboucher.ai
# Notifications    : notifications@spboucher.ai
#
# Preferred Contact: support@spboucher.ai
#
# =============================================================================
# COPYRIGHT & INTELLECTUAL PROPERTY
# =============================================================================
#
# Copyright (c) 2026
# Simon-Pierre Boucher
#
# All rights reserved where applicable.
#
# This file is governed by the applicable project license,
# copyright notices, institutional agreements and relevant law.
#
# Unless expressly authorized by the applicable license or
# rights holder, copying, redistribution, sublicensing,
# publication and commercial exploitation are not permitted.
#
# Existing third-party rights and notices remain unaffected.
#
# =============================================================================
# CONFIDENTIALITY & SECURITY
# =============================================================================
#
# Classification   : Public
# Distribution     : Public repository; use is governed by the project license
# Security Contact : admin@spboucher.ai
#
# Access to this source does not independently grant permission
# to redistribute or disclose confidential materials.
#
# Do not embed credentials, private keys, access tokens,
# certificates or confidential personal information.
#
# =============================================================================
# LICENSE & MAINTENANCE
# =============================================================================
#
# License          : Proprietary, all rights reserved (see license file)
# License File     : LICENSE
# Maintainer       : Simon-Pierre Boucher
# Technical Contact: dev@spboucher.ai
#
# =============================================================================
# END OF SP BOUCHER SOURCE HEADER
# =============================================================================

"""
  Scripts/localize.py            write the string catalog
  Scripts/localize.py --missing  list strings found in Swift sources without a French entry (exit 1 if any)

Every SwiftUI `Text("…")` and `String(localized: "…")` in the packages resolves in the app's main bundle, so one
catalog in the app covers all of them. Keys are the English strings, with interpolations written the way SwiftUI
builds them: %@ for strings, %lld for integers, %lf for doubles.
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "App", "Resources", "Localizable.xcstrings")

# Calls whose first string literal is user-facing.
CALLS = r'(?:Text|Label|Button|Toggle|Picker|Section|Menu|TextField|SecureField|Link|DisclosureGroup|LabeledContent|Tab|EmptyState|PageHeader|SectionHeader|KeyValueRow|MetricTile|NavigationLink|ProgressView|GroupBox|ControlGroup|Stepper|DatePicker|ColorPicker|Slider|Gauge|ContentUnavailableView|CommandMenu|WindowGroup)'
PATTERNS = [
    re.compile(CALLS + r'\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'String\(localized:\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'(?:title|message|subtitle|actionTitle|label|key|placeholder|prompt|help)\s*:\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\.(?:help|navigationTitle|accessibilityLabel|accessibilityHint|accessibilityValue|confirmationDialog|alert)\(\s*(?:Text\()?\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'return\s+"((?:[^"\\]|\\.)*)"\s*$', re.M),
]


def to_key(literal: str) -> str:
    """Swift literal -> catalog key: interpolations become format specifiers."""
    out, i, depth, start = "", 0, 0, 0
    while i < len(literal):
        if literal.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(literal) and depth:
                depth += literal[j] == "("
                depth -= literal[j] == ")"
                j += 1
            expr = literal[i + 2:j - 1]
            integer = re.search(r'\bcount\b|\.count\b|Count\b|\bn\b|index|version|revision|\bInt\(|days|minutes|seconds|total|number', expr) and "Format." not in expr
            out += "%lld" if integer else "%@"
            i = j
        elif literal.startswith('\\"', i):
            out += '"'; i += 2
        elif literal.startswith("\\n", i):
            out += "\n"; i += 2
        else:
            out += literal[i]; i += 1
    return out


def source_strings():
    found = {}
    files = glob.glob(os.path.join(ROOT, "App", "Sources", "**", "*.swift"), recursive=True)
    for pkg in ["ORIXAppUI"] + [os.path.basename(p) for p in glob.glob(os.path.join(ROOT, "Packages", "ORIXFeature*"))]:
        files += glob.glob(os.path.join(ROOT, "Packages", pkg, "Sources", pkg, "**", "*.swift"), recursive=True)
    for f in files:
        text = open(f, encoding="utf-8").read()
        for i, pattern in enumerate(PATTERNS):
            for m in pattern.finditer(text):
                lit = m.group(1)
                if i == 4 and not re.search(r'[a-z] [a-z]', lit):  # `return "…"`: sentences only
                    continue
                key = to_key(lit)
                if len(key) < 2 or not re.search(r'[A-Za-z]{2}', key):
                    continue
                if re.fullmatch(r'[a-z0-9_.\-/#:]+', key) or key.startswith(("http", "x-apple", "ai.spboucher")):
                    continue  # identifiers, symbols, paths
                found.setdefault(key, os.path.relpath(f, ROOT))
    return found


def translations():
    merged = {}
    for path in sorted(glob.glob(os.path.join(ROOT, "Packages", "*", "Localization", "fr.json")) + glob.glob(os.path.join(ROOT, "App", "Localization", "fr.json"))):
        for k, v in json.load(open(path, encoding="utf-8")).items():
            if isinstance(v, str) and v:
                merged.setdefault(k, v)
    return merged


def main():
    fr = translations()
    if "--missing" in sys.argv:
        missing = {k: f for k, f in source_strings().items() if k not in fr}
        for k, f in sorted(missing.items(), key=lambda kv: kv[1]):
            print(f"{f}\t{json.dumps(k, ensure_ascii=False)}")
        print(f"{len(missing)} string(s) without a French translation; {len(fr)} translated", file=sys.stderr)
        return 1 if missing else 0
    strings = {}
    for key, value in sorted(fr.items()):
        strings[key] = {"localizations": {"fr-CA": {"stringUnit": {"state": "translated", "value": value}}}}
    os.makedirs(os.path.dirname(CATALOG), exist_ok=True)
    with open(CATALOG, "w", encoding="utf-8") as out:
        json.dump({"sourceLanguage": "en", "strings": strings, "version": "1.0"}, out, ensure_ascii=False, indent=2, sort_keys=True)
        out.write("\n")
    print(f"wrote {os.path.relpath(CATALOG, ROOT)} with {len(strings)} French strings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
