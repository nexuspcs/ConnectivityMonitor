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


def _normalize_targets(targets):
    """Split and clean a comma-separated targets string."""
    if not targets:
        return []
    return [t.strip() for t in str(targets).split(",") if t.strip()]


def _require_positive_int(value, label, minimum=1, maximum=None):
    """Validate integer bounds and return the coerced value."""
    try:
        num = int(value)
    except (TypeError, ValueError):
        raise ValueError("{} must be an integer.".format(label))
    if num < minimum:
        raise ValueError("{} must be at least {}.".format(label, minimum))
    if maximum is not None and num > maximum:
        raise ValueError("{} must be at most {}.".format(label, maximum))
    return num


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
    if args.lat_warn is not None:
        cfg["lat_warn"] = args.lat_warn
    if args.enable_dns is not None:
        cfg["enable_dns"] = args.enable_dns
    if args.dns_target:
        cfg["dns_target"] = args.dns_target
    if args.web_port is not None:
        cfg["web_port"] = args.web_port

    return cfg


def validate_config(cfg):
    """
    Validate and normalize configuration.

    Ensures numeric fields are positive, port is within range, targets are
    present, and DNS settings are consistent. Returns the validated config
    (mutating the original dict).
    """
    cfg["poll"] = _require_positive_int(
        cfg.get("poll", DEFAULTS["poll"]), "Poll interval (seconds)"
    )
    cfg["threshold"] = _require_positive_int(
        cfg.get("threshold", DEFAULTS["threshold"]),
        "Failure threshold",
    )
    cfg["lat_warn"] = _require_positive_int(
        cfg.get("lat_warn", DEFAULTS["lat_warn"]),
        "Latency warning threshold (ms)",
    )
    cfg["web_port"] = _require_positive_int(
        cfg.get("web_port", DEFAULTS["web_port"]),
        "Web dashboard port",
        maximum=65535,
    )

    targets = _normalize_targets(cfg.get("targets", DEFAULTS["targets"]))
    if not targets:
        raise ValueError("At least one ping target is required (e.g. 1.1.1.1).")
    cfg["targets"] = ",".join(targets)

    enable_dns = cfg.get("enable_dns", True)
    if isinstance(enable_dns, str):
        enable_dns = enable_dns.lower() not in ("false", "0", "no", "off")
    cfg["enable_dns"] = bool(enable_dns)

    if cfg["enable_dns"]:
        dns_target = cfg.get("dns_target", DEFAULTS["dns_target"])
        if not dns_target or not str(dns_target).strip():
            raise ValueError("DNS health check is enabled but no DNS hostname is set.")
        cfg["dns_target"] = str(dns_target).strip()

    return cfg
