# ============================================================================
#  CONNECTIVITY MONITOR v4.0 (Cross-Platform Python Edition)
#  Matching feature-parity with ConnectivityDropMonitor.ps1
#  Works on Linux, macOS, Raspberry Pi — Python 3.6+ stdlib only
#  JAMES COATES and Claude Opus 4.6 (Graciously hosted with GitHub CoPilot)
# ============================================================================
"""
Connectivity Monitor — Real-time network monitoring with latency tracking

A cross-platform network monitoring tool that continuously pings targets,
tracks latency and packet loss, detects outages, and provides live analytics
through a web dashboard.

Key Features:
- Continuous ICMP ping monitoring with configurable targets
- Live web dashboard with auto-refresh (5 tabs: Overview, Graph, Drops, Targets, Heatmap)
- Smart diagnostics (local network, gateway, ISP, DNS health checks)
- Health scoring (A+ to F based on latency, jitter, packet loss)
- Baseline learning (learns normal latency from first 30 pings)
- Automatic traceroute on connectivity drops
- CSV logging with daily rotation (ping results, drops, latency breaches)
- HTML report generation with Chart.js visualizations
- Hourly heatmap for time-of-day pattern analysis

Modules:
- config: Configuration management (JSON file, CLI prompts, validation)
- state: Global monitor state (all mutable session data)
- network: Network utilities (ping, DNS, gateway detection, traceroute)
- metrics: Statistical calculations (loss, avg, percentile, jitter, health score)
- csv_logger: CSV file logging with daily rotation
- html_report: HTML report generation with Chart.js
- web_server: Built-in HTTP server for live dashboard and JSON API
- monitor: Main monitoring loop and orchestration

Usage:
    python -m connectivity_monitor              # Interactive setup
    python -m connectivity_monitor --headless    # Headless mode with saved config
    python -m connectivity_monitor --targets 1.1.1.1,8.8.8.8 --web-port 9090

See README.md and docs/ directory for full documentation.
"""

__version__ = "4.0"
