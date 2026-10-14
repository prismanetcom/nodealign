"""Test del vero script su Lua 5.1 (Fusion) e 5.4 con Lupa.
python -m pip install lupa; python tests/run_tests.py [sorgente.lua] [--preview output.json]
Il fixture S08 è uno snapshot read-only: i test NON si collegano a Resolve.
"""
import argparse
import json
from pathlib import Path

from lupa.lua51 import LuaRuntime as Lua51
from lupa.lua54 import LuaRuntime as Lua54

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("source", nargs="?", type=Path, default=root / "NodeAlign.lua")
parser.add_argument("--preview", type=Path)
args = parser.parse_args()
source = args.source.resolve()
tests = (root / "tests" / "test_nodealign.lua").read_text(encoding="utf-8")
fixture = json.loads((root / "tests" / "fixtures" / "resolve-s08.json").read_text(encoding="utf-8"))
for runtime in (Lua51, Lua54):
    print(f"Testing {runtime.__module__}: {source}", flush=True)
    lua = runtime(unpack_returned_tuples=True)
    lua.globals().NODEALIGN_SOURCE = source.as_posix()
    lua.globals().FUSION_FIXTURE = lua.table_from(fixture, recursive=True)
    lua.execute(tests)
    if args.preview:
        nodes = []
        for node in lua.globals().FUSION_PREVIEW.values():
            nodes.append({"name": node.name, "x": node.x, "y": node.y,
                          "inputs": [{"source": inp.source, "id": inp.id} for inp in node.inputs.values()]})
        args.preview.parent.mkdir(parents=True, exist_ok=True)
        args.preview.write_text(json.dumps({"nodes": nodes}, indent=2), encoding="utf-8")
        print(f"Anteprima simulata salvata: {args.preview}", flush=True)
