#!/usr/bin/env bash
# =============================================================================
#                  SP BOUCHER | INFRASTRUCTURE & AUTOMATION
#             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
# =============================================================================
#
# Project          : ORIX OS Automation
# File             : Workflows/Samples/spreadsheet-validation/make-sample-workbooks.sh
# Module           : Workflows
# Repository       : https://git.spboucher.ai/orix-automation
# Created          : 2026-11-21
# Last Modified    : 2026-11-21
#
# Author           : Simon-Pierre Boucher
# Position         : Professor of Finance
# Institution      : Université du Québec en Outaouais (UQO)
# Organization     : SP Boucher
# Website          : https://spboucher.ai
# Git              : https://git.spboucher.ai
#
# Preferred Contact: support@spboucher.ai
# Technical Contact: dev@spboucher.ai
# Security/Admin   : admin@spboucher.ai
#
# Copyright (c) 2026
# Simon-Pierre Boucher
# All rights reserved where applicable. This file is governed by the
# applicable project license, copyright notices and relevant law.
# Existing third-party rights and notices remain unaffected.
#
# License          : Proprietary, all rights reserved (see license file)
# License File     : LICENSE
#
# Do not embed credentials, private keys, access tokens,
# certificates or confidential personal information.
#
# =============================================================================
# END OF SP BOUCHER SOURCE HEADER
# =============================================================================

# ORIX OS Automation
# File: Workflows/Samples/spreadsheet-validation/make-sample-workbooks.sh
# Description: Regenerates the two minimal .xlsx sample workbooks (one valid, one with broken rows) from hand-written SpreadsheetML parts, using only zip.
#
# Author: Simon-Pierre Boucher
# Contact: contact@spboucher.ai
#
# Usage: ./make-sample-workbooks.sh [output folder]     (default: the folder of this script)
set -euo pipefail
OUT="$(cd "${1:-$(dirname "$0")}" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# $1 = file name, $2 = sheetData XML (rows), $3 = shared strings (one per line)
make_workbook() {
  local dir="$WORK/$1.d"
  mkdir -p "$dir/_rels" "$dir/xl/_rels" "$dir/xl/worksheets"
  cat > "$dir/[Content_Types].xml" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/></Types>
XML
  cat > "$dir/_rels/.rels" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
XML
  cat > "$dir/xl/workbook.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Orders" sheetId="1" r:id="rId1"/></sheets></workbook>
XML
  cat > "$dir/xl/_rels/workbook.xml.rels" <<'XML'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/></Relationships>
XML
  {
    printf '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    while IFS= read -r s; do [ -n "$s" ] && printf '<si><t>%s</t></si>' "$s"; done <<< "$3"
    printf '</sst>\n'
  } > "$dir/xl/sharedStrings.xml"
  printf '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>%s</sheetData></worksheet>\n' "$2" > "$dir/xl/worksheets/sheet1.xml"
  rm -f "$OUT/$1"
  (cd "$dir" && zip -q -X -r "$OUT/$1" '[Content_Types].xml' _rels xl)
  echo "wrote $OUT/$1"
}

# Shared strings: 0 id, 1 name, 2 amount, 3 Alpha, 4 Beta, 5 Gamma, 6 Delta, 7 total
STRINGS=$'id\nname\namount\nAlpha\nBeta\nGamma\nDelta\ntotal'
HEADER='<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c></row>'

# data.xlsx: header + 4 complete rows (numbers, shared strings, one formula with its cached value).
make_workbook data.xlsx "$HEADER"'<row r="2"><c r="A2"><v>1001</v></c><c r="B2" t="s"><v>3</v></c><c r="C2"><v>120.5</v></c></row><row r="3"><c r="A3"><v>1002</v></c><c r="B3" t="s"><v>4</v></c><c r="C3"><v>75</v></c></row><row r="4"><c r="A4"><v>1003</v></c><c r="B4" t="s"><v>5</v></c><c r="C4"><v>310</v></c></row><row r="5"><c r="A5"><v>1004</v></c><c r="B5" t="s"><v>6</v></c><c r="C5"><f>C2+C3</f><v>195.5</v></c></row>' "$STRINGS"

# data-invalid.xlsx: the "amount" column is called "total", row 3 has no id, row 4 is empty.
make_workbook data-invalid.xlsx '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>7</v></c></row><row r="2"><c r="A2"><v>1001</v></c><c r="B2" t="s"><v>3</v></c><c r="C2"><v>120.5</v></c></row><row r="3"><c r="B3" t="s"><v>4</v></c><c r="C3"><v>75</v></c></row><row r="4"><c r="A4" t="inlineStr"><is><t></t></is></c></row><row r="5"><c r="A5"><v>1004</v></c><c r="B5" t="s"><v>6</v></c><c r="C5"><v>10</v></c></row>' "$STRINGS"
