#!/usr/bin/env bash
set -euo pipefail

# every stack under /srv that has a service named "db" gets dumped; nothing registers
trap 'rm -f /var/backups/*/*.part' EXIT

for compose in /srv/*/compose.yaml; do
	dir=$(dirname "$compose")
	name=$(basename "$dir")

	docker compose --project-directory "$dir" config --services | grep -qx db || continue

	mkdir -p "/var/backups/$name"
	out="/var/backups/$name/$name-$(date +%F).sql.gz"

	docker compose --project-directory "$dir" exec -T db \
		sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' | gzip >"$out.part"
	mv "$out.part" "$out"

	find "/var/backups/$name" -name "$name-*.sql.gz" -mtime +7 -delete
done

docker image prune -f --filter until=720h
