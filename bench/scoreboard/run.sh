#!/usr/bin/env bash
# bench/scoreboard/run.sh [--rows id,id] [--runs 3] [--side node|facil|both] [--quick] [--list]   (--help for all options)
exec python3 "$(dirname "$0")/driver.py" "$@"
