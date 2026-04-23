#!/bin/bash
set -e

if ! brew list sdl3 &>/dev/null; then
  echo "SDL3 not found. Install it with: brew install sdl3"
  exit 1
fi

mkdir -p build
rsync -a --delete minesweeper/resources/ build/resources/
odin build minesweeper/minesweeper.odin -file -debug -vet -out:build/minesweeper
