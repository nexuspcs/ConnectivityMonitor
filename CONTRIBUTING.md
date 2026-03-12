# Contributing to Connectivity Monitor

First off, thanks for taking the time to contribute! This project is open source and contributions of all kinds are welcome — whether you're fixing a typo, reporting a bug, suggesting a feature, or writing code.

## Code of Conduct

This project has a [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you agree to uphold it. Please report unacceptable behavior by opening an issue.

## How Can I Contribute?

### Reporting Bugs

If you've found a bug, please [open an issue](https://github.com/nexuspcs/ConnectivityMonitor/issues/new) and include:

- **What you were doing** when the bug happened
- **What happened** (error messages, unexpected behavior, screenshots if applicable)
- **What you expected** to happen
- Your **PowerShell version** (`$PSVersionTable.PSVersion`) and **Windows version**
- Your **network adapter type** (Wi-Fi, Ethernet, etc.)

### Suggesting Features

Got an idea? Open an issue with the **"enhancement"** label and describe:

- What the feature would do
- Why it would be useful
- How you'd expect it to work

### Contributing Code

1. **Fork the repo** and clone your fork locally
2. **Create a branch** for your change (`git checkout -b my-feature`)
3. **Make your changes** — try to keep them focused on one thing
4. **Test your changes** by running the script and verifying the behavior
5. **Commit** with a clear message describing what you changed and why
6. **Push** to your fork and **open a pull request**

In your pull request, please include:

- A clear description of what you changed and why
- How you tested it
- Screenshots of any UI changes (the dashboard is visual, so this helps a lot)

### Non-Code Contributions

Code isn't the only way to contribute! These are just as valuable:

- **Documentation** — improve the README, add examples, clarify setup steps
- **Bug reports** — well-written bug reports save everyone time
- **Feature ideas** — share what would make this tool more useful for you
- **Testing** — try the tool on different Windows versions, network setups, or adapters and report what you find
- **Sharing** — star the repo, tell others about it, write about your experience using it

## Areas That Could Use Help

Here are some things the project needs. Look for issues tagged with **"Help wanted"** and **"Good first issue"** labels to find a good starting point.

### Good First Issues

These are great if you're new to the project or to open source:

- Improving error messages and user-facing text
- Adding comments or documentation to the script
- Fixing typos or clarifying the README
- Adding new default ping target presets

### Help Wanted

These are bigger efforts where contributions would make a real difference:

- **Cross-platform support** (Linux/macOS) — the biggest gap right now. The script uses Windows-specific cmdlets like `Get-NetAdapter`, `Test-Connection`, and `netsh`
- **Historical trend analysis** across multiple sessions
- **Network speed test integration**
- **More ping targets** / custom target presets
- **Dark/light theme toggle** for the dashboard
- **Automated testing** — there's no test suite yet, so adding one would be a big win

### What We're Not Looking For

To set expectations, here are some things that are outside the scope of this project:

- GUI frameworks or Electron wrappers — the tool is intentionally terminal-based
- Features that require external dependencies or installations — the "just run the script" simplicity is a core design goal
- Changes that break backward compatibility with PowerShell 5.0

## Style Guidelines

This project doesn't have a formal style guide, but here are some conventions to follow:

- **Pure PowerShell** — no external modules or dependencies
- **ASCII only** for dashboard rendering — no Unicode box-drawing characters
- **Functions** should have clear, descriptive names
- **Keep it readable** — if a block of code needs a comment to explain what it does, add one
- **Test on a real network** — this is a networking tool, so manual testing matters

## Questions?

If you're not sure about something, open an issue and ask. There are no dumb questions — especially about contributing to a project for the first time.

Thanks for helping make Connectivity Monitor better!
