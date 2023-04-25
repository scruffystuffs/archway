#! /usr/bin/env python3

import argparse
import os
from pathlib import Path
import re
import shutil
import sys

DEFAULT_FILE = "/etc/mkinitcpio.conf"
LVM_BOOT_HOOK = "lvm2"
ENCRYPT_BOOT_HOOK = "encrypt"


def eprint(*args, **kwargs):
    kwargs["file"] = sys.stderr
    print(*args, **kwargs)


def add_boot_hooks(
    input_file: os.PathLike, output_file: os.PathLike, lvm=False, encrypt=False
):
    if not lvm and not encrypt:
        # Early exit if there's nothing to add
        eprint("No hooks to add")
        return

    backup = f"{output_file}.bak"
    if Path(output_file).is_file():
        # Make a backup of anything that's currently there.
        eprint(f'Backing up: {output_file}')
        shutil.copy(output_file, backup)

    eprint(f'Reading input file: {input_file}')
    with open(input_file, encoding="ascii") as conf_fp:
        contents = conf_fp.read()

    # Find the uncommented HOOKS line
    hook_match = re.search(r"^HOOKS=\((.*?)\)$", contents, re.MULTILINE)
    assert hook_match, "No HOOKS line found, did you point at the right file?"

    # Get everything else in the file, so we can edit instead of rewriting
    head = contents[: hook_match.start()]
    tail = contents[hook_match.end() :]

    # Rewrite the HOOKS line
    hooks = hook_match[1].split()
    block_index = hooks.index("block")
    if lvm and LVM_BOOT_HOOK not in hooks:
        hooks.insert(block_index + 1, LVM_BOOT_HOOK)
    if encrypt and ENCRYPT_BOOT_HOOK not in hooks:
        hooks.insert(block_index + 1, ENCRYPT_BOOT_HOOK)
    hook_str = f"HOOKS=({' '.join(hooks)})"

    # Write the new file
    # If there already was one, we backed it up earlier.
    eprint(f"Writing output file: {output_file}")
    with open(output_file, "w", encoding="ascii") as output_fp:
        output_fp.write(head)
        output_fp.write(hook_str)
        output_fp.write(tail)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-l", "--lvm2", action="store_true")
    parser.add_argument("-e", "--encrypt", action="store_true")
    parser.add_argument(
        "input",
        nargs="?",
        metavar="INPUT_FILE",
        default=DEFAULT_FILE,
        help=f"Default: {DEFAULT_FILE}",
    )
    parser.add_argument(
        "output", nargs="?", metavar="OUTPUT_FILE", help="Same as input if unspecified"
    )
    args = parser.parse_args()
    input_file = args.input
    output_file = args.output
    if output_file is None:
        output_file = input_file
    add_boot_hooks(input_file, output_file, lvm=args.lvm2, encrypt=args.encrypt)


if __name__ == "__main__":
    main()
