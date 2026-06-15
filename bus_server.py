#!/usr/bin/env python3
"""
Local entry point for the stdio bus server (used by setup.sh / the installer).
Runs the packaged server from the bundled src/ copy, so there is a single
implementation shared with the PyPI package and the HTTP/Docker build.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "src"))

from claude_bus.server import main  # noqa: E402

if __name__ == "__main__":
    main()
