import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

// The MCP server is `quesynth --mcp`, so these tests drive the built binary. It
// serves MCP on Linux only: the QCP socket transport exists nowhere else, and
// other platforms print that --mcp is unsupported and exit 1.
export const skip = process.platform !== "linux";

export const buildCommand = "odin build hosts/standalone -o:speed -out:build/quesynth";

// QUESYNTH_BIN names a binary built elsewhere; otherwise it is build/quesynth.
export function quesynthBinary() {
  const binary = process.env.QUESYNTH_BIN || fileURLToPath(new URL("../../../build/quesynth", import.meta.url));
  if (!existsSync(binary)) {
    throw new Error(`quesynth binary not found at ${binary}. Build it from the repository root with: ${buildCommand}`);
  }
  return binary;
}
