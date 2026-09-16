"""Run the team's unchanged backend against disposable SQLite for FE HTTP tests.

Requires Python 3.13+ and the backend dependencies in a separate virtualenv.
This is a test launcher, not an alternative production backend or migration.
"""
import argparse
import os
from pathlib import Path
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend-dir", type=Path, required=True)
    parser.add_argument("--port", type=int, default=18090)
    args = parser.parse_args()
    backend = args.backend_dir.resolve(strict=True)
    if not (backend / "app" / "main.py").is_file():
        parser.error("--backend-dir must point to apps/backend")
    sys.path.insert(0, str(backend))
    test_root = (Path(__file__).resolve().parents[1] / "build" / "backend-fixtures").resolve()
    test_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="daehwa-fe-test-", dir=test_root) as temporary:
        if not Path(temporary).resolve().is_relative_to(test_root):
            raise RuntimeError("Test directory escaped its expected root")
        db_path = (Path(temporary) / "test.sqlite").as_posix()
        os.environ["DATABASE_URL"] = f"sqlite+pysqlite:///{db_path}"
        os.environ["PROVIDER_MODE"] = "mock"
        os.environ["APP_ENV"] = "development"
        from app.main import app
        from app.db import Base, engine
        import uvicorn

        Base.metadata.create_all(engine)
        try:
            uvicorn.run(app, host="127.0.0.1", port=args.port, access_log=False)
        finally:
            engine.dispose()


if __name__ == "__main__":
    main()
