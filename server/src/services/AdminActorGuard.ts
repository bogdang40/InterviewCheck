import type { User } from "../domain/User.js";
import { HttpError } from "../http/HttpError.js";
import type { UserRepository } from "../repositories/UserRepository.js";

/**
 * Re-reads the acting admin inside the caller's transaction, so an admin who
 * was demoted or disabled after authenticating cannot finish a write.
 */
export class AdminActorGuard {
  constructor(private readonly users: UserRepository) {}

  requireActiveAdmin(actorId: string): User {
    const actor = this.users.findById(actorId);
    if (!actor || actor.disabled || actor.role !== "admin") {
      throw new HttpError(403, "forbidden", "Admin access required.");
    }
    return actor;
  }
}
