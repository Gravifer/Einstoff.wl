import json
import subprocess
import sys
from pathlib import Path

import einx
import numpy as np


ROOT = Path(__file__).resolve().parents[1]


def arr(x):
    return np.asarray(x).tolist()


def normalize_value(x):
    if isinstance(x, tuple):
        return [arr(part) for part in x]
    return arr(x)


def py_case(func):
    out = {"ok": True}
    try:
        out["value"] = normalize_value(func(False))
    except Exception as exc:
        out["ok"] = False
        out["error"] = type(exc).__name__ + ": " + str(exc)
    try:
        graph = func(True)
        out["graphTrueType"] = type(graph).__name__
        out["graphTrue"] = str(graph)
    except Exception as exc:
        out["graphTrueType"] = "ERROR"
        out["graphTrue"] = type(exc).__name__ + ": " + str(exc)
    return out


def einx_cases():
    return {
        "id_permute_2d": py_case(
            lambda graph: einx.id(
                "a b -> b a", (1 + np.arange(6)).reshape(2, 3), graph=graph
            )
        ),
        "id_split_permute_merge": py_case(
            lambda graph: einx.id(
                "a (b c) -> (b a) c",
                (1 + np.arange(32)).reshape(4, 8),
                b=2,
                graph=graph,
            )
        ),
        "id_repeat_2d": py_case(
            lambda graph: einx.id(
                "a b -> a b c",
                (1 + np.arange(6)).reshape(2, 3),
                c=2,
                graph=graph,
            )
        ),
        "id_repeat_merge": py_case(
            lambda graph: einx.id(
                "a -> (a c)", 1 + np.arange(4), c=3, graph=graph
            )
        ),
        "id_unit_squeeze": py_case(
            lambda graph: einx.id(
                "a 1 c -> a c",
                (1 + np.arange(6)).reshape(2, 1, 3),
                graph=graph,
            )
        ),
        "sum_basic": py_case(
            lambda graph: einx.sum(
                "a [b] -> a", (1 + np.arange(12)).reshape(3, 4), graph=graph
            )
        ),
        "sum_permute": py_case(
            lambda graph: einx.sum(
                "a [b] c -> c a",
                (1 + np.arange(24)).reshape(2, 3, 4),
                graph=graph,
            )
        ),
        "sum_merge": py_case(
            lambda graph: einx.sum(
                "a [b] c -> (a c)",
                (1 + np.arange(24)).reshape(2, 3, 4),
                graph=graph,
            )
        ),
        "sum_repeat": py_case(
            lambda graph: einx.sum(
                "a [b] -> a c",
                (1 + np.arange(12)).reshape(4, 3),
                c=3,
                graph=graph,
            )
        ),
        "max_basic": py_case(
            lambda graph: einx.max(
                "a [b] -> a", (1 + np.arange(12)).reshape(3, 4), graph=graph
            )
        ),
        "map_flip": py_case(
            lambda graph: einx.flip(
                "a [b]", (1 + np.arange(8)).reshape(2, 4), graph=graph
            )
        ),
        "map_sort": py_case(
            lambda graph: einx.sort(
                "a [b]", (8 - np.arange(8)).reshape(2, 4), graph=graph
            )
        ),
        "dot_matmul": py_case(
            lambda graph: einx.dot(
                "a [b], [b] c -> a c",
                (1 + np.arange(6)).reshape(2, 3),
                (1 + np.arange(12)).reshape(3, 4),
                graph=graph,
            )
        ),
        "dot_batch_matmul": py_case(
            lambda graph: einx.dot(
                "b a [k], b [k] c -> b a c",
                (1 + np.arange(24)).reshape(2, 3, 4),
                (1 + np.arange(40)).reshape(2, 4, 5),
                graph=graph,
            )
        ),
        "directsum_join": py_case(
            lambda graph: einx.id(
                "m a, m b -> m (a + b)",
                (1 + np.arange(6)).reshape(2, 3),
                (1 + np.arange(8)).reshape(2, 4),
                graph=graph,
            )
        ),
        "directsum_split": py_case(
            lambda graph: einx.id(
                "m (a + b) -> m a, m b",
                (1 + np.arange(14)).reshape(2, 7),
                a=3,
                b=4,
                graph=graph,
            )
        ),
    }


def wl_cases():
    proc = subprocess.run(
        ["wolframscript", "-script", str(ROOT / "agent-explore" / "trace_einx_probe.wls")],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    lines = [line for line in proc.stdout.splitlines() if line.startswith("{")]
    if proc.returncode != 0 or not lines:
        return {
            "_error": {
                "returncode": proc.returncode,
                "stdout": proc.stdout,
                "stderr": proc.stderr,
            }
        }
    return json.loads(lines[-1])


def summarize(wl, py):
    rows = []
    for name in py:
        w = wl.get(name, {})
        p = py[name]
        rows.append(
            {
                "case": name,
                "valueMatches": p.get("ok") and w.get("normal") == p.get("value"),
                "traceReleasesToNormal": w.get("normalEqualsReleased"),
                "traceHasPrivateMaterialize": w.get("hasPrivateMaterialize"),
                "traceHasArrayReduce": "ArrayReduce" in (w.get("graph") or ""),
                "traceHasDot": "Dot" in (w.get("graph") or ""),
                "traceHasJoin": "Join" in (w.get("graph") or ""),
                "wlGraphHead": w.get("graphHead"),
                "wlGraphPreview": (w.get("graph") or "")[:220],
                "einxGraphTrueType": p.get("graphTrueType"),
                "einxGraphPreview": (p.get("graphTrue") or "")[:220],
            }
        )
    return rows


def main():
    py = einx_cases()
    wl = wl_cases()
    print(json.dumps({"wl": wl, "einx": py, "summary": summarize(wl, py)}, indent=2))
    failures = [
        r
        for r in summarize(wl, py)
        if not r["valueMatches"]
        or not r["traceReleasesToNormal"]
        or r["traceHasPrivateMaterialize"]
    ]
    return 1 if failures or "_error" in wl else 0


if __name__ == "__main__":
    raise SystemExit(main())
