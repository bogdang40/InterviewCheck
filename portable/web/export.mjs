// The portable distribution ships Next's HTML export and runs without Node.
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const result = spawnSync(process.execPath, [require.resolve("next/dist/bin/next"), "build", "--webpack"], {
  stdio: "inherit",
  env: { ...process.env, INTERVIEWCHECK_STATIC_EXPORT: "1" },
});
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
