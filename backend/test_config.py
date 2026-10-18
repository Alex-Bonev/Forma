import importlib
import os

import main
import usdz


def test_limits_read_from_env(monkeypatch):
    monkeypatch.setenv("MAX_UPLOAD_MB", "2")
    monkeypatch.setenv("MAX_RESPONSE_MB", "3")
    monkeypatch.setenv("USDZ_MAX_MB", "1.5")
    monkeypatch.setenv("USDZ_MAX_FACES", "1234")
    try:
        importlib.reload(main)
        importlib.reload(usdz)
        assert main.MAX_UPLOAD == 2 * 1024 * 1024
        assert main.MAX_RESPONSE_B64 == 3 * 1024 * 1024
        assert usdz.MAX_USDZ == int(1.5 * 1024 * 1024)
        assert usdz.START_FACES == 1234
    finally:
        monkeypatch.undo()
        importlib.reload(main)
        importlib.reload(usdz)


def test_local_defaults():
    assert main.MAX_UPLOAD == 10 * 1024 * 1024
    assert main.MAX_RESPONSE_B64 == 20 * 1024 * 1024
    assert usdz.MAX_USDZ == 8 * 1024 * 1024 and usdz.START_FACES == 80_000


def test_dotenv_does_not_override_env(tmp_path, monkeypatch):
    from dotenv import load_dotenv
    env = tmp_path / ".env"
    env.write_text("RV_TEST_A=from_file\nRV_TEST_B=from_file\n")
    monkeypatch.setenv("RV_TEST_A", "from_env")
    monkeypatch.delenv("RV_TEST_B", raising=False)
    load_dotenv(env, override=False)  # the same call main.py makes
    assert os.environ["RV_TEST_A"] == "from_env" and os.environ["RV_TEST_B"] == "from_file"
    monkeypatch.delenv("RV_TEST_B")


def test_tests_skip_the_real_dotenv():
    assert os.environ["DOTENV"] == "0"
