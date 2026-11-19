// Run the Next.js server and FastAPI as one local application on Windows or Unix.
import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const web = path.join(root, "web");
const windows = process.platform === "win32";
const python = path.join(root, ".venv", windows ? "Scripts/python.exe" : "bin/python");
const mode = process.argv[2];
const env = { ...process.env, NEXT_TELEMETRY_DISABLED: "1" };
delete env.INTERVIEWCHECK_STATIC_EXPORT;
if (process.platform === "darwin" && mode === "dev") env.WATCHPACK_POLLING ||= "1000";
const children = new Set();

function port(key, defaultValue) {
  const value = Number(env[key] || defaultValue);
  if (!Number.isInteger(value) || value < 1 || value > 65535) {
    throw new Error(key + " must be a port between 1 and 65535.");
  }
  return String(value);
}

function run(command, args, cwd) {
  const result = spawnSync(command, args, { stdio: "inherit", cwd, env });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}

function start(command, args, cwd) {
  const child = spawn(command, args, { cwd, env, stdio: "inherit", detached: !windows });
  children.add(child);
  child.once("error", error => {
    console.error(error.message);
    stop(1);
  });
  child.once("exit", (code, signal) => {
    if (!stopping) stop(code ?? (signal ? 1 : 0));
  });
}

function terminate(pid, force) {
  if (!pid) return;
  if (windows) {
    // Include the Next.js compiler and Python reload worker in the same shutdown.
    spawnSync("taskkill.exe", ["/PID", String(pid), "/T", "/F"], { stdio: "ignore", windowsHide: true });
  } else {
    try { process.kill(-pid, force ? "SIGKILL" : "SIGTERM"); }
    catch (error) { if (error.code !== "ESRCH") throw error; }
  }
}

let stopping = false;
function stop(code) {
  if (stopping) return;
  stopping = true;
  process.exitCode = code;
  for (const child of children) terminate(child.pid, false);
  if (!windows) {
    const remaining = setTimeout(() => {
      for (const child of children) terminate(child.pid, true);
    }, 3500);
    remaining.unref();
  }
}

if (!["setup", "dev", "build", "start", "export"].includes(mode)) {
  throw new Error("Select setup, dev, build, start, or export.");
}
const frontend = port("INTERVIEWCHECK_WEB_PORT", 3000);
const backend = port("INTERVIEWCHECK_API_PORT", 8000);
if (frontend === backend) throw new Error("Choose separate frontend and API ports.");
env.INTERVIEWCHECK_WEB_PORT = frontend;
env.INTERVIEWCHECK_API_PORT = backend;

const bootstrap = existsSync(python) ? [python] : windows ? ["py", "-3"] : ["python3"];
run(bootstrap[0], [...bootstrap.slice(1), "run.py", mode === "export" ? "--build-only" : "--prepare-web-runtime"], root);
if (mode === "setup" || mode === "export") process.exit(0);

const next = createRequire(path.join(web, "package.json")).resolve("next/dist/bin/next");
if (mode === "build") {
  run(process.execPath, [next, "build", "--webpack"], web);
  run(process.execPath, [path.join(web, "inject-csp.mjs")], web);
  process.exit(0);
}

if (mode === "start") {
  const manifestFile = path.join(web, ".next-server", "routes-manifest.json");
  if (!existsSync(manifestFile)) throw new Error("Run npm run build before starting the production server.");
  const rewrites = JSON.parse(readFileSync(manifestFile, "utf8")).rewrites;
  const routes = Array.isArray(rewrites) ? rewrites : Object.values(rewrites).flat();
  if (!routes.some(rule => rule.destination === "http://127.0.0.1:" + backend + "/api/:path*")) {
    throw new Error("Build with the same INTERVIEWCHECK_API_PORT that you use at startup.");
  }
} else if (env.INTERVIEWCHECK_PUBLIC_ORIGIN) {
  throw new Error("Use npm run build and npm start for a public origin.");
}

for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => stop(0));
start(python, ["-m", "uvicorn", "api.main:app", "--host", "127.0.0.1", "--port", backend,
  "--no-proxy-headers", "--no-access-log", "--timeout-keep-alive", "120", ...(mode === "dev" ? ["--reload", "--reload-dir", "api"] : [])], root);
start(process.execPath, [next, mode, "--hostname", "127.0.0.1", "--port", frontend,
  ...(mode === "dev" ? ["--webpack"] : [])], web);
console.log("InterviewCheck at http://localhost:" + frontend + " (FastAPI http://127.0.0.1:" + backend + ").");
