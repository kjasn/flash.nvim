# Pinyin dictionary attribution

`lua/flash/pinyin/data.lua` is derived from [mozillazg/pinyin-data](https://github.com/mozillazg/pinyin-data),
version 0.15.0, revision `9d05c9e29cb6a7e5c79f2f5279f5c1014246a19a`.
The upstream data is distributed under the MIT license; its copyright and
license text are preserved in [pinyin-data-LICENSE](pinyin-data-LICENSE).

Source: <https://raw.githubusercontent.com/mozillazg/pinyin-data/9d05c9e29cb6a7e5c79f2f5279f5c1014246a19a/pinyin.txt>

Source SHA-256: `90c11bd680ccfe7f2617a6e25abdb1fb87b5540df3e6f011ca50aaf3c7263a89`

## Generating the dictionary

The generated file is not tracked in Git. Generation requires Python 3.9+ and
network access on the first build or when dictionary/generator versions change.
From the **flash.nvim plugin directory**, run:

```sh
python3 scripts/generate_pinyin.py
```

This command works with any plugin manager. After generation, enable
`search.pinyin` in your existing configuration and restart Neovim. For an optional
lazy.nvim build hook, see [installation instructions](../README.md#chinese-pinyin-jumps).

A current file is reused without downloading only when its generator format,
source revision, source SHA-256 and content checksum all match. Use `--force` to
regenerate anyway. For offline generation, supply a previously downloaded source
using `--source /path/to/pinyin.txt`. Downloaded and local sources are verified
against the pinned source hash before generation.

Generation uses a temporary file in the destination directory and atomically
replaces the output on success. Failures exit nonzero and preserve any previous
file. Without a usable dictionary, pinyin falls back to literal matching with a
one-time warning; repair the build and restart Neovim. No automatic runtime
download takes place.
The generator removes diacritics, maps `ü` to `v`, and deduplicates identical
readings for each character. All listed readings are retained after this
normalization; none are excluded. Unusual readings such as `m`, `ng`, and `ê`
(normalized to `e`) are included. Characters are grouped by syllable and sorted
by Unicode code point for deterministic output.

The generated table contains 44,440 characters and 426 normalized syllables.
Coverage follows the upstream dictionary, including simplified, traditional,
and supplementary-plane characters; it does not imply coverage of all Unicode
Han characters. Python and network access are needed to generate or update the dictionary,
not during jumps. Users who do not enable pinyin have no additional dependencies.

## Development checks

The Lua matching tests use a small in-memory dictionary fixture, so a clean
checkout can run them without generating data. For the install safety tests:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_generate_pinyin.py'
```

After changing normalization or output formatting, increment `FORMAT_VERSION`
in the generator so previously generated files are rebuilt. Changes to the
pinned source must update both `REVISION` and `SOURCE_SHA256`. Keep this license
and attribution alongside the generator even though the data is untracked.
