# 0008: Controlled concept experiments

## Status

Superseded by [0010](0010-tauri-rewrite.md). Code execution and experiments were removed from the current product and must not be restored without a new decision.

## Context

Satori should occasionally let a reader manipulate an idea from the PDF, but it
is not a terminal or an arbitrary code-hosting product. The previous runner put
AI-generated Python, C, C++, shell, and Swift snippets behind the same “运行”
button. A temporary working directory and timeout were useful reliability
guards, but they did not prevent a snippet from reading user files, starting a
process, or connecting to the network.

## Decision

- Experiments are limited to pure-computation Python, C, and C++ snippets.
- Shell and Swift remain recognized for legacy decoding, but are deliberately
  not offered or executed as Satori experiments.
- A conservative static safety gate rejects file, network, dynamic-evaluation,
  and process-launch APIs before a process starts. Rejected snippets remain
  copyable so the reader can deliberately use another environment.
- Allowed snippets run in their own temporary working directory with a bounded
  timeout/output budget and a macOS sandbox that denies network access, runtime
  writes, and reads from the user's home/volumes. If that sandbox is unavailable,
  the experiment fails closed instead of falling back to an unsandboxed process.
- The “试试看” reading action still asks the model to design a small experiment;
  it does not grant the model a new execution capability.

## Consequences

The common operating-systems experiments—scheduling, page replacement,
sequential/random access, and allocation calculations—remain possible without
turning the reading panel into a general shell. A snippet that genuinely needs
files or networking is intentionally redirected to copy-only use instead of
silently receiving broader permissions.
