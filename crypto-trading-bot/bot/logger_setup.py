"""Logging configuration shared by the live bot and CLI scripts."""
from __future__ import annotations

import logging
import logging.handlers
from pathlib import Path


def setup_logging(log_dir: str = "logs", level: int = logging.INFO) -> None:
    Path(log_dir).mkdir(parents=True, exist_ok=True)
    handlers = [
        logging.StreamHandler(),
        logging.handlers.RotatingFileHandler(f"{log_dir}/bot.log", maxBytes=5_000_000, backupCount=5),
    ]
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        handlers=handlers,
    )
