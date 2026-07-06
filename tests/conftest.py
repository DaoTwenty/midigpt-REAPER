"""
Shared test fixtures and stubs.

Stubs out reaper_python and mmm_refactored so tests can import the project
modules without requiring REAPER or the C++ extension.
"""

import sys
import os
import types


# ---------------------------------------------------------------------------
# Stub: reaper_python
# ---------------------------------------------------------------------------

class _ReaperModule(types.ModuleType):
    """Fake reaper_python that provides RPR_* callables returning tuples."""

    def __getattr__(self, name):
        if name.startswith("RPR_") or name.startswith("_"):
            return lambda *a, **k: (0,) * 10
        raise AttributeError(name)

    # `from reaper_python import *` calls dir() then getattr for each name.
    # We expose nothing by default (no RPR_ names needed at import time).
    __all__ = []


if "reaper_python" not in sys.modules:
    sys.modules["reaper_python"] = _ReaperModule("reaper_python")


# ---------------------------------------------------------------------------
# Add source directories to sys.path
# ---------------------------------------------------------------------------

_src_midigpt = os.path.join(os.path.dirname(__file__), "..", "src", "Scripts", "MIDI-GPT")
if _src_midigpt not in sys.path:
    sys.path.insert(0, _src_midigpt)
