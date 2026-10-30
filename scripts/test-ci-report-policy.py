"""Exercise the pinned report classifier with this project's resolved CI config."""
import importlib.util
import json
import os
import re
import sys
import unittest


class ReportPolicyTests(unittest.TestCase):
    def test_only_explicit_audit_assertions_are_warnings(self):
        cases = [
            ("QuietReaderUITests-Runner (35231) encountered an error",
             "The test runner failed to initialize for UI testing. (Underlying Error: Timed out while loading Accessibility.)",
             "test"),
            ("LibraryFlowTests/testZZAccessibilityAcrossLibraryAndReader()",
             "Test exceeded execution time allowance of 5 minutes", "test"),
            ("LibraryFlowTests/testZZAccessibilityAcrossLibraryAndReader()",
             "Failed to get matching snapshots: Timed out while evaluating UI query.", "test"),
            ("LibraryFlowTests/testZZAccessibilityAcrossLibraryAndReader()",
             "XCTAssertTrue failed", "test"),
            ("LibraryFlowTests/testZZAccessibilityAcrossLibraryAndReader()",
             "failed - Accessibility audit（书库）：Contrast failed — iBooks", "accessibility"),
            ("LibraryFlowTests/testZZAccessibilityAcrossLibraryAndReader()",
             "failed - Accessibility audit（阅读页）：Dynamic Type font sizes are unsupported", "accessibility"),
            ("LibraryFlowTests/testEPUBImportsRendersPublisherContentAndResumesChapter()",
             "XCTAssertTrue failed", "test"),
            ("LayoutTests/testCoverSnapshot()", "Snapshot does not match reference.", "snapshot"),
        ]
        for name, reason, expected in cases:
            with self.subTest(test=name, reason=reason):
                failure = {"testIdentifierString": name, "failureText": reason}
                self.assertEqual(report.classify(failure, pattern), expected)


if __name__ == "__main__":
    spec = importlib.util.spec_from_file_location("project_report", os.path.join(os.path.dirname(__file__), "ci-test-report.py"))
    adapter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(adapter)
    report = adapter.load_report(sys.argv[1])
    config = json.loads(os.environ["CONFIG"])
    pattern = re.compile(config["build_test"]["accessibility_test_pattern"])
    unittest.main(argv=[sys.argv[0]], verbosity=2)
