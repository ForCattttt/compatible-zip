#!/usr/bin/env python3
"""Exercise the built macOS app through its public CLI, using synthetic data only.

Run after building the app:
    python3 tests/smoke.py build/兼容压缩.app/Contents/MacOS/CompatZip

The suite uses only the Python standard library. ZIP payloads are read in memory;
untrusted archive member paths are never extracted to the filesystem.
"""

import argparse
import hashlib
import io
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
import unicodedata
import unittest
import warnings
import zipfile


EXECUTABLE = None
UTF8_FLAG = 1 << 11


def digest(data):
    return hashlib.sha256(data).hexdigest()


def normalized(name):
    # macOS filesystems may return decomposed Unicode spellings.
    return unicodedata.normalize("NFC", name)


def tree_snapshot(root):
    """Record names, node types, link targets, and file bytes without following links."""
    result = {}

    def visit(path, relative):
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            result[relative] = ("link", os.readlink(path))
        elif stat.S_ISDIR(mode):
            result[relative] = ("directory",)
            for child in sorted(path.iterdir()):
                visit(child, relative + "/" + child.name)
        else:
            result[relative] = ("file", digest(path.read_bytes()))

    visit(root, ".")
    return result


def zip_bytes(entries):
    """Create a small ordinary ZIP; entries are (member name, payload) pairs."""
    stream = io.BytesIO()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)  # Deliberate duplicate fixtures.
        with zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED) as archive:
            for name, payload in entries:
                archive.writestr(name, payload)
    return stream.getvalue()


def clear_utf8_flags(data):
    """Make a legacy fixture: UTF-8 names present, but bit 11 omitted in both headers.

    Use the documented ZIP record layout rather than relying on zipfile to write
    deliberately incorrect encoding metadata. Fixtures are non-ZIP64 and have no
    archive comment, so their end-of-central-directory record is the last 22 bytes.
    """
    result = bytearray(data)
    eocd = len(result) - 22
    assert result[eocd:eocd + 4] == b"PK\x05\x06"
    count = struct.unpack_from("<H", result, eocd + 10)[0]
    cursor = struct.unpack_from("<I", result, eocd + 16)[0]
    for _ in range(count):
        assert result[cursor:cursor + 4] == b"PK\x01\x02"
        local = struct.unpack_from("<I", result, cursor + 42)[0]
        assert result[local:local + 4] == b"PK\x03\x04"
        for offset in (cursor + 8, local + 6):
            flags = struct.unpack_from("<H", result, offset)[0]
            struct.pack_into("<H", result, offset, flags & ~UTF8_FLAG)
        name_length, extra_length, comment_length = struct.unpack_from(
            "<HHH", result, cursor + 28
        )
        cursor += 46 + name_length + extra_length + comment_length
    return bytes(result)


class CompatibilitySmokeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="compat-zip-smoke-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / "result.zip"

    def write(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def invoke(self, inputs, output=None):
        command = [str(EXECUTABLE), "--cli"]
        if output is not None:
            command.extend(["--output", str(output)])
        command.extend(str(path) for path in inputs)
        return subprocess.run(
            command, cwd=self.root, capture_output=True, text=True,
            encoding="utf-8", errors="replace", timeout=60, check=False,
        )

    def succeed(self, inputs, output=None):
        destination = self.output if output is None else output
        before = {str(path): tree_snapshot(path) for path in inputs}
        result = self.invoke(inputs, destination)
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        self.assertEqual(result.stderr, "")
        self.assertEqual(result.stdout.strip(), str(destination))
        self.assertTrue(destination.is_file(), "Success must create the reported ZIP")
        for path in inputs:
            self.assertEqual(tree_snapshot(path), before[str(path)], "Source changed")
        return destination

    def reject(self, inputs, output=None):
        destination = self.output if output is None else output
        before = tree_snapshot(self.root)
        result = self.invoke(inputs, destination)
        self.assertNotEqual(result.returncode, 0, "Unsafe input was accepted")
        self.assertEqual(result.stdout, "", "Failure must not report an output")
        self.assertTrue(result.stderr.strip(), "Failure should explain why it failed")
        self.assertEqual(tree_snapshot(self.root), before, "Failure changed source/output files")

    def assert_archive(self, data, expected_files, expected_directories=()):
        if isinstance(data, Path):
            data = data.read_bytes()
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            self.assertIsNone(archive.testzip(), "Payload CRC check failed")
            infos = archive.infolist()
            names = [normalized(info.filename) for info in infos]
            self.assertEqual(len(names), len(set(names)), "Duplicate ZIP member names")
            for info in infos:
                self.assertFalse(info.filename.startswith("./"), info.filename)
                # ASCII is unambiguous without bit 11; non-ASCII names or entry
                # comments need the flag in both the central and local records.
                needs_flag = any(byte >= 128 for byte in info.filename.encode("utf-8") + info.comment)
                if needs_flag:
                    self.assertTrue(info.flag_bits & UTF8_FLAG, "Missing central UTF-8 flag")
                    local_flags = struct.unpack_from("<H", data, info.header_offset + 6)[0]
                    self.assertTrue(local_flags & UTF8_FLAG, "Missing local UTF-8 flag")
            actual = {
                normalized(info.filename): digest(archive.read(info))
                for info in infos if not info.is_dir()
            }
            self.assertEqual(actual, {name: digest(value) for name, value in expected_files.items()})
            self.assertTrue(set(expected_directories).issubset(set(names)))

    def test_chinese_file_and_binary_payload(self):
        payload = "中文正文\n第二行\n".encode() + bytes(range(256))
        source = self.write("生产日报 中文.txt", payload)
        self.assert_archive(self.succeed([source]), {source.name: payload})

    def test_pure_ascii_file_is_valid_without_a_required_utf8_flag(self):
        source = self.write("plain.txt", b"plain ASCII content\n")
        self.assert_archive(self.succeed([source]), {source.name: source.read_bytes()})

    def test_chinese_tree_excludes_macos_metadata_and_keeps_empty_subdirectory(self):
        folder = self.root / "中文资料"
        first = self.write("中文资料/一车间/运行记录.txt", "完整原始记录".encode())
        second = self.write("中文资料/图片.bin", bytes(range(128)))
        (folder / "空子目录").mkdir()
        self.write("中文资料/.DS_Store", b"synthetic metadata")
        self.write("中文资料/._图片.bin", b"synthetic resource fork")
        self.write("中文资料/一车间/._运行记录.txt", b"synthetic metadata")
        self.write("中文资料/__MACOSX/不可发送.txt", b"synthetic metadata")
        self.assert_archive(
            self.succeed([folder]),
            {"中文资料/一车间/运行记录.txt": first.read_bytes(), "中文资料/图片.bin": second.read_bytes()},
            ["中文资料/空子目录/"],
        )

    def test_option_like_names_and_multiple_input_files(self):
        first = self.write("-中文.txt", b"first")
        second = self.write("@archive.txt", b"second")
        self.assert_archive(self.succeed([first, second]), {first.name: b"first", second.name: b"second"})

    def test_repairs_legacy_utf8_flags_without_changing_payload_or_other_bytes(self):
        original = zip_bytes([("旧资料/中文.txt", "中文内容".encode()), ("ascii.txt", b"ascii")])
        legacy = clear_utf8_flags(original)
        source = self.write("旧中文.zip", legacy)
        repaired = self.succeed([source]).read_bytes()
        self.assert_archive(repaired, {"旧资料/中文.txt": "中文内容".encode(), "ascii.txt": b"ascii"})
        self.assertEqual(clear_utf8_flags(repaired), legacy, "Flag-only repair rewrote other ZIP bytes")

    def test_repairs_utf8_entry_comment_with_an_ascii_filename(self):
        comment = "保留完整中文条目注释".encode("utf-8")
        stream = io.BytesIO()
        entry = zipfile.ZipInfo("commented.txt")
        entry.comment = comment
        entry.compress_type = zipfile.ZIP_DEFLATED
        with zipfile.ZipFile(stream, "w") as archive:
            archive.writestr(entry, b"unchanged payload")
        legacy = clear_utf8_flags(stream.getvalue())
        source = self.write("comment.zip", legacy)
        repaired = self.succeed([source]).read_bytes()
        self.assert_archive(repaired, {"commented.txt": b"unchanged payload"})
        with zipfile.ZipFile(io.BytesIO(repaired)) as archive:
            self.assertEqual(archive.getinfo("commented.txt").comment, comment)
        self.assertEqual(clear_utf8_flags(repaired), legacy, "Comment repair rewrote other ZIP bytes")

    def test_repairs_leading_dot_slash_paths(self):
        source = self.write("旧路径.zip", zip_bytes([("./文件夹/中文.txt", b"preserve me")]))
        self.assert_archive(self.succeed([source]), {"文件夹/中文.txt": b"preserve me"})

    def test_repairs_nested_zip_in_a_folder_without_editing_the_source(self):
        legacy = clear_utf8_flags(zip_bytes([("./旧目录/中文.txt", "嵌套正文".encode())]))
        source = self.write("待发送/内层.zip", legacy)
        note = self.write("待发送/说明.txt", b"outer content")
        output = self.succeed([source.parent])
        with zipfile.ZipFile(output) as archive:
            inner = archive.read("待发送/内层.zip")
            self.assertEqual(digest(archive.read("待发送/说明.txt")), digest(note.read_bytes()))
        self.assertNotEqual(inner, legacy)
        self.assert_archive(inner, {"旧目录/中文.txt": "嵌套正文".encode()})

    def test_default_output_names_never_overwrite(self):
        source = self.write("报告.txt", b"source content")
        original_hash = digest(source.read_bytes())
        outputs = []
        for _ in range(2):
            existing = {path: path.read_bytes() for path in outputs}
            result = self.invoke([source])
            self.assertEqual(result.returncode, 0, result.stderr)
            output = Path(result.stdout.strip())
            self.assertTrue(output.is_file())
            self.assertEqual(output.parent, self.root)
            self.assertNotIn(output, outputs)
            for old, content in existing.items():
                self.assertEqual(old.read_bytes(), content, "Existing output overwritten")
            self.assert_archive(output, {source.name: b"source content"})
            outputs.append(output)
        self.assertEqual(digest(source.read_bytes()), original_hash)
        self.reject([source], outputs[0])

    def test_rejects_windows_reserved_and_invalid_names_on_disk(self):
        for name in ("CON.txt", "aux", "COM1.log", "LPT¹.txt", "bad?.txt", "trailing."):
            with self.subTest(name=name):
                source = self.write(name, b"do not alter")
                self.reject([source])

    def test_rejects_windows_name_conflicts_between_input_roots(self):
        first = self.write("one/同名.txt", b"one")
        second = self.write("two/同名.txt", b"two")
        self.reject([first, second])

    def test_rejects_unsafe_member_names_and_collisions_in_existing_zip(self):
        cases = (
            [("CON.txt", b"reserved")],
            [("A.txt", b"first"), ("a.txt", b"second")],
            [("same.txt", b"first"), ("same.txt", b"second")],
            [("node", b"file"), ("node/child.txt", b"child")],
            [("../escape.txt", b"escape")],
            [("/absolute.txt", b"absolute")],
            [("C:\\escape.txt", b"drive")],
        )
        for index, entries in enumerate(cases):
            with self.subTest(entries=[name for name, _ in entries]):
                source = self.write("unsafe-%d.zip" % index, zip_bytes(entries))
                self.reject([source])

    def test_rejects_symbolic_links_in_inputs(self):
        target = self.write("original.txt", b"real target")
        link = self.root / "linked.txt"
        link.symlink_to(target)
        self.reject([link])
        folder = self.root / "含链接"
        folder.mkdir()
        (folder / "linked.txt").symlink_to(target)
        self.reject([folder])

    def test_rejects_empty_folders_and_empty_archives(self):
        folder = self.root / "空文件夹"
        folder.mkdir()
        self.reject([folder])
        source = self.write("empty.zip", zip_bytes([]))
        self.reject([source])

    def test_rejects_corrupt_zip_and_damaged_payload(self):
        truncated = self.write("损坏.zip", b"PK\x03\x04incomplete synthetic ZIP")
        self.reject([truncated])
        data = bytearray(zip_bytes([("document.txt", b"readable fixture payload")]))
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            info = archive.infolist()[0]
            name_length, extra_length = struct.unpack_from("<HH", data, info.header_offset + 26)
            content_start = info.header_offset + 30 + name_length + extra_length
        data[content_start] ^= 0xFF
        damaged = self.write("内容损坏.zip", data)
        self.reject([damaged])

    def test_rejects_corrupt_or_traversing_nested_zip(self):
        folder = self.root / "嵌套检查"
        invalid = self.write("嵌套检查/broken.zip", b"synthetic incomplete ZIP")
        self.reject([folder])
        invalid.unlink()
        self.write("嵌套检查/unsafe.zip", zip_bytes([("../outside.txt", b"no extraction")]))
        self.reject([folder])

    def test_rejects_output_inside_the_source_folder(self):
        source = self.write("资料/文档.txt", b"unchanged")
        self.reject([source.parent], source.parent / "output.zip")


def main():
    global EXECUTABLE
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("executable", type=Path, help="Built CompatZip executable inside the .app bundle")
    arguments = parser.parse_args()
    EXECUTABLE = arguments.executable.expanduser().resolve()
    if not EXECUTABLE.is_file() or not os.access(EXECUTABLE, os.X_OK):
        parser.error("Executable is missing or is not executable: %s" % EXECUTABLE)
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(CompatibilitySmokeTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
