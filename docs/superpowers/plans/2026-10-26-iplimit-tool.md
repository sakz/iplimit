# IPLimit Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package a Debian 12 traffic-shaping tool that installs its dependencies in one command and exposes interactive and non-interactive management through `iplimit`.

**Architecture:** A single Bash executable owns the CLI and a systemd daemon mode. The daemon discovers direct TCP and UDP clients from conntrack, then creates one HTB class per client: WAN egress is classified by destination IP for downloads, while WAN ingress is redirected to an IFB and classified by source IP for uploads. An installer copies the executable and service, installs Debian dependencies, and leaves rate activation to an explicit `iplimit start` or interactive choice.

**Tech Stack:** Bash 5, iproute2/tc, conntrack-tools, IFB, systemd, GitHub Actions

---

### Task 1: Define CLI and pure parsing behavior

**Files:**
- Create: `iplimit`
- Create: `tests/test.sh`

- [ ] **Step 1: Write failing shell tests**

Test that integer and decimal positive Mbps values are accepted, zero/malformed values are rejected, IPv4/IPv6 address validation works, and conntrack parsing returns only original-direction TCP/UDP clients whose original destination is a local address.

- [ ] **Step 2: Run tests and confirm failure**

Run: `bash tests/test.sh`
Expected: non-zero exit because `iplimit` or the pure helper functions do not exist.

- [ ] **Step 3: Implement the minimal pure helpers and CLI usage**

Implement `is_valid_rate`, `is_ip_address`, `extract_clients`, configuration loading, `help`, `version`, and a library-only entry point used by tests. Reject unknown commands instead of opening the menu so command typos cannot mutate traffic control state.

- [ ] **Step 4: Run helper tests**

Run: `bash tests/test.sh`
Expected: every assertion prints `ok` and the process exits 0.

### Task 2: Implement safe traffic shaping and automatic client lifecycle

**Files:**
- Modify: `iplimit`
- Modify: `tests/test.sh`

- [ ] **Step 1: Add command-generation assertions**

Assert IPv4 clients use `protocol ip` with `/32`, IPv6 clients use `protocol ipv6` with `/128`, download filters use `dst_ip`, upload filters use `src_ip`, and TCP/UDP do not create separate shared buckets.

- [ ] **Step 2: Implement owned qdiscs and classes**

Create an HTB root on the selected WAN interface, an IFB device for ingress shaping, and one class plus `fq_codel` child per discovered IP in each direction. Preserve unmatched traffic in a high-rate default class. Refuse to overwrite a non-default root qdisc, and delete only IPLimit-owned filters, classes, qdiscs, and IFB state during stop.

- [ ] **Step 3: Implement daemon reconciliation**

Poll conntrack for original-direction TCP and UDP flows addressed to the WAN interface, add unseen clients, refresh last-seen timestamps, expire idle clients after the configured TTL, persist a read-only status table under `/run/iplimit`, and rebuild state on service restart.

- [ ] **Step 4: Implement management commands and menu**

Support `start [rate] [interface]`, `set <rate>`, `status`, `clients`, `stop`, and an interactive menu when no command is supplied. Validate prerequisites before changing qdiscs and print exact recovery guidance on failure.

- [ ] **Step 5: Run syntax and helper tests**

Run: `bash -n iplimit && bash tests/test.sh`
Expected: both commands exit 0.

### Task 3: Add one-command installation and documentation

**Files:**
- Create: `install.sh`
- Create: `iplimit.service`
- Create: `README.md`
- Create: `LICENSE`
- Create: `.github/workflows/ci.yml`
- Modify: `tests/test.sh`

- [ ] **Step 1: Add an isolated installer test**

Run the installer with `DESTDIR` and `SKIP_DEPENDENCIES=1`, then assert executable mode, service placement, and default configuration without touching the host system.

- [ ] **Step 2: Implement the installer**

Require root for a real install, require `apt-get`, install `bash iproute2 conntrack kmod`, atomically install the executable and systemd unit, create `/etc/iplimit.conf` only when absent, reload systemd, and print the first `iplimit` command to run.

- [ ] **Step 3: Document operation and limitations**

Document curl and git installation, CLI/menu examples, TCP/UDP support, direct-client-IP requirement, SSH-safe behavior, cleanup semantics, Debian 12 scope, diagnostics, and uninstall steps.

- [ ] **Step 4: Add continuous integration**

On pushes and pull requests, install ShellCheck, run `bash -n`, ShellCheck, and the isolated test suite on Ubuntu.

- [ ] **Step 5: Run all locally available checks**

Run: `bash -n iplimit install.sh tests/test.sh && bash tests/test.sh`
Expected: syntax checks and all tests exit 0; if ShellCheck is unavailable locally, record that CI performs it.

### Task 4: Publish the public repository

**Files:**
- Modify: plan checkboxes only after evidence exists

- [ ] **Step 1: Initialize and inspect Git state**

Run: `git init -b main && git status --short`
Expected: only the planned repository files are untracked.

- [ ] **Step 2: Verify the complete deliverable**

Run the full syntax/test suite, inspect `git diff --check`, and review every file against the requirements before staging.

- [ ] **Step 3: Commit the verified files**

Run: `git add . && git commit -m "feat: add per-IP traffic shaping tool"`
Expected: one initial commit containing only the IPLimit deliverable.

- [ ] **Step 4: Create and push the public GitHub repository**

Run: `gh repo create iplimit --public --source=. --remote=origin --push`
Expected: GitHub reports the public repository URL and `main` tracks `origin/main`.

- [ ] **Step 5: Verify the remote**

Run: `gh repo view --json nameWithOwner,visibility,url,defaultBranchRef` and compare local `HEAD` with `origin/main`.
Expected: visibility is `PUBLIC`, default branch is `main`, and both commit hashes match.
