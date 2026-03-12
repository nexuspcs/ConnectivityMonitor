"""Global monitor state — all mutable data lives here."""

import datetime
import threading


class MonitorState:
    """Holds all mutable state for the connectivity monitor session."""

    def __init__(self):
        # Session
        self.session_start = datetime.datetime.now()
        self.shutdown = False
        self.paused = False

        # Ping history (max 1000 entries)
        self.history = []          # list of {time, latency, target}
        self.max_history = 1000
        self.total_pings = 0
        self.total_success = 0

        # Drop tracking
        self.drops = []            # list of {start, end, duration, target, diagnosis}
        self.fail_count = 0
        self.is_down = False
        self.down_start = None

        # Per-target stats
        self.per_target = {}       # {target: {sent, ok, lats}}

        # Baseline learning (first 30 successful pings)
        self.baseline_samples = []
        self.baseline_latency = None
        self.baseline_locked = False

        # Gateway history (max 200)
        self.gw_history = []       # list of {time, latency}

        # Threshold breach tracking (high latency)
        self.threshold_breaches = []
        self.breach_active = False
        self.breach_start = None

        # Network info
        self.public_ip = "detecting..."
        self.isp_name = "detecting..."

        # Hourly heatmap data
        self.hourly_data = {}      # {hour (0-23): [latencies]}

        # Traceroute results (keep last 3)
        self.traceroutes = []
        self.last_trace_time = datetime.datetime.min
        self.trace_thread = None

        # Diagnostics
        self.last_diagnosis = {"msg": "Initializing...", "color": "gray"}

        # Daily log rotation
        self.current_date = datetime.date.today().isoformat()

        # Thread lock for shared state
        self.lock = threading.Lock()

    def reset(self):
        """Reset all session data (R key equivalent)."""
        with self.lock:
            self.history.clear()
            self.drops.clear()
            self.per_target.clear()
            self.gw_history.clear()
            self.threshold_breaches.clear()
            self.traceroutes.clear()
            self.hourly_data.clear()
            self.fail_count = 0
            self.is_down = False
            self.total_pings = 0
            self.total_success = 0
            self.session_start = datetime.datetime.now()
            self.baseline_samples.clear()
            self.baseline_latency = None
            self.baseline_locked = False
