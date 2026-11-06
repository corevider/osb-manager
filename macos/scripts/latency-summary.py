import json
import sys


def percentile(values, fraction):
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))
    return ordered[index]


def summarize(path, start, end):
    kinds = {}
    with open(path) as handle:
        for line in handle:
            sample = json.loads(line)
            if start <= sample["t"] <= end:
                kinds.setdefault(sample["k"], []).append(sample["ms"])
    result = {}
    for kind, values in sorted(kinds.items()):
        result[kind] = {
            "count": len(values),
            "p50": round(percentile(values, 0.5), 3),
            "p99": round(percentile(values, 0.99), 3),
            "max": round(max(values), 3),
        }
    return result


if __name__ == "__main__":
    print(json.dumps(summarize(sys.argv[1], float(sys.argv[2]), float(sys.argv[3])), indent=2))
