# PPSA Local Builder - Master Development Plan

## Role

You are the lead software engineer for this project.

Your goal is to build a professional-grade local CI/CD system for the PPSA project.

The system must be modular, extensively logged, highly maintainable, and capable of running continuously without GitHub Actions.

Never rewrite the entire project at once.

Implement one milestone at a time.

After every milestone:

* Build
* Test
* Fix
* Commit
* Update documentation

Never continue if tests are failing.

---

# Existing Project

Repository:

kaiser62/ppsa

Current build:

PowerShell → WSL → build-live-usb.sh

Artifacts:

* VDI
* IMG.ZST
* SHA256

Output directory:

H:\dev\palimage

---

# Overall Goals

The finished system should:

* Watch GitHub issue comments
* Detect new test reports
* Build locally in WSL
* Produce VDI images
* Verify artifacts
* Boot VirtualBox
* Run smoke tests
* Store build history
* Produce professional logs
* Recover from failures automatically

GitHub Actions must never be required.

Everything should execute locally.

---

# Development Rules

Always follow these rules.

1.

Never delete existing functionality unless replacing it with an improved implementation.

2.

Every function must have logging.

3.

Every major operation must be timed.

4.

Every error must include:

* timestamp
* command
* exit code
* stack/location
* recommended action

5.

Every file copy must be verified.

6.

Every artifact must be checksum verified.

7.

Never use temporary files on C:.

Use only:

WSL home

or

H:\

8.

Never hardcode values that belong in configuration.

---

# Logging Standard

Every log line must include

Timestamp

Severity

Module

Message

Example

[2026-06-26 14:33:21.225]
[INFO]
[Builder]

Building image...

Levels

INFO

DEBUG

WARN

ERROR

SUCCESS

TRACE

---

# Build Report

Every build must generate

build.log

trace.log

system.log

commands.log

summary.log

status.json

history.json

manifest.json

---

# status.json

Must include

Build ID

Git Commit

Git Branch

Duration

Success

Exit Code

Artifact Sizes

Checksum

Build Timestamp

Machine Name

WSL Version

Kernel Version

CPU

Memory

Disk Free

---

# Modules

Split the project into modules.

modules/

Logger.psm1

GitHub.psm1

Queue.psm1

Builder.psm1

VirtualBox.psm1

Artifacts.psm1

Status.psm1

Utils.psm1

Configuration.psm1

---

# Configuration

Everything configurable.

builder.json

Output directory

Polling interval

WSL user

Project path

Artifact size

Compression level

VirtualBox VM

Log retention

Retry count

GitHub issue

Repository

---

# Build Workflow

System Information

↓

Git Status

↓

Pull Latest Code

↓

Verify Repository

↓

Start Timer

↓

Build

↓

Compress

↓

Convert RAW

↓

Generate SHA256

↓

Verify Files

↓

Boot VM

↓

Smoke Tests

↓

Save Artifacts

↓

Generate Reports

↓

Update status.json

↓

Commit if requested

---

# Logging Requirements

Every shell command executed.

Every command timed.

Every stdout captured.

Every stderr captured.

Every command exit code stored.

Every phase duration stored.

Total build duration stored.

---

# Bash Requirements

Always use

set -Eeuo pipefail

set -x

PS4 timestamps

ERR trap

tee

Never suppress errors.

---

# PowerShell Requirements

Use structured logging.

Use Stopwatch timers.

Use Write-Progress.

Use colored console output.

Use transcript logging.

---

# Artifact Verification

Verify

Exists

Size

Checksum

Can be opened

Latest symlink updated

Manifest updated

---

# VirtualBox Testing

Create VM if missing.

Attach latest VDI.

Boot VM.

Wait for login.

Collect serial log.

Run smoke tests.

Shutdown.

Store results.

---

# Failure Recovery

If build fails

Save logs

Save trace

Generate failure report

Do not overwrite latest.vdi

Keep previous successful build

---

# GitHub Watcher

Watch issue comments.

Ignore duplicates.

Ignore own comments.

Queue builds.

Prevent concurrent builds.

---

# Cleanup

Delete builds older than configured retention.

Compress old logs.

Never delete latest successful build.

---

# Documentation

Maintain

README.md

docs/architecture.md

docs/modules.md

docs/workflow.md

docs/configuration.md

Every module must be documented.

---

# Commit Policy

Every milestone must have a separate commit.

Example

feat(logger): add structured logging

feat(builder): add WSL build module

feat(vbox): automatic VM boot

fix(builder): preserve previous successful build

Never create huge commits.

---

# Development Order

Milestone 1

Configuration

Milestone 2

Logger

Milestone 3

Utilities

Milestone 4

GitHub watcher

Milestone 5

Build queue

Milestone 6

WSL builder

Milestone 7

Artifact manager

Milestone 8

Status engine

Milestone 9

VirtualBox manager

Milestone 10

Smoke testing

Milestone 11

Cleanup

Milestone 12

Documentation

Milestone 13

Optimization

Milestone 14

Refactoring

Milestone 15

Final validation

---

# Definition of Done

The project is complete only when

✓ All modules are documented

✓ All tests pass

✓ A complete build succeeds

✓ VirtualBox boots successfully

✓ Artifacts are verified

✓ Logs are complete

✓ status.json is correct

✓ history.json is maintained

✓ Existing functionality has been preserved

At the end of every milestone, summarize:

1. What changed.
2. Which files were modified.
3. Which tests were run.
4. The results.
5. Any remaining issues before proceeding.
