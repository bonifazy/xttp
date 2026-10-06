#!/usr/bin/env bash
set -euo pipefail

# 23:59 — обнулить журнал xray, чтобы следующий календарный день
# писался с нуля. journald хранит юниты в общих файлах и не умеет
# vacuum только xray: rotate закрывает текущий журнал, vacuum-time=1s
# удаляет архив. Активный файл после этого пустой.
journalctl --rotate
journalctl --quiet --vacuum-time=1s || true
