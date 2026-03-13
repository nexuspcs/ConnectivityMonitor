"""Configuration management — load/save JSON config, CLI prompts."""

import json
import os
import sys


# Default config values
DEFAULTS = {
    "poll": 2,
    "threshold": 4,
    "targets": "1.1.1.1,8.8.8.8,208.67.222.222",
    "lat_warn": 100,
    "enable_dns": True,
    "dns_target": "google.com",
    "web_port": 8080,
}


def get_base_dir():
    """Return base directory for logs/reports/config."""
    home = os.path.expanduser("~")
    return os.path.join(home, "ConnectivityMonitor")


def get_config_path():
    return os.path.join(get_base_dir(), "monitor_config.json")


def ensure_dirs():
    """Create base, logs, and reports directories if needed."""
    base = get_base_dir()
    logs = os.path.join(base, "logs")
    reports = os.path.join(base, "reports")
    for d in (base, logs, reports):
        os.makedirs(d, exist_ok=True)
    return base, logs, reports


def load_config():
    """Load config from JSON file. Returns dict or None."""
    path = get_config_path()
    if os.path.exists(path):
        try:
            with open(path, "r") as f:
                return json.load(f)
        except Exception:
            return None
    return None


def save_config(cfg):
    """Save config dict to JSON file."""
    path = get_config_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)


def prompt_default(prompt, default):
    """Prompt user with a default value."""
    val = input("{} [{}]: ".format(prompt, default)).strip()
    return val if val else str(default)


def prompt_yes_no(prompt, default="Y"):
    """Prompt user for yes/no."""
    val = input("{} [{}]: ".format(prompt, default)).strip()
    if not val:
        val = default
    return val.upper().startswith("Y")


def interactive_setup(saved_cfg=None):
    """Run interactive configuration and return config dict."""
    print()
    print("+================================================+")
    print("|       CONNECTIVITY MONITOR v4.0                |")
    print("|       Cross-Platform Python Edition            |")
    print("+================================================+")
    print()

    use_saved = False
    if saved_cfg:
        print(" Saved config found:")
        print("   Targets   : {}".format(saved_cfg.get("targets", "")))
        print("   Poll      : {}s".format(saved_cfg.get("poll", 2)))
        print("   Threshold : {}".format(saved_cfg.get("threshold", 4)))
        print("   Lat warn  : {}ms".format(saved_cfg.get("lat_warn", 100)))
        print("   DNS       : {}".format(saved_cfg.get("enable_dns", True)))
        print("   Web port  : {}".format(saved_cfg.get("web_port", 8080)))
        use_saved = prompt_yes_no(" Use saved config?", "Y")

    if use_saved and saved_cfg:
        cfg = dict(DEFAULTS)
        cfg.update(saved_cfg)
        return cfg

    cfg = dict(DEFAULTS)
    poll = prompt_default(" Poll interval (seconds)", cfg["poll"])
    cfg["poll"] = int(poll)

    threshold = prompt_default(" Failure threshold for drop", cfg["threshold"])
    cfg["threshold"] = int(threshold)

    targets = prompt_default(" Ping targets (comma-sep)", cfg["targets"])
    cfg["targets"] = targets

    lat_warn = prompt_default(" Latency warning (ms)", cfg["lat_warn"])
    cfg["lat_warn"] = int(lat_warn)

    cfg["enable_dns"] = prompt_yes_no(" Enable DNS health check?", "Y")
    if cfg["enable_dns"]:
        cfg["dns_target"] = prompt_default(" DNS test hostname", cfg["dns_target"])

    web_port = prompt_default(" Web dashboard port", cfg["web_port"])
    cfg["web_port"] = int(web_port)

    save_config(cfg)
    print(" Config saved to {}".format(get_config_path()))
    return cfg


def headless_config(args):
    """Build config from CLI args and/or saved config for headless mode."""
    cfg = dict(DEFAULTS)
    saved = load_config()
    if saved:
        cfg.update(saved)

    if args.targets:
        cfg["targets"] = args.targets
    if args.poll:
        cfg["poll"] = args.poll
    if args.threshold:
        cfg["threshold"] = args.threshold
    if args.web_port is not None:
        cfg["web_port"] = args.web_port

    return cfg
