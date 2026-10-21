@echo off
rem Windows wrapper for the knowledge base tool: heard-kb build, search, stats, eval (see heard-kb --help).
uv run --script "%~dp0heard-kb" %*
