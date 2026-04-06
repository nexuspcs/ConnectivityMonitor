# Security Policy

## Overview

ConnectivityMonitor is designed for local network monitoring and diagnostics. This document outlines security considerations, best practices, and how to report security vulnerabilities.

## Security Model

ConnectivityMonitor is designed to run on:
- **Local machines** for personal network diagnostics
- **Private networks** behind firewalls
- **Trusted environments** where users have appropriate access

### Threat Model

**What ConnectivityMonitor protects against:**
- Command injection in network operations
- Path traversal in file serving
- Code injection via configuration files
- Insecure temporary file creation

**What ConnectivityMonitor does NOT protect against:**
- Unauthorized access to the web dashboard (no authentication)
- Data exfiltration if the host is compromised
- Network-level attacks on the monitoring traffic itself

## Security Best Practices

### Web Dashboard Security

The built-in web server (Python version) **does not include authentication** by default. Follow these guidelines:

#### For Local Use Only (Recommended)
```bash
# Bind to localhost only (default behavior can be changed)
python -m connectivity_monitor --web-port 8080
# Access via http://localhost:8080 only
```

#### For Network Access
If you need to access the dashboard from other devices on your network:

1. **Firewall Configuration**: Ensure your firewall only allows connections from trusted IPs
2. **Bind Address**: By default, the server binds to `0.0.0.0` (all interfaces)
3. **Network Isolation**: Run only on trusted private networks (home/office LAN)
4. **VPN Access**: For remote access, use a VPN instead of exposing the port publicly

**⚠️ WARNING**: Do NOT expose the web dashboard to the public internet without additional security measures.

### Configuration File Security

Configuration files are stored at:
- **Linux/macOS**: `~/ConnectivityMonitor/monitor_config.json`
- **Windows**: `%USERPROFILE%\ConnectivityMonitor\monitor_config.json`

**Best practices:**
- Keep configuration files with appropriate permissions (readable only by owner)
- Do not store sensitive credentials in configuration files
- Review ping targets to ensure they are legitimate and trusted

### Execution Policy (Windows)

The PowerShell script requires script execution to be enabled:

```powershell
# Check current execution policy
Get-ExecutionPolicy

# Set execution policy for current user (recommended)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Alternative: Run with bypass for single session
powershell -ExecutionPolicy Bypass -File .\ConnectivityDropMonitor.ps1
```

**Security note**: Only use `RemoteSigned` or stricter policies. Avoid `Unrestricted` in production environments.

### macOS/Linux Permissions

**Script Permissions:**
```bash
# Set appropriate execute permissions
chmod 755 macos/ConnectivityDropMonitor.sh
chmod 644 macos/lib/*.sh  # Library files don't need execute bit

# Ensure ownership is correct
chown -R $USER:$GROUP ~/ConnectivityMonitor
```

**File Permissions:**
```bash
# Secure the base directory
chmod 700 ~/ConnectivityMonitor

# Logs and reports
chmod 600 ~/ConnectivityMonitor/logs/*.csv
chmod 600 ~/ConnectivityMonitor/reports/*.html
```

### Network Security Considerations

**ICMP Ping Requirements:**
- Ping commands typically require no special privileges on Windows
- On Linux/macOS, ping may require setuid or capabilities
- The monitor uses system `ping` command, not raw sockets

**DNS Security:**
- DNS health checks query configured DNS servers
- Ensure DNS targets are trusted (default: google.com)
- DNS spoofing could affect diagnostics but not monitoring integrity

**External API Calls:**
The monitor makes HTTPS calls to:
- `https://ip-api.com/json` — Public IP and ISP detection

These are optional features. If privacy is a concern:
1. Review the code in `network.py` (Python), `lib/network.sh` (macOS), or PowerShell functions
2. These calls happen once at startup (not continuously)
3. No personally identifiable information is sent (simple GET request)

### Data Privacy

**What data is collected:**
- Ping latency measurements
- Packet loss statistics
- Gateway IP addresses
- Public IP address (via ip-api.com)
- ISP name (via ip-api.com)
- WiFi signal strength (if available)

**What is NOT collected:**
- Personal user information
- Browsing history
- Network traffic content
- Authentication credentials

**Data storage:**
- All data is stored locally in CSV and HTML files
- No telemetry is sent to external services
- Logs can be deleted at any time

