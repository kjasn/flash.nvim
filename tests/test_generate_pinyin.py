"""Installer safety checks; run with python3 -m unittest discover -s tests -p 'test_*.py'."""

import contextlib
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location(
    "generate_pinyin", Path(__file__).resolve().parents[1] / "scripts/generate_pinyin.py"
)
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class GeneratePinyinTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "pinyin.txt"
        self.source.write_text("U+597D: hǎo,hào # 好\n", encoding="utf-8")
        self.output = self.root / "data.lua"
        checksum = hashlib.sha256(self.source.read_bytes()).hexdigest()
        self.patch = mock.patch.object(generator, "SOURCE_SHA256", checksum)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def generate(self, *extra):
        with contextlib.redirect_stdout(io.StringIO()):
            generator.main(["--output", str(self.output), *extra])

    def test_current_dictionary_skips_network_and_force_fetches(self):
        self.generate("--source", str(self.source))
        with mock.patch.object(generator.urllib.request, "urlopen") as request:
            self.generate()
            request.assert_not_called()
            request.return_value.__enter__.return_value.read.return_value = self.source.read_bytes()
            self.generate("--force")
            request.assert_called_once()

    def test_modified_content_or_metadata_requires_regeneration(self):
        self.generate("--source", str(self.source))
        self.assertTrue(generator.is_current(self.output))
        original = self.output.read_bytes()
        self.output.write_bytes(original.replace(b'["hao"]', b'["wrong"]'))
        self.assertFalse(generator.is_current(self.output))
        self.generate("--source", str(self.source))
        self.assertEqual(self.output.read_bytes(), original)
        with mock.patch.object(generator, "FORMAT_VERSION", generator.FORMAT_VERSION + 1):
            self.assertFalse(generator.is_current(self.output))
        with mock.patch.object(generator, "REVISION", "different"):
            self.assertFalse(generator.is_current(self.output))
        with mock.patch.object(generator, "SOURCE_SHA256", "different"):
            self.assertFalse(generator.is_current(self.output))

    def test_source_checksum_mismatch_preserves_existing_dictionary(self):
        self.output.write_bytes(b"previous dictionary")
        self.source.write_bytes(b"unexpected source")
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            self.generate("--source", str(self.source))
        self.assertEqual(self.output.read_bytes(), b"previous dictionary")
        self.assertEqual(sorted(path.name for path in self.root.iterdir()), ["data.lua", "pinyin.txt"])

    def test_replace_failure_preserves_dictionary_and_removes_temporary_file(self):
        self.output.write_bytes(b"previous dictionary")
        with mock.patch.object(generator.os, "replace", side_effect=OSError("replace failed")):
            with self.assertRaisesRegex(OSError, "replace failed"):
                self.generate("--source", str(self.source))
        self.assertEqual(self.output.read_bytes(), b"previous dictionary")
        self.assertEqual(sorted(path.name for path in self.root.iterdir()), ["data.lua", "pinyin.txt"])


if __name__ == "__main__":
    unittest.main()
