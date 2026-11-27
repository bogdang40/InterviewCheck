import { constants, copyFileSync, existsSync, lstatSync, readFileSync, readdirSync, unlinkSync } from "node:fs";
import { join } from "node:path";

function* files(root, parents = []) {
  for (const entry of readdirSync(join(root, ...parents), { withFileTypes: true })) {
    const parts = [...parents, entry.name];
    if (entry.isDirectory()) yield* files(root, parts);
    else if (entry.isFile()) yield parts;
  }
}

function matches(file, bytes) {
  return lstatSync(file, { throwIfNoEntry: false })?.isFile() && readFileSync(file).equals(bytes);
}

// Next 16.4.6 flattens segment request keys using "/" only. On Windows the
// exporter instead puts nested segments in directories below "__next.<segment>".
export function normalizeExportSegments(output, compiledApp) {
  const suffix = ".segment.rsc";
  const repairs = [];
  const destinations = new Set();
  for (const parts of files(compiledApp)) {
    if (!parts.at(-1).endsWith(suffix)) continue;
    const boundary = parts.findIndex(part => part.endsWith(".segments"));
    if (boundary < 0 || parts.length - boundary < 3) continue;
    const route = [...parts.slice(0, boundary), parts[boundary].slice(0, -".segments".length)];
    // Next stores "/" at "index" and prefixes a literal "/index" route with "index".
    if (route[0] === "index") route.shift();
    const directory = join(output, ...route);
    if (!existsSync(join(directory, "__next._tree.txt"))) continue;
    const key = parts.slice(boundary + 1);
    key[key.length - 1] = key.at(-1).slice(0, -suffix.length);
    const target = join(directory, `__next.${key.join(".")}.txt`);
    const legacy = join(directory, `__next.${key[0]}`, ...key.slice(1, -1), `${key.at(-1)}.txt`);
    if (destinations.has(target)) throw new Error(`Conflicting Next segment filename: ${target}`);
    destinations.add(target);
    const bytes = readFileSync(join(compiledApp, ...parts));
    const hasTarget = lstatSync(target, { throwIfNoEntry: false }) !== undefined;
    const hasLegacy = lstatSync(legacy, { throwIfNoEntry: false }) !== undefined;
    if (hasTarget && !matches(target, bytes)) throw new Error(`Conflicting exported segment: ${target}`);
    if (hasLegacy && !matches(legacy, bytes)) throw new Error(`Unverified exported segment: ${legacy}`);
    if (!hasTarget && !hasLegacy) throw new Error(`Missing exported segment: ${target}`);
    if (hasLegacy) repairs.push({ legacy, target, hasTarget });
  }
  // Validate every mapping before the first write. An interrupted copy can be
  // retried when both names already have the exact compiler bytes.
  for (const { legacy, target, hasTarget } of repairs) {
    if (!hasTarget) copyFileSync(legacy, target, constants.COPYFILE_EXCL);
    unlinkSync(legacy);
  }
  return repairs.length;
}
