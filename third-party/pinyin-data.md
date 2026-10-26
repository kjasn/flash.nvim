# Pinyin dictionary attribution

`lua/flash/pinyin/data.lua` is derived from [mozillazg/pinyin-data](https://github.com/mozillazg/pinyin-data),
version 0.15.0, revision `9d05c9e29cb6a7e5c79f2f5279f5c1014246a19a`.
The upstream data is distributed under the MIT license; its copyright and
license text are preserved in [pinyin-data-LICENSE](pinyin-data-LICENSE).

Source: <https://raw.githubusercontent.com/mozillazg/pinyin-data/9d05c9e29cb6a7e5c79f2f5279f5c1014246a19a/pinyin.txt>

Source SHA-256: `90c11bd680ccfe7f2617a6e25abdb1fb87b5540df3e6f011ca50aaf3c7263a89`

Regenerate from the repository root using Python 3.9 or newer:

```sh
python3 scripts/generate_pinyin.py
```

For offline regeneration, supply a previously downloaded source using
`--source /path/to/pinyin.txt`. Both paths verify the pinned source hash.
The generator removes diacritics, maps `ü` to `v`, and deduplicates identical
readings for each character. All listed readings are retained after this
normalization; none are excluded. Unusual readings such as `m`, `ng`, and `ê`
(normalized to `e`) are included. Characters are grouped by syllable and sorted
by Unicode code point for deterministic output.

The bundled table contains 44,440 characters and 426 normalized syllables.
Coverage follows the upstream dictionary, including simplified, traditional,
and supplementary-plane characters; it does not imply coverage of all Unicode
Han characters. Python and network access are only needed when maintaining the
generated data, not when using Flash.
