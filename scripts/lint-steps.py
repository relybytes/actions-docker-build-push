#!/usr/bin/env python3
"""Run shellcheck over the shell scripts embedded in a composite action.

shellcheck cannot read action.yml, so the step bodies inside it are never
checked by anything. This script pulls each composite step's ``run`` body out of
the YAML, makes it parseable by replacing every ``${{ ... }}`` expression with a
harmless placeholder, writes it to a temporary file with a shebang, and runs
shellcheck on the result.

Usage:
    scripts/lint-steps.py [action.yml ...] [--shell-file scripts/lib.sh]

Exit status is non-zero when shellcheck reports anything or when the action file
cannot be parsed.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

# A GitHub expression can appear anywhere, including in the middle of a word.
# "$(:)" is a command substitution that expands to nothing and is valid in every
# position a value can appear: inside double quotes, as a bare word, or as part
# of a larger string. That keeps the script parseable without pretending the
# expression had a particular value.
EXPRESSION = re.compile(r"\$\{\{.*?\}\}", re.DOTALL)
EXPRESSION_PLACEHOLDER = "$(:)"

SHEBANG = "#!/usr/bin/env bash\n"


def replace_expressions(script: str) -> str:
    """Replace every GitHub expression with a placeholder shellcheck can parse."""
    return EXPRESSION.sub(EXPRESSION_PLACEHOLDER, script)


def collect_steps(action_path: Path) -> list[tuple[str, str]]:
    """Return (label, script) for every composite step that has a bash run body."""
    with action_path.open(encoding="utf-8") as handle:
        document = yaml.safe_load(handle)

    if not isinstance(document, dict):
        raise ValueError(f"{action_path}: top level is not a mapping")

    runs = document.get("runs")
    if not isinstance(runs, dict):
        raise ValueError(f"{action_path}: missing 'runs' mapping")

    steps = runs.get("steps")
    if not isinstance(steps, list):
        raise ValueError(f"{action_path}: missing 'runs.steps' list")

    collected: list[tuple[str, str]] = []

    for index, step in enumerate(steps):
        if not isinstance(step, dict):
            raise ValueError(f"{action_path}: step {index} is not a mapping")

        script = step.get("run")
        if script is None:
            continue

        shell = step.get("shell")
        if shell not in ("bash", "sh"):
            raise ValueError(
                f"{action_path}: step {index} has a 'run' body with shell "
                f"{shell!r}; only bash and sh are checked"
            )

        name = step.get("name") or step.get("id") or f"step-{index}"
        collected.append((f"{action_path}: {name}", script))

    return collected


def slug(label: str) -> str:
    """Turn a step label into something usable as a file name."""
    return re.sub(r"[^A-Za-z0-9._-]+", "-", label).strip("-").lower()


def run_shellcheck(path: Path, label: str) -> bool:
    """Run shellcheck on one file. Return True when it reports nothing."""
    result = subprocess.run(
        ["shellcheck", "--shell=bash", "--external-sources", str(path)],
        capture_output=True,
        text=True,
        check=False,
    )

    if result.returncode == 0:
        print(f"ok    {label}")
        return True

    print(f"FAIL  {label}")
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "actions",
        nargs="*",
        default=["action.yml"],
        help="composite action files to check (default: action.yml)",
    )
    parser.add_argument(
        "--shell-file",
        action="append",
        default=[],
        dest="shell_files",
        help="additional standalone shell file to check, may be repeated",
    )
    arguments = parser.parse_args()

    if shutil.which("shellcheck") is None:
        print("shellcheck is not installed", file=sys.stderr)
        return 2

    failures = 0
    checked = 0

    for shell_file in arguments.shell_files:
        path = Path(shell_file)
        if not path.is_file():
            print(f"{path}: not found", file=sys.stderr)
            return 2
        checked += 1
        if not run_shellcheck(path, str(path)):
            failures += 1

    with tempfile.TemporaryDirectory(prefix="lint-steps-") as directory:
        workspace = Path(directory)

        for action in arguments.actions:
            action_path = Path(action)
            if not action_path.is_file():
                print(f"{action_path}: not found", file=sys.stderr)
                return 2

            try:
                steps = collect_steps(action_path)
            except (yaml.YAMLError, ValueError) as error:
                print(f"{error}", file=sys.stderr)
                return 2

            print(f"{action_path}: parsed, {len(steps)} shell step(s)")

            for index, (label, script) in enumerate(steps):
                target = workspace / f"{index:02d}-{slug(label)}.bash"
                # newline="\n" matters: on Windows the default would translate
                # every newline to CRLF and shellcheck would report a literal
                # carriage return on every single line.
                with target.open("w", encoding="utf-8", newline="\n") as handle:
                    handle.write(SHEBANG + replace_expressions(script))
                checked += 1
                if not run_shellcheck(target, label):
                    failures += 1

    print(f"\n{checked} file(s) checked, {failures} with findings")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
