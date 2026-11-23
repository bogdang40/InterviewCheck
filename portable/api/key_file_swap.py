"""Replace the local master key file atomically, with a backup until the rotation settles."""
import base64
import os
from pathlib import Path


def write_key_file(dest: Path, encoded: bytes) -> Path:
    dest.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, encoded)
        os.fsync(fd)
    finally:
        os.close(fd)
    if os.name != "nt":
        os.chmod(dest, 0o600)
    return dest


class KeyFileSwap:
    """Installs a new master key and can restore, keep or discard the previous one."""

    def __init__(self, key_path: Path):
        self.key_path = key_path
        self.backup_path = key_path.with_name(key_path.name + ".bak")
        self._tmp_path: Path | None = None
        self._has_backup = False
        self._replaced = False

    def install(self, master: bytes) -> None:
        self._tmp_path = write_key_file(self.key_path.with_name(self.key_path.name + ".tmp"), base64.urlsafe_b64encode(master))
        if self.key_path.exists():
            write_key_file(self.backup_path, self.key_path.read_bytes())
            self._has_backup = True
        os.replace(self._tmp_path, self.key_path)
        self._replaced, self._tmp_path = True, None

    def restore(self) -> None:
        """Undo an installation whose database changes were all rolled back."""
        if self._replaced and self._has_backup and self.backup_path.exists():
            os.replace(self.backup_path, self.key_path)
        else:
            if self._tmp_path is not None:
                self._tmp_path.unlink(missing_ok=True)
            if self._has_backup:
                self.backup_path.unlink(missing_ok=True)
        self._has_backup = self._replaced = False

    def discard_backup(self) -> None:
        if self._has_backup:
            self.backup_path.unlink(missing_ok=True)
            self._has_backup = False

    @property
    def installed(self) -> bool:
        return self._replaced