### Environment Variables

The monitor supports customization via environment variables:

```bash
# Customize base directory location
export CM_BASE_DIR="$HOME/my-custom-location"
python -m connectivity_monitor
```

**Security consideration**: Ensure custom directories have appropriate permissions.

## Known Limitations

1. **No Authentication**: Web dashboard has no built-in authentication
2. **No Encryption**: Local file storage is unencrypted
3. **No Rate Limiting**: Web API endpoints have no rate limiting
4. **No Audit Logging**: No security event logging beyond diagnostic logs

## Security Fixes in v4.0

This release includes the following security improvements:

### Fixed Vulnerabilities
1. **Command Injection (PowerShell)** — Fixed in commit `13b4514`
   - Old: Used `cmd /c "tracert $target"` (injectable)
   - New: Uses `System.Diagnostics.ProcessStartInfo` with argument array

2. **HTTP Downgrade Attack** — Fixed in commit `13b4514`
   - Old: Used `http://ip-api.com` (unencrypted)
   - New: Uses `https://ip-api.com` (encrypted)

3. **Path Traversal (Python Web Server)** — Fixed in commit `13b4514`
   - Old: Insufficient validation with `basename()` only
   - New: Validates resolved path stays within base directory

4. **Code Injection (Bash Config)** — Fixed in commit `13b4514`
   - Old: Interpolated shell variables into Python code strings
   - New: Uses heredoc with command-line arguments (safe)

5. **Insecure Temporary Files (macOS)** — Fixed in commit `13b4514`
   - Old: Predictable filenames `/tmp/cm_traceroute_$$.txt`
   - New: Uses `mktemp` with random names

### Input Validation Improvements (commit `25b672a`)
- Poll interval: Must be between 0.1 and 3600 seconds
- Failure threshold: Must be between 1 and 100
- Web port: Must be between 1 and 65535
- Ping targets: Validated as IP addresses or hostnames
- DNS target: Validated as valid hostname

## Reporting a Security Vulnerability

If you discover a security vulnerability in ConnectivityMonitor:

1. **Do NOT** open a public GitHub issue
2. **Email** the maintainer: Include the following in your report:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if available)

3. **Allow time** for a fix to be developed and released before public disclosure

### Security Contact

For security issues, please open a security advisory on GitHub or create an issue with the `security` label. The maintainer will respond within 7 days.

## Security Checklist for Users

Before deploying ConnectivityMonitor in a production environment:

- [ ] Review all ping targets and ensure they are trusted
- [ ] Configure firewall rules to restrict web dashboard access
- [ ] Set appropriate file permissions on logs and config files
- [ ] Run with least privileges (do not run as root/administrator unless required)
- [ ] Keep the software updated to receive security fixes
- [ ] Review logs periodically for unexpected behavior
- [ ] Disable features you don't need (e.g., DNS checks, public IP detection)
- [ ] Use a separate monitoring account with limited privileges
- [ ] Consider network segmentation if running on servers

## Security-Related Configuration

### Disable Public IP Detection

If privacy is a concern, you can disable public IP detection by modifying the code:

**Python**: Comment out the `detect_public_ip()` call in `monitor.py`
**macOS**: Comment out the `detect_public_ip` call in `ConnectivityDropMonitor.sh`
**Windows**: Comment out the `DetectPublicIP` call in `ConnectivityDropMonitor.ps1`

### Restrict Web Dashboard Binding

**Python**: Modify `web_server.py` to bind to `127.0.0.1` instead of `0.0.0.0`:

```python
def start_web_server(port, state, reports_dir, logs_dir, bind="127.0.0.1"):
```

### Read-Only Logs

To prevent log tampering:

```bash
# Make logs read-only after rotation
chmod 444 ~/ConnectivityMonitor/logs/*.csv
```

## Compliance and Certifications

ConnectivityMonitor is not certified for:
- Medical use
- Financial services
- Critical infrastructure
- Compliance with specific regulations (HIPAA, PCI-DSS, etc.)

For compliance-critical environments, perform your own security audit and testing.

## License and Disclaimer

This software is provided as-is without warranty. Users are responsible for:
- Evaluating security for their specific use case
- Implementing additional security controls as needed
- Monitoring and maintaining the software
- Complying with applicable laws and regulations

---

**Last Updated**: 2026-04-06
**Document Version**: 1.0
