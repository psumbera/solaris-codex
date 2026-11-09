#!/usr/bin/env python3
"""Compile V8 byte reads with current and legacy Solaris int8_t typedefs."""

import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent
VERSION = re.search(r"^V8_VERSION=([0-9.]+)$",
                    (ROOT / "versions.sh").read_text(), re.M).group(1)
SOURCE = Path(os.environ.get("V8_SOURCE", ROOT / "build/src" / ("v8-" + VERSION)))
COMPILER = shlex.split(os.environ.get("CXX") or "g++")
PROGRAM = r"""
#include <cstdint>
#include <cstring>
#include <type_traits>
#include "src/base/memory.h"

static_assert(std::is_same_v<int8_t, char> == bool(EXPECT_LEGACY));

template <typename T>
concept CanRead = requires(const T* pointer) {
  v8::base::ReadUnalignedValue<uint64_t>(pointer);
};
static_assert(CanRead<char> && CanRead<int8_t> && CanRead<uint8_t>);
static_assert(!CanRead<uint16_t>);

int main() {
  constexpr uint64_t expected = UINT64_C(0x0123456789abcdef);
  char bytes[sizeof(expected) + 1] = {};
  std::memcpy(bytes + 1, &expected, sizeof(expected));
  const auto address = reinterpret_cast<v8::base::Address>(bytes + 1);
  return v8::base::ReadUnalignedValue<uint64_t>(bytes + 1) != expected ||
         v8::base::ReadUnalignedValue<uint64_t>(
             reinterpret_cast<const int8_t*>(bytes + 1)) != expected ||
         v8::base::ReadUnalignedValue<uint64_t>(
             reinterpret_cast<const uint8_t*>(bytes + 1)) != expected ||
         v8::base::ReadUnalignedValue<uint64_t>(address) != expected;
}
"""


@unittest.skipUnless((SOURCE / "v8/src/base/memory.h").is_file(),
                     "requires the prepared V8 source tree")
@unittest.skipUnless(COMPILER and shutil.which(COMPILER[0]), "requires a C++ compiler")
class V8HeaderTests(unittest.TestCase):
    def compile_and_run(self, legacy, unpatched=False):
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as temporary:
            root = Path(temporary)
            source = root / "memory.cc"
            source.write_text(PROGRAM)
            binary = root / "memory"
            if unpatched:
                header = root / "src/base/memory.h"
                header.parent.mkdir(parents=True)
                text = (SOURCE / "v8/src/base/memory.h").read_text()
                new = (
                    "template <typename V, typename Byte>\n"
                    "  requires(std::is_same_v<Byte, int8_t> && !std::is_same_v<Byte, char>)\n"
                    "static inline V ReadUnalignedValue(const Byte p[sizeof(V)]) {"
                )
                old = (
                    "template <typename V>\n"
                    "static inline V ReadUnalignedValue(const int8_t p[sizeof(V)]) {"
                )
                self.assertIn(new, text, "requires the Solaris memory.h patch")
                header.write_text(text.replace(new, old, 1))
            command = [
                *COMPILER, "-m64", "-std=c++23", "-DNDEBUG",
                "-D_LEGACY_INT8_T=" + str(legacy),
                "-DEXPECT_LEGACY=" + str(legacy),
                "-I" + str(root),
                "-I" + str(SOURCE / "v8"),
                "-I" + str(SOURCE / "v8/include"),
                "-I" + str(SOURCE / "third_party/abseil-cpp"),
                str(source), "-o", str(binary),
            ]
            result = subprocess.run(command, capture_output=True, text=True,
                                    timeout=60)
            if unpatched:
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("redefinition", result.stderr)
                return
            self.assertEqual(result.returncode, 0, result.stderr)
            subprocess.run([str(binary)], check=True, timeout=10)

    def test_distinct_signed_char(self):
        # Probe the actual compiler/sysroot: older headers may ignore the switch.
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as temporary:
            probe = Path(temporary) / "typedef-probe"
            result = subprocess.run(
                [*COMPILER, "-m64", "-std=c++23", "-D_LEGACY_INT8_T=0",
                 "-x", "c++", "-", "-o", str(probe)],
                input="#include <cstdint>\n#include <type_traits>\n"
                      "int main() { return std::is_same_v<int8_t, char>; }\n",
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            alias = subprocess.run([str(probe)], timeout=10).returncode
            self.assertIn(alias, (0, 1))
            if alias:
                self.skipTest("older Solaris headers cannot select signed-char int8_t")
        self.compile_and_run(0)

    def test_legacy_char_alias(self):
        self.compile_and_run(1)

    def test_unpatched_legacy_char_alias_reproduces_ci_failure(self):
        self.compile_and_run(1, unpatched=True)


if __name__ == "__main__":
    unittest.main()
