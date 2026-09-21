"""Logging configuration shared by the live bot and CLI scripts."""
from __future__ import annotations

import logging
import logging.handlers
import sys
from pathlib import Path


def setup_logging(log_dir: str = "logs", level: int = logging.INFO) -> None:
    Path(log_dir).mkdir(parents=True, exist_ok=True)

    # Windows consoles default to a legacy codepage (e.g. cp1252) that can't
    # encode the emoji used in status/alert messages, which otherwise raises
    # UnicodeEncodeError out of the logging call itself. Fall back to an
    # escaped representation instead of erroring on every such log line.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="backslashreplace")
        except (AttributeError, ValueError):
            pass

    handlers = [
        logging.StreamHandler(),
        logging.handlers.RotatingFileHandler(
            f"{log_dir}/bot.log", maxBytes=5_000_000, backupCount=5, encoding="utf-8"
        ),
    ]
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        handlers=handlers,
    )
