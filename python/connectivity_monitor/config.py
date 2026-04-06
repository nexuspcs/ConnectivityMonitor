"""Configuration management — load/save JSON config, CLI prompts."""

import json
import os
import re
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
    # Check environment variable first for user customization
    base = os.getenv("CM_BASE_DIR")
    if base:
        return os.path.expanduser(base)
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
        except (json.JSONDecodeError, IOError, OSError) as e:
            # Invalid JSON or file read errors
            print(f"Warning: Could not load config from {path}: {e}", file=sys.stderr)
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


def validate_hostname(hostname):
    """Validate hostname format (basic check)."""
    if not hostname or len(hostname) > 253:
        return False
    # Basic hostname regex: alphanumeric, hyphens, dots
    pattern = r'^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'
    return bool(re.match(pattern, hostname))


def validate_targets(targets):
    """Validate comma-separated ping targets."""
    import ipaddress
    if not targets:
        return False
    target_list = [t.strip() for t in targets.split(",")]
    if not target_list:
        return False
    for target in target_list:
        # Try to parse as IP address first
        try:
            ipaddress.ip_address(target)
            continue
        except ValueError:
            pass
        # Otherwise validate as hostname
        if not validate_hostname(target):
            return False
    return True


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

    # Poll interval validation
    while True:
        try:
            poll = prompt_default(" Poll interval (seconds)", cfg["poll"])
            poll_val = float(poll)
            if 0.1 <= poll_val <= 3600:
                cfg["poll"] = poll_val
                break
            else:
                print("   Error: Poll interval must be between 0.1 and 3600 seconds")
        except ValueError:
            print("   Error: Please enter a valid number")

    # Failure threshold validation
    while True:
        try:
            threshold = prompt_default(" Failure threshold for drop", cfg["threshold"])
            threshold_val = int(threshold)
            if 1 <= threshold_val <= 100:
                cfg["threshold"] = threshold_val
                break
            else:
                print("   Error: Threshold must be between 1 and 100")
        except ValueError:
            print("   Error: Please enter a valid integer")

    # Ping targets validation
    while True:
        targets = prompt_default(" Ping targets (comma-sep)", cfg["targets"])
        if validate_targets(targets):
            cfg["targets"] = targets
            break
        else:
            print("   Error: Invalid target format. Use IP addresses or hostnames (comma-separated)")

    # Latency warning validation
    while True:
        try:
            lat_warn = prompt_default(" Latency warning (ms)", cfg["lat_warn"])
            lat_val = int(lat_warn)
            if 1 <= lat_val <= 10000:
                cfg["lat_warn"] = lat_val
                break
            else:
                print("   Error: Latency warning must be between 1 and 10000 ms")
        except ValueError:
            print("   Error: Please enter a valid integer")

    cfg["enable_dns"] = prompt_yes_no(" Enable DNS health check?", "Y")
    if cfg["enable_dns"]:
        while True:
            dns_target = prompt_default(" DNS test hostname", cfg["dns_target"])
            if validate_hostname(dns_target):
                cfg["dns_target"] = dns_target
                break
            else:
                print("   Error: Invalid hostname format")

    # Web port validation
    while True:
        try:
            web_port = prompt_default(" Web dashboard port", cfg["web_port"])
            port_val = int(web_port)
            if 1 <= port_val <= 65535:
                cfg["web_port"] = port_val
                break
            else:
                print("   Error: Port must be between 1 and 65535")
        except ValueError:
            print("   Error: Please enter a valid port number")

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
