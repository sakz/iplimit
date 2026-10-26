# IPLimit CPU And Chinese UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove avoidable softirq work from IPLimit's ingress path and present all script-facing prompts, status, help, and errors in Chinese.

**Architecture:** Replace the global ingress `matchall` redirect with per-client source-IP redirects created only after conntrack discovery. Group equal-mask flower filters under one priority per address family and use each class number as the independently removable filter handle. Keep the existing HTB/IFB rate semantics, ownership journal, configuration format, and systemd lifecycle.

**Tech Stack:** Bash 5, Linux tc/HTB/flower/mirred/IFB, conntrack, systemd, Docker-based Debian 12 integration tests

---

### Task 1: Reproduce and lock the data-path regression

**Files:**
- Create: `tests/test_tc_integration.sh`
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Add an integration test for unrelated ingress traffic**

Create a veth plus network namespace, configure IPLimit on the host-side veth, send packets from a source IP that has no client class, and assert the IFB default class receives zero packets. Then add that source as a client, send traffic again, and assert its upload class receives packets.

- [ ] **Step 2: Add shared-priority assertions**

Add two IPv4 clients and assert their WAN, IFB, and ingress flower filters share one priority but retain different handles. Assert there is no ingress `matchall` filter.

- [ ] **Step 3: Run the test against the current release**

Run the test in a privileged Debian 12 container. Expected: FAIL because `setup_network` installs a global matchall redirect and unrelated ingress reaches IFB.

### Task 2: Limit IFB work to discovered clients

**Files:**
- Modify: `iplimit`
- Modify: `tests/test.sh`
- Modify: `tests/test_tc_integration.sh`

- [ ] **Step 1: Define stable filter identity**

Use priority `49150` for IPv4 and `49151` for IPv6. Use the hexadecimal tc class number as the flower handle so one client's rules can be removed without traversing or deleting the other clients' rules.

- [ ] **Step 2: Remove the global ingress redirect**

Keep clsact setup, but do not add `protocol all matchall`. During client creation, add an ingress flower match on that client's source IP and redirect only matching packets to IFB after its IFB class exists.

- [ ] **Step 3: Update removal and crash cleanup**

Delete one client's WAN, IFB, and ingress filters by protocol, shared priority, and handle. On daemon recovery or full cleanup, remove the two owned ingress priority groups while preserving unrelated ingress and egress filters.

- [ ] **Step 4: Verify the hypothesis**

Run the privileged Debian test. Expected: unrelated packets never enter IFB; registered clients are shaped; same-family filters share a priority; owned cleanup leaves foreign clsact filters intact.

### Task 3: Translate the command interface

**Files:**
- Modify: `iplimit`
- Modify: `install.sh`
- Modify: `README.md`
- Modify: `tests/test.sh`

- [ ] **Step 1: Translate user-visible command output**

Translate help, menu choices, prompts, errors, warnings, status labels, start/stop confirmations, daemon log messages, config comments, and installer messages. Keep command names and configuration keys stable for compatibility.

- [ ] **Step 2: Add interface assertions**

Assert `iplimit help` contains the Chinese usage heading and menu/action descriptions, and that unknown-command errors are Chinese.

- [ ] **Step 3: Document the lower-overhead path**

Explain that only discovered client upload packets enter IFB and that equal-mask flower rules share an address-family priority. Include commands to compare softirq and tc counters before and after upgrade.

### Task 4: Verify and publish

**Files:**
- Modify: version string and the files above only

- [ ] **Step 1: Run static and unit checks**

Run `bash -n`, `bash tests/test.sh`, ShellCheck, and `git diff --check`.

- [ ] **Step 2: Run Debian 12 network integration**

Run `tests/test_tc_integration.sh` in a privileged Debian 12 container and verify selective IFB counters, IPv4/IPv6 filters, foreign-qdisc refusal, and owned cleanup.

- [ ] **Step 3: Review the diff**

Compare against this plan and request an independent production-readiness review. Fix every Critical or Important finding before publication.

- [ ] **Step 4: Commit and push**

Commit only the planned files, push `main`, verify local and remote hashes, wait for GitHub Actions, and rerun the public one-command installer.
