import { randomBytes, scrypt, timingSafeEqual } from "node:crypto";
import { promisify } from "node:util";

const scryptAsync = promisify(scrypt) as (
  password: string,
  salt: Buffer,
  keylen: number,
  options: { N: number; r: number; p: number; maxmem: number },
) => Promise<Buffer>;

export interface ScryptParameters {
  readonly cost: number;
  readonly blockSize: number;
  readonly parallelization: number;
}

const DEFAULT_PARAMETERS: ScryptParameters = { cost: 32768, blockSize: 8, parallelization: 1 };
const KEY_LENGTH = 64;
const SALT_LENGTH = 16;

/**
 * scrypt password hashing using only the Node standard library, so the
 * server has no native dependencies. Encoded form:
 *   scrypt$N$r$p$<salt base64>$<hash base64>
 */
export class PasswordHasher {
  private decoy: Promise<string> | undefined;

  constructor(private readonly parameters: ScryptParameters = DEFAULT_PARAMETERS) {}

  async hash(password: string): Promise<string> {
    const salt = randomBytes(SALT_LENGTH);
    const derived = await this.derive(password, salt, this.parameters);
    const { cost, blockSize, parallelization } = this.parameters;
    return ["scrypt", cost, blockSize, parallelization, salt.toString("base64"), derived.toString("base64")].join("$");
  }

  async verify(password: string, encoded: string): Promise<boolean> {
    const parsed = PasswordHasher.parse(encoded);
    if (!parsed) return false;
    const derived = await this.derive(password, parsed.salt, parsed.parameters);
    return derived.length === parsed.hash.length && timingSafeEqual(derived, parsed.hash);
  }

  /**
   * A syntactically valid hash for a password nobody knows. Login runs a
   * verify against it when the email is unknown so response timing does
   * not reveal which emails exist. Computed once per process so the decoy
   * path costs exactly one derivation, like the real path.
   */
  decoyHash(): Promise<string> {
    this.decoy ??= this.hash(randomBytes(24).toString("base64"));
    return this.decoy;
  }

  private derive(password: string, salt: Buffer, parameters: ScryptParameters): Promise<Buffer> {
    const maxmem = 128 * parameters.cost * parameters.blockSize * 2;
    return scryptAsync(password, salt, KEY_LENGTH, {
      N: parameters.cost,
      r: parameters.blockSize,
      p: parameters.parallelization,
      maxmem,
    });
  }

  private static parse(encoded: string): { parameters: ScryptParameters; salt: Buffer; hash: Buffer } | null {
    const parts = encoded.split("$");
    if (parts.length !== 6 || parts[0] !== "scrypt") return null;
    const cost = Number(parts[1]);
    const blockSize = Number(parts[2]);
    const parallelization = Number(parts[3]);
    if (![cost, blockSize, parallelization].every((n) => Number.isInteger(n) && n > 0)) return null;
    return {
      parameters: { cost, blockSize, parallelization },
      salt: Buffer.from(parts[4] ?? "", "base64"),
      hash: Buffer.from(parts[5] ?? "", "base64"),
    };
  }
}
