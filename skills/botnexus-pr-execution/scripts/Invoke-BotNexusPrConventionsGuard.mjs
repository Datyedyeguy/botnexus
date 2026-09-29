// Runs the repository's trusted-base PR conventions evaluator for the publication helper.
// Usage: node Invoke-BotNexusPrConventionsGuard.mjs <guard-module> <packet-json>
import fs from "node:fs";
import { pathToFileURL } from "node:url";

const [guardPath, packetPath] = process.argv.slice(2);
if (!guardPath || !packetPath) {
  console.error("guard module and packet JSON paths are required");
  process.exit(2);
}

const packet = JSON.parse(fs.readFileSync(packetPath, "utf8"));
const guard = await import(pathToFileURL(guardPath).href);
if (typeof guard.evaluate !== "function") {
  console.error("trusted-base guard does not export evaluate");
  process.exit(2);
}

const result = guard.evaluate({
  title: String(packet.title ?? ""),
  body: String(packet.body ?? ""),
  changedPaths: Array.isArray(packet.changedPaths) ? packet.changedPaths : [],
  openCriteriaIssues: [],
});
process.stdout.write(JSON.stringify(result));
