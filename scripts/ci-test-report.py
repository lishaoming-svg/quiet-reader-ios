"""Use the pinned central report, treating XCTest infrastructure errors as blocking."""
import importlib.util
import sys


def load_report(path):
    spec = importlib.util.spec_from_file_location("pinned_xcresult_report", path)
    report = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(report)
    original_classify = report.classify

    def classify(failure, pattern):
        reason = (failure.get("failureText") or "").lower()
        infrastructure_errors = (
            "test runner failed to initialize",
            "failed to initialize for ui testing",
            "timed out while loading accessibility",
            "failed to get matching snapshots",
            "test exceeded execution time allowance",
            "failed to terminate",
        )
        if any(error in reason for error in infrastructure_errors):
            return "test"
        return original_classify(failure, pattern)

    report.classify = classify
    return report


if __name__ == "__main__":
    sys.exit(load_report(sys.argv[1]).main())
