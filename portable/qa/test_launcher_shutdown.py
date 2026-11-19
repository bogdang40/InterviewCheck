"""Check the Windows cleanup race without depending on process scheduling."""
from types import SimpleNamespace
from unittest.mock import Mock
import subprocess

import pytest

import smoke_archive


@pytest.mark.parametrize("still_listening", [False, True])
def test_taskkill_race_checks_the_resulting_state(monkeypatch, still_listening):
    launcher = Mock(pid=120)
    launcher.poll.return_value = None
    kill = Mock(return_value=subprocess.CompletedProcess(["taskkill"], 255))
    monkeypatch.setattr(smoke_archive, "os", SimpleNamespace(name="nt"))
    monkeypatch.setattr(smoke_archive.subprocess, "run", kill)
    monkeypatch.setattr(smoke_archive, "listening", lambda port: still_listening and port == 8000)
    monkeypatch.setattr(smoke_archive, "time", SimpleNamespace(monotonic=iter([0, 9]).__next__))

    if still_listening:
        with pytest.raises(subprocess.CalledProcessError) as error:
            smoke_archive.stop_launcher(launcher, (3000, 8000))
        assert error.value.returncode == 255
    else:
        smoke_archive.stop_launcher(launcher, (3000, 8000))
    launcher.wait.assert_called_once_with(timeout=15)
