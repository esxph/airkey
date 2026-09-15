#!/usr/bin/env python3
"""Rebuild bundled dictionaries from a pinned, attributed FrequencyWords snapshot."""
from pathlib import Path
import re
import unicodedata
import urllib.request

REVISION = '525f9b560de45753a5ea01069454e72e9aa541c6'
ROOT = Path(__file__).resolve().parents[1] / 'Sources/airKey/Resources'
for language in ('en', 'es'):
    url = f'https://raw.githubusercontent.com/hermitdave/FrequencyWords/{REVISION}/content/2018/{language}/{language}_50k.txt'
    source = urllib.request.urlopen(url, timeout=30).read().decode('utf-8')
    words = []
    seen = set()
    for line in source.splitlines():
        word, count = line.rsplit(' ', 1)
        word = unicodedata.normalize('NFC', word.lower())
        if not re.fullmatch(r"[a-záéíóúüñ]+(?:'[a-z]+)?", word) or not 1 <= len(word) <= 24 or word in seen:
            continue
        seen.add(word)
        words.append(f'{word} {count}')
    (ROOT / f'{language}.txt').write_text('\n'.join(words) + '\n', encoding='utf-8')
    print(f'{language}: {len(words)} words')
