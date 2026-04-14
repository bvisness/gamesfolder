@echo off

if not exist SDL3.dll (
  echo SDL3.dll not found in current directory.
  exit /b 1
)
if not exist build mkdir build
copy SDL3.dll build\SDL3.dll
odin build minesweeper.odin -file -vet -out:build\minesweeper.exe
