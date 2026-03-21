#!/bin/sh
# SPDX-FileCopyrightText: 2023 Richard Masters <grick23@gmail.com>
# SPDX-License-Identifier: MIT
#
# Generate a builder-hex0 shell script that loads a hex0 file,
# compiles it to /dev/hda, and flushes.
#
# Usage: hex0-to-src.sh <file.hex0>
# Output goes to stdout.

HEX0="$1"

echo "src 0 /dev"
printf "src "
wc -c < "$HEX0" | tr -d ' '
printf " %s\n" "$HEX0"
cat "$HEX0"
echo "hex0 $HEX0 /dev/hda"
echo "f"
