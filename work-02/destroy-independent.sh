#!/usr/bin/env bash
set -euo pipefail

PREFIX=boldyrev-04

delete_prefixed() {
  local resources_json names name
  resources_json=$(yc "$@" list --format json)
  names=$(jq -r --arg prefix "$PREFIX-" \
    '.[] | .name | select(startswith($prefix))' <<< "$resources_json")

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    yc "$@" delete "$name"
  done <<< "$names"
}

# Удаляем сначала ресурсы, которые ссылаются на другие.
delete_prefixed load-balancer network-load-balancer
delete_prefixed load-balancer target-group
delete_prefixed compute instance
delete_prefixed compute disk
delete_prefixed vpc subnet
delete_prefixed vpc network

echo "==> ресурсы с префиксом $PREFIX удалены"
