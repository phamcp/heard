@echo off
rem Windows wrapper so `heard --last 3m` works from any terminal; the CLI itself needs only the standard library.
uv run --no-project --script "%~dp0heard" %*
