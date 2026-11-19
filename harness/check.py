"""What an embedding host typically needs from its Python: common standard library modules, NumPy, threads,
and reading a folder of files. UnrealPy's web build, the reference host, uses all of them."""

import hashlib
import json
import math
import os
import random
import struct
import sys
import threading
import time
import zlib
from pathlib import Path

import numpy as np

print("python", sys.version.split()[0], sys.platform, "pointer bits", struct.calcsize("P") * 8)
print("numpy", np.__version__)
a = np.arange(12, dtype=np.float64).reshape(3, 4)
assert float(a.sum()) == 66.0 and a.T.shape == (4, 3)
assert np.allclose(np.linalg.inv(np.eye(3) * 2), np.eye(3) / 2)
assert abs(np.fft.fft(np.ones(8))[0] - 8) < 1e-9
assert np.random.default_rng(1).integers(0, 10, 5).shape == (5,)
v = np.array([1.0, 2.0, 3.0]) * 2 - np.array([0.5, 0.5, 0.5])
assert v.tolist() == [1.5, 3.5, 5.5]
assert json.loads(json.dumps({"a": [1, 2.5]})) == {"a": [1, 2.5]}
assert zlib.decompress(zlib.compress(b"doom" * 100)) == b"doom" * 100
assert hashlib.sha256(b"x").hexdigest().startswith("2d711642")
assert math.isclose(math.atan2(1, 1), math.pi / 4) and random.Random(1).random() < 1

seen = []
worker = threading.Thread(target=lambda: seen.append(sum(range(1000))))
worker.start()
worker.join()
assert seen == [499500]

names = sorted(os.listdir("/harness"))[:3]
assert Path("/cpw/python311.zip").is_file() and json.__spec__.origin.startswith("/cpw/python311.zip")
start = time.perf_counter()
import email.message  # noqa: E402,F401  (a package import spread over several files)

print("listdir", names, "import email %.3f s" % (time.perf_counter() - start))
print("OK")
