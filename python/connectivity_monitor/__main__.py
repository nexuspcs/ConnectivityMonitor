"""Entry point for `python -m connectivity_monitor`."""

import argparse
import sys

from .config import load_config, interactive_setup, headless_config, ensure_dirs
from .monitor import run_monitor


def main():
    parser = argparse.ArgumentParser(
        description="Connectivity Monitor v4.0 — Cross-Platform Python Edition",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python -m connectivity_monitor                          # Interactive setup
  python -m connectivity_monitor --headless               # Use saved config
  python -m connectivity_monitor --headless --web-port 9090
  python -m connectivity_monitor --targets 1.1.1.1,8.8.8.8
        """,
    )
    parser.add_argument(
        "--headless", action="store_true",
        help="Run without interactive prompts (uses saved or default config)",
    )
    parser.add_argument(
        "--targets", type=str, default=None,
        help="Comma-separated ping targets (e.g. 1.1.1.1,8.8.8.8)",
    )
    parser.add_argument(
        "--poll", type=int, default=None,
        help="Poll interval in seconds (default: 2)",
    )
    parser.add_argument(
        "--threshold", type=int, default=None,
        help="Consecutive failures to declare an outage (default: 4)",
    )
    parser.add_argument(
        "--web-port", type=int, default=None, dest="web_port",
        help="Web dashboard port (default: 8080)",
    )

    args = parser.parse_args()

    ensure_dirs()

    if args.headless:
        cfg = headless_config(args)
        cfg["headless"] = True
    else:
        saved = load_config()
        cfg = interactive_setup(saved)
        cfg["headless"] = False

    run_monitor(cfg)


if __name__ == "__main__":
    main()
