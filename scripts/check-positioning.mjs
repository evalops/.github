#!/usr/bin/env node
// Positioning guardrail for the EvalOps org profile and docs.
//
// Keeps the org front door on the visibility + governance + coverage frame and
// blocks regressions to the eval-era / execution-first framing the org moved
// away from (see evalops/hopper #192-197). Self-contained: no ripgrep or npm
// dependencies, runs on plain `node`.

import { readFileSync, existsSync } from "node:fs";

const FILES = ["profile/README.md", "README.md", "AGENTS.md", "SECURITY.md"];

const banned = [
  // eval-era org tagline
  "organi[sz]ational operating system",
  "operating system for (ai )?agent",
  "shipping accountable ai",
  "evaluation, governance,? and observability",
  // execution-first frame (mirrors the hopper positioning-frame guardrail)
  "put (ai )?agents to work",
  "operating layer",
  "agents that actually work",
  "from signal to done",
  "governed agent work",
  "proves? agents are trustworthy",
];

const re = new RegExp(banned.join("|"), "i");

let failed = false;
for (const file of FILES) {
  if (!existsSync(file)) continue;
  readFileSync(file, "utf8")
    .split("\n")
    .forEach((line, i) => {
      if (re.test(line)) {
        failed = true;
        console.error(`positioning guardrail: ${file}:${i + 1}: ${line.trim()}`);
      }
    });
}

if (failed) {
  console.error(
    "\nOff-frame positioning copy found. Hold the visibility + governance + coverage frame.",
  );
  process.exitCode = 1;
} else {
  console.log("positioning guardrail passed");
}
