#!/usr/bin/env python3
"""Select a deterministic, repository-diverse subset from a SWE-bench deck."""

import argparse
import itertools
import json
import random
from pathlib import Path


def select(instances: list[dict], repos: int, tasks: int, seed: int) -> list[dict]:
    by_repo: dict[str, list[dict]] = {}
    for instance in instances:
        by_repo.setdefault(instance["repo"], []).append(instance)

    if not 1 <= repos <= len(by_repo):
        raise ValueError(f"REPOS must be between 1 and {len(by_repo)}")
    if tasks < repos:
        raise ValueError("TASKS must be at least REPOS so every selected repository is represented")

    rng = random.Random(seed)
    # Choose only among repository combinations that can satisfy TASKS. This prevents a valid
    # request from failing merely because the seeded shuffle picked several one-issue repos.
    combinations = [
        names for names in itertools.combinations(sorted(by_repo), repos)
        if sum(len(by_repo[name]) for name in names) >= tasks
    ]
    if not combinations:
        raise ValueError(f"no set of {repos} repositories contains {tasks} available issues")
    repo_names = list(rng.choice(combinations))
    for name in repo_names:
        rng.shuffle(by_repo[name])

    chosen: list[dict] = []
    offset = 0
    while len(chosen) < tasks:
        added = False
        for name in repo_names:
            if offset < len(by_repo[name]) and len(chosen) < tasks:
                chosen.append(by_repo[name][offset])
                added = True
        if not added:
            available = sum(len(by_repo[name]) for name in repo_names)
            raise ValueError(f"TASKS={tasks} exceeds the {available} issues available in the selected repositories")
        offset += 1
    return chosen


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--deck", default="experiments/swebench/deck.json")
    parser.add_argument("--repos", type=int, required=True)
    parser.add_argument("--tasks", type=int, required=True)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    source = json.loads(Path(args.deck).read_text())
    selected = select(source["instances"], args.repos, args.tasks, args.seed)
    result = {**source, "seed": args.seed, "instances": selected}
    Path(args.output).write_text(json.dumps(result, indent=2) + "\n")

    names = sorted({item["repo"] for item in selected})
    print(f"Selected {len(selected)} tasks across {len(names)} repositories:")
    for name in names:
        count = sum(item["repo"] == name for item in selected)
        print(f"  {name}: {count}")


if __name__ == "__main__":
    main()
