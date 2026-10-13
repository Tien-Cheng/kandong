#!/usr/bin/env bash
# Downloads the offline dictionary data and the Reading's typeface into Data/ (not committed).
#   - CC-CEDICT (CC BY-SA 4.0, https://www.mdbg.net/chinese/dictionary?page=cc-cedict)
#   - HSK 3.0 word levels + frequency ranks (MIT, https://github.com/drkameleon/complete-hsk-vocabulary)
#   - LXGW WenKai Lite (SIL OFL 1.1, https://github.com/lxgw/LxgwWenKai-Lite)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Data
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [[ ! -s Data/cedict_ts.u8 || "${1:-}" == "--force" ]]; then
  echo "Fetching CC-CEDICT…"
  curl -fsSL -o "$tmp/cedict.gz" https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz
  gunzip -c "$tmp/cedict.gz" > Data/cedict_ts.u8
fi

if [[ ! -s Data/hsk.tsv || "${1:-}" == "--force" ]]; then
  echo "Fetching HSK vocabulary…"
  curl -fsSL -o "$tmp/hsk.json" https://raw.githubusercontent.com/drkameleon/complete-hsk-vocabulary/main/complete.min.json
  # word <TAB> HSK 3.0 level (1-6, 7 = band 7-9) <TAB> frequency rank
  python3 -I - "$tmp/hsk.json" > Data/hsk.tsv <<'PY'
import json, sys
for w in json.load(open(sys.argv[1], encoding="utf-8")):
    levels = [int(l[1:]) for l in w.get("l", []) if l.startswith("n")]
    if not levels:
        continue
    print(f"{w['s']}\t{min(levels)}\t{w.get('q', 999999)}")
PY
fi
font=LXGWWenKaiLite-Regular.ttf
font_sha256=140c99ba4e28e817cec49bf82a0c5fcdc4fe633fb9dfda16d0ee8d59a8545f15
if [[ ! -s "Data/$font" || "${1:-}" == "--force" ]]; then
  echo "Fetching LXGW WenKai Lite…"
  curl -fsSL -o "$tmp/$font" "https://github.com/lxgw/LxgwWenKai-Lite/releases/download/v1.522/$font"
  echo "$font_sha256  $tmp/$font" | shasum -a 256 -c --quiet
  mv "$tmp/$font" "Data/$font"
fi

echo "Data ready: $(wc -l < Data/cedict_ts.u8) CEDICT lines, $(wc -l < Data/hsk.tsv) HSK words"
