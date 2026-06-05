#!/usr/bin/env python3
"""Validate a Stride batch JSON document produced by /stride-ideation:decompose.

Usage:
    python3 lib/validate_batch.py <path-to-stride-batch.json>

Exits 0 with no output on success.
Exits 1 on the first violation, printing a single line of the form:

    stride-ideation: <error message naming the failing JSON path>

The named error variants are exactly the five the task contract calls out:

  (a) parse_error           - input is not valid JSON
  (b) wrong_root_key        - root has 'tasks' or any key other than 'goals'
  (c) empty_goals           - 'goals' is missing, not an array, or empty
  (d) goal_missing_field    - a goal entry lacks title, type, or tasks
  (e) bad_dependency_index  - a task's dependencies[] index references an
                              array slot that does not exist OR points to a
                              task at or after the referencing task's own
                              position (forward reference)

The validator does NOT enforce per-task Stride-API field shapes
(pitfalls-as-array-of-strings, verification_steps-as-objects, etc.). Those
are the decomposer agent's responsibility; /ship surfaces the API's own
error if anything slips through.
"""

import json
import sys
from typing import Any


def fail(message: str) -> "None":
    sys.stderr.write(f"stride-ideation: {message}\n")
    sys.exit(1)


def validate(path: str) -> "None":
    try:
        with open(path, "r", encoding="utf-8") as fp:
            text = fp.read()
    except OSError as exc:
        fail(f"could not read {path}: {exc}")

    # (a) parse_error
    try:
        doc = json.loads(text)
    except json.JSONDecodeError as exc:
        fail(
            f"JSON parse failed at line {exc.lineno} col {exc.colno} "
            f"(char {exc.pos}): {exc.msg}"
        )

    if not isinstance(doc, dict):
        fail(
            f"top-level JSON value must be an object, got {type(doc).__name__}"
        )

    # (b) wrong_root_key
    if "goals" not in doc:
        if "tasks" in doc:
            fail(
                "root key 'tasks' is the most common batch-API mistake — "
                "Stride's POST /api/tasks/batch requires root key 'goals'. "
                "Rename 'tasks' to 'goals' at the JSON root and retry."
            )
        # Surface whatever non-'goals' key the agent picked instead.
        unexpected = [k for k in doc.keys() if k not in (
            "source_spec",
            "source_spec_sha256",
            "decomposition_notes",
        )]
        if unexpected:
            fail(
                f"root object is missing the required 'goals' array "
                f"(saw unexpected key(s): {sorted(unexpected)})"
            )
        fail("root object is missing the required 'goals' array")

    # (c) empty_goals
    goals = doc["goals"]
    if not isinstance(goals, list):
        fail(
            f"root.goals must be an array, got {type(goals).__name__}"
        )
    if len(goals) == 0:
        fail(
            "root.goals is an empty array — the decomposer returned no goals; "
            "check the requirements doc for under-specification"
        )

    # (d) goal_missing_field
    for goal_idx, goal in enumerate(goals):
        if not isinstance(goal, dict):
            fail(
                f"goals[{goal_idx}] must be an object, "
                f"got {type(goal).__name__}"
            )
        for required in ("title", "type", "tasks"):
            if required not in goal:
                fail(
                    f"goals[{goal_idx}] is missing required field '{required}'"
                )
        if not isinstance(goal["title"], str) or not goal["title"].strip():
            fail(f"goals[{goal_idx}].title must be a non-empty string")
        if goal["type"] != "goal":
            fail(
                f"goals[{goal_idx}].type must be 'goal', "
                f"got {goal['type']!r}"
            )
        if not isinstance(goal["tasks"], list):
            fail(
                f"goals[{goal_idx}].tasks must be an array, "
                f"got {type(goal['tasks']).__name__}"
            )
        if len(goal["tasks"]) == 0:
            fail(
                f"goals[{goal_idx}].tasks is empty — every goal must "
                f"own at least one task"
            )

        # (e) bad_dependency_index
        for task_idx, task in enumerate(goal["tasks"]):
            if not isinstance(task, dict):
                fail(
                    f"goals[{goal_idx}].tasks[{task_idx}] must be an object, "
                    f"got {type(task).__name__}"
                )
            deps = task.get("dependencies", [])
            if not isinstance(deps, list):
                fail(
                    f"goals[{goal_idx}].tasks[{task_idx}].dependencies must "
                    f"be an array, got {type(deps).__name__}"
                )
            for dep_pos, dep in enumerate(deps):
                # String identifiers (e.g. 'W47') reference pre-existing tasks
                # outside the batch — they are not validated here.
                if isinstance(dep, str):
                    continue
                if not isinstance(dep, int) or isinstance(dep, bool):
                    fail(
                        f"goals[{goal_idx}].tasks[{task_idx}]"
                        f".dependencies[{dep_pos}] must be a non-negative "
                        f"integer index or a string identifier, "
                        f"got {dep!r}"
                    )
                if dep < 0:
                    fail(
                        f"goals[{goal_idx}].tasks[{task_idx}]"
                        f".dependencies[{dep_pos}] = {dep} is negative"
                    )
                if dep >= len(goal["tasks"]):
                    fail(
                        f"goals[{goal_idx}].tasks[{task_idx}]"
                        f".dependencies references index {dep} but goal "
                        f"only has {len(goal['tasks'])} tasks "
                        f"(valid indices 0..{len(goal['tasks']) - 1})"
                    )
                if dep >= task_idx:
                    # Self-reference or forward reference — both are invalid;
                    # array-index dependencies must point to a task that
                    # appears EARLIER in the same goal's tasks array.
                    fail(
                        f"goals[{goal_idx}].tasks[{task_idx}]"
                        f".dependencies references index {dep} which is at "
                        f"or after the referencing task's own position "
                        f"{task_idx} — array-index dependencies must point "
                        f"to an earlier sibling"
                    )

    # All checks passed.


def main(argv: "list[str]") -> "None":
    if len(argv) != 2:
        sys.stderr.write(
            "usage: validate_batch.py <path-to-stride-batch.json>\n"
        )
        sys.exit(2)
    validate(argv[1])


if __name__ == "__main__":
    main(sys.argv)
