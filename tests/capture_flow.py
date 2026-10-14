"""Snapshot diagnostico READ-ONLY del flow corrente in Resolve.
Non sposta nodi, non cambia parametri, non salva la comp.
Uso: python tests/capture_flow.py [output.json]
Le connessioni agli output interni di Macro/Group sono proiettate sul gruppo.
"""
import json
from pathlib import Path
import sys

sys.path.insert(0, "C:/ProgramData/Blackmagic Design/DaVinci Resolve/Support/Developer/Scripting/Modules")
import DaVinciResolveScript as resolve_script

resolve = resolve_script.scriptapp("Resolve")
if not resolve:
    raise SystemExit("Resolve non disponibile")
comp = resolve.Fusion().GetCurrentComp()
if not comp:
    raise SystemExit("Nessuna comp Fusion corrente")
flow = comp.GetFrameList()[1].FlowView
valid_types = {"Image", "DataType2D", "Mask", "DataType3D", "ParticleStyle"}


def outer(tool):
    while tool and tool.ParentTool:
        tool = tool.ParentTool
    return tool


nodes = []
for tool in comp.GetToolList(False).values():
    if tool.ParentTool:
        continue
    attrs = tool.GetAttrs()
    pos = flow.GetPosTable(tool)  # GetPos in Python espone solo il primo valore.
    if not isinstance(pos, dict) or 1 not in pos or 2 not in pos:
        continue
    inputs = []
    for inp in (tool.GetInputList() or {}).values():
        info = inp.GetAttrs()
        if info.get("INPS_DataType") not in valid_types:
            continue
        output = inp.GetConnectedOutput()
        if output:
            src = outer(output.GetTool())
            if src:
                inputs.append({"source": src.GetAttrs()["TOOLS_Name"],
                               "id": info.get("INPS_ID", ""), "type": info["INPS_DataType"]})
    nodes.append({"name": attrs["TOOLS_Name"], "type": attrs["TOOLS_RegID"],
                  "x": pos[1], "y": pos[2], "inputs": inputs})
nodes.sort(key=lambda t: t["name"])
result = {"description": "Snapshot read-only del grafo visibile corrente; gruppi atomici",
          "nodes": nodes}
path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".pi/current-flow-snapshot.json")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(result, indent=2), encoding="utf-8")
print(f"Salvato {path}: {len(nodes)} nodi visibili")
for node in nodes:
    print(node["name"], (node["x"], node["y"]), node["inputs"])
