# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

"""
  Recursively copy and merge /bin and /lib from a list of store paths
  - Warn if files have already been `seen` in another store path, and list the
    colliding paths
  - Allow directories to exist in `destination`, so that they get merged.
  - Ignore symlinks that point outside the /nix/store.
  - Resolve symlinks if pointing out of the store path, but into /nix/store.
  - Copy them as-is if they point intoto their own store path.

Some paths may collide, i.e. different builds of bash or foundational libraries,
different libgcc, etc. Ensuring a collision-free closure via overlays can be
done but is quite a bit of work with no clear upside, as many of the collisions
are non-critical.
For cases where they are, a second list of store paths, `pins` can be passed
in a file. Store path listed in that file are added first, effectivly "overriding"
those comming later.

"""
import os
import sys
import shutil
import logging
import itertools
import subprocess
import re
from pathlib import Path


root = logging.getLogger()
root.setLevel(logging.INFO)

# nix build --print-out-paths --no-link --impure --expr "let pkgs = import <nixpkgs> {}; in pkgs.closureInfo { rootPaths = [ pkgs.helix ]; }'
if len(sys.argv) not in (3, 4):
    print(f"""usage: {sys.argv[0]} <store-paths> <out-dir> (<pins>)
""", file=sys.stderr)
    sys.exit(1)

store_paths_file = Path(sys.argv[1])
output = Path(sys.argv[2])
output.mkdir(exist_ok=True)
(output / "bin").mkdir()
(output / "lib").mkdir()

if len(sys.argv) == 4:
    with open(sys.argv[3], "r") as f:
        pins = [line.strip() for line in f.readlines()]
else:
    pins = []
logging.info(f"First store path wins on collision. Pins added at start: {" ".join(pins)}")
seen = dict()
with open(store_paths_file, "r") as f:
    for store_path in itertools.chain(pins, f.readlines()):
        store_path = Path(store_path.strip())
        logging.info(f"Copying {store_path}")
        assert store_path.exists(), f"{store_path} does not exist"

        for dir in ["bin", "lib"]:
            output_dir = (output / dir)
            input_dir = (store_path / dir)

            for path in input_dir.glob("**"):
                if path == input_dir:
                    continue
                relative_path = path.relative_to(input_dir)
                out_path = output_dir / relative_path

                if path.is_dir():
                    out_path.mkdir(exist_ok=True)

                elif path.is_file() or path.is_symlink():
                    # Check for collisions
                    if relative_path not in seen:
                        seen[relative_path] = []
                    seen[relative_path].append(str(path.parents[-4]))
                    if len(seen[relative_path]) > 1:
                        if not any(p in pins for p in seen[relative_path]):
                            logging.warning(f"Found collision for {relative_path}: {" vs ".join(seen[relative_path])}")
                        else:
                            logging.debug(f"Ignoring collision for {relative_path} due to pin resolving it")
                        continue

                    # Resolve symlinks if they point outside this store path, but into /nix/store
                    # Ignore/drop them if they point outside /nix/store.
                    if path.is_symlink():
                        resolved = path.resolve()
                        if not resolved.is_relative_to(store_path):
                            if resolved.is_relative_to("/nix/store"):
                                path = resolved
                            else:
                                logging.debug(f"Ignoring symlink {path} as it's pointing outside /nix/store, to {resolved}.")
                                continue

                    # Actually copy the file/symlink
                    logging.debug(f"copying {path}")
                    assert not out_path.exists()
                    shutil.copy(path, out_path)

                    # Check and patch dynamic executables
                    if dir == "bin":

                        file_desc = subprocess.run(["file", str(out_path)], capture_output=True, text=True).stdout
                        if re.search(r"ELF.*dynamically", file_desc):
                            mode = out_path.stat().st_mode
                            os.chmod(out_path, mode | 0o200)
                            subprocess.run([
                                "patchelf",
                                "--set-rpath", "/lib",
                                "--set-interpreter", "/lib/ld-linux-x86-64.so.2", str(out_path)
                            ])
                            os.chmod(out_path, mode & ~0o200)
                else:
                    raise NotImplementedError(f"{relative_path} has an unsupported file type")
