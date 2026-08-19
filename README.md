# homelab

One VPS (2 GB RAM, Debian 13), Docker Compose. This repo is the host: packages, firewall, swap, SSH,
backups, and the Caddy that terminates TLS for everything. Read [`site.yml`](site.yml) for what is
installed — below is only what it cannot say.

Services live in their own repos and deploy themselves. This playbook never writes under
`/srv/<service>/`.

## The contract

A service is anything that follows these four conventions. Nothing registers, nothing is configured
here per service.

| Convention                             | Effect                                       |
|----------------------------------------|----------------------------------------------|
| `/srv/<name>/compose.yaml` exists      | it is a service                              |
| its containers join the `edge` network | Caddy can reach them                         |
| `/srv/edge/sites/<name>.caddy` exists  | its domains and routes                       |
| its stack has a service named `db`     | nightly `pg_dump` into `/var/backups/<name>` |

## Adding a service

In the service's own repo, ship three files and a playbook that copies them.

`compose.yaml` — the alias is what Caddy addresses, so it has to be unique across the box:

```yaml
services:
  app:
    networks:
      default:
      edge:
        aliases: [ my-service ]
  db:
    image: postgres:18   # no networks key: stays on default, unreachable from edge

networks:
  edge:
    external: true
```

`site.caddy` — copied to `/srv/edge/sites/<name>.caddy`:

```caddyfile
my-service.example.com {
	import common
	reverse_proxy my-service:8080
}
```

`deploy.yml` — copy the files, then `docker compose up -d --wait`, then reload Caddy:

```yaml
- name: Reload Caddy
  ansible.builtin.command: docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile
  args:
    chdir: /srv/edge
  changed_when: true
```

See [`knobel-manager-service`](https://github.com/henok321/knobel-manager-service/tree/main/deploy) for
a complete one.

A broken snippet cannot take the box down: `caddy reload` validates first and keeps serving the old
config if the new one does not parse.

**Give each service its own Postgres.** A shared instance means a superuser secret two repos need,
role provisioning that has to live somewhere, and one major bump that breaks everything at once. A
`db` container costs ~120 MB. Revisit when the box actually runs out of RAM, not before.

## Bootstrap a new VPS

1. Debian 13 image, root SSH key in the provider's "SSH key" field
2. DNS `A` record per service domain → the IPv4 (INWX: *Domains → knobel-manager.de → Nameserver/DNS*)
3. GitHub: the variables and secrets [below](#github-secrets-and-variables)
4. Push to `main`, then deploy each service repo

CI is `root` because config management cannot run behind a forced `command=` — so push access to
`main` in this repo *or in any service repo* is root access to the box. The docker group is
root-equivalent, so there is no cheaper boundary to move to; the split between this repo and the
service repos is about ownership, not privilege.

To run it yourself:

```bash
pipx install --include-deps ansible
export ACME_EMAIL=...
ansible-playbook -i "<vps>," -u root site.yml
```

Settings are `vars` at the top of the playbook, overridable per run: `-e swap_size=4G`.

## Cutover from the combined stack

The box ran one Compose project that also owned Caddy. Nothing has to be migrated: the project name
comes from the directory, so `/srv/knobel-manager` keeps producing `knobel-manager_db-data` and Postgres
never notices the split. **Do not reset the VPS** — that is the one action that would cost the database.

Only Caddy moves projects, so its certificates are re-issued into a fresh `edge_caddy-data` volume. One
issuance against a limit of five per domain per week.

1. Free port 80/443 — the old Caddy belongs to the service's project, so the edge stack cannot bind
   while it runs. The API is down from here until step 3:

   ```bash
   ssh root@<vps> 'cd /srv/knobel-manager && docker compose rm -sf caddy'
   ```

2. Push this repo. Caddy comes up with an empty `sites/`, serving nothing yet.
3. Push `knobel-manager-service`. Its snippet lands, Caddy reloads, the certificate is issued.
4. Clean up what the old project left behind:

   ```bash
   ssh root@<vps> 'docker volume rm knobel-manager_caddy-data'
   ```

## Traps

- **Add no AAAA record** unless the VPS has working IPv6 — a dangling one hangs clients and the ACME
  challenge on v6 first. Never use INWX *Weiterleitung*: it proxies HTTP and breaks the challenge.
- **Keep port 80 open.** It is the ACME challenge, not just the redirect. Certs live in the
  `edge_caddy-data` volume; deleting it means re-issuing against a limit of 5 per domain per week.
- **ufw does not cover published container ports.** Docker's iptables rules in the `DOCKER` chain are
  evaluated first, so `"5432:5432"` is world-open even with `ufw deny`. The `127.0.0.1:` prefix is
  what keeps a port private.
- **HSTS belongs in the `Caddyfile`.** Apps behind the proxy see `r.TLS == nil` and will not emit it
  themselves — that is what `import common` is for.

## Backups

Nightly at 03:15, 7 kept per service, in `/var/backups/<name>`. Nothing copies them off the disk and
nothing reports a failed one. Restore:

```bash
cd /srv/<name>
gunzip -c /var/backups/<name>/<name>-2026-08-17.sql.gz \
  | docker compose exec -T db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

## GitHub secrets and variables

| Name           | Kind     | Value                                            |
|----------------|----------|--------------------------------------------------|
| `VPS_HOST`     | variable | server IP or hostname                            |
| `VPS_HOST_KEY` | variable | `ssh-keyscan -t ed25519 <host>` output, one line |
| `ACME_EMAIL`   | variable | contact address for Let's Encrypt                |
| `VPS_SSH_KEY`  | secret   | private key for `root` on the VPS                |

Service repos need the same three connection values plus their own secrets.
