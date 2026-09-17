import copy
import json
import os
import subprocess
import unittest
from unittest.mock import patch

import coverage_solc as adapter


class CoverageCompilerTests(unittest.TestCase):
    def setUp(self):
        self.payload = {
            "language": "Solidity",
            "sources": {"src/Foo.sol": {"content": "pragma solidity ^0.8.30;\ncontract Foo {}"}},
            "settings": {
                "viaIR": True,
                "optimizer": {"enabled": True, "runs": 123, "details": {"yul": True}},
                "evmVersion": "osaka",
                "libraries": {"src/Lib.sol": {"Lib": "0x1111111111111111111111111111111111111111"}},
                "metadata": {"bytecodeHash": "none"},
                "outputSelection": {"*": {"*": ["abi", "evm.bytecode", "evm.deployedBytecode"], "": ["ast"]}},
            },
        }
        self.version = subprocess.CompletedProcess([], 0, b"Version: 0.8.33+commit.64118f21.Linux.g++", b"")

    def test_only_optimizer_changes_and_sources_remain_exact(self):
        expected = copy.deepcopy(self.payload)
        expected["settings"]["optimizer"] = {"enabled": False, "runs": 200}
        self.assertEqual(json.loads(adapter.compiler_input(json.dumps(self.payload))), expected)

    def test_rejects_invalid_json_and_wrong_language_or_ir_mode(self):
        with self.assertRaises(ValueError):
            adapter.compiler_input("not JSON")
        for key, value in [("language", "Vyper"), ("settings", {"viaIR": False})]:
            invalid = copy.deepcopy(self.payload)
            invalid[key] = value
            with self.assertRaises(ValueError):
                adapter.compiler_input(json.dumps(invalid))

    @patch.dict(os.environ, {"POA_COVERAGE_SOLC": "/compiler path/solc"})
    @patch("coverage_solc.subprocess.run")
    def test_argument_boundaries_and_error_exit_are_preserved(self, execute):
        execute.side_effect = [self.version, subprocess.CompletedProcess([], 17)]
        self.assertEqual(adapter.run(["--standard-json", "--base-path", "/path with spaces"], json.dumps(self.payload)), 17)
        args, kwargs = execute.call_args
        self.assertEqual(args[0], ["/compiler path/solc", "--standard-json", "--base-path", "/path with spaces"])
        self.assertNotIn("stdout", kwargs)
        self.assertNotIn("stderr", kwargs)
        self.assertNotIn("shell", kwargs)
        self.assertEqual(json.loads(kwargs["input"])["sources"], self.payload["sources"])

    @patch.dict(os.environ, {"POA_COVERAGE_SOLC": "/compiler/solc"})
    @patch("coverage_solc.subprocess.run")
    def test_version_probe_has_no_stdin_rewrite(self, execute):
        execute.side_effect = [self.version, subprocess.CompletedProcess([], 0)]
        self.assertEqual(adapter.run(["--version"]), 0)
        execute.assert_called_with(["/compiler/solc", "--version"], check=False)

    @patch.dict(os.environ, {"POA_COVERAGE_SOLC": "/compiler/solc"})
    @patch("coverage_solc.subprocess.run")
    def test_rejects_compiler_drift_before_compilation(self, execute):
        execute.return_value = subprocess.CompletedProcess([], 0, b"Version: 0.8.34+commit.example", b"")
        with self.assertRaises(ValueError):
            adapter.run(["--standard-json"], json.dumps(self.payload))
        self.assertEqual(execute.call_count, 1)

    @patch.dict(os.environ, {}, clear=True)
    def test_rejects_missing_compiler_and_unsupported_invocation(self):
        with self.assertRaisesRegex(ValueError, "POA_COVERAGE_SOLC"):
            adapter.run(["--version"])
        with self.assertRaisesRegex(ValueError, "only supports"):
            adapter.run(["--help"])

    @patch.dict(os.environ, {"POA_COVERAGE_SOLC": "/compiler/solc"})
    @patch("coverage_solc.subprocess.run")
    def test_failed_version_probe_preserves_exit_and_stderr(self, execute):
        execute.return_value = subprocess.CompletedProcess([], 42)
        self.assertEqual(adapter.run(["--version"]), 42)
        self.assertNotIn("stderr", execute.call_args.kwargs)
        self.assertEqual(execute.call_count, 1)


if __name__ == "__main__":
    unittest.main()
