import { execFileSync } from "node:child_process";

/**
 * Reads the IOPlatformUUID of the Mac the tool runs on, the same value the
 * app reads through IOKit, so `--device auto` binds a license to this Mac.
 */
export class MacDeviceID {
  static read(runner: (file: string, args: string[]) => string = MacDeviceID.ioreg): string {
    const output = runner("ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"]);
    const match = /"IOPlatformUUID"\s*=\s*"([0-9A-Fa-f-]+)"/.exec(output);
    if (!match?.[1]) throw new Error("IOPlatformUUID not found; pass --device <uuid> explicitly");
    return match[1].toUpperCase();
  }

  private static ioreg(file: string, args: string[]): string {
    return execFileSync(file, args, { encoding: "utf8" });
  }
}
