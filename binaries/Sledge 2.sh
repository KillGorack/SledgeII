#!/bin/sh
printf '\033c\033]0;%s\a' Sledge 2
base_path="$(dirname "$(realpath "$0")")"
"$base_path/Sledge 2.x86_64" "$@"
