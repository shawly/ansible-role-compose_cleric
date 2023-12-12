# shawly.compose_cleric

An Ansible role for spinning up a service that checks for unhealthy containers and restarts them. This is similar to [willfarrell/docker-autoheal](https://github.com/willfarrell/docker-autoheal) but it runs as systemd service unit.

It also checks if a compose service uses the network of another container and runs `docker compose up -d` instead if the linked container doesn't exist anymore.
This should circumvent problems like [this one](https://github.com/qdm12/gluetun/issues/641). It's certainly not as cool as deunhealth or autoheal because it doesn't yet have notifications and other fancy stuff, but I didn't really need that.

Also check out my [`shawly.compose_artificer`](https://github.com/shawly/ansible-role-compose_artificer) role which automatically sets the cleric labels to all containers in a compose stack.

## Role Variables

- `compose_cleric_install_dir` - The directory where the cleric.sh script is installed.
  - Default: `/opt/compose_cleric`
- `compose_cleric_service_dir` - The directory where the compose-cleric.service is installed.
  - Default: `/lib/systemd/system`

## Usage

After installing, you only need to add `de.shawly.compose.cleric.enabled=true` to your container labels and compose cleric will handle restarts for you.

Available labels are:

- `de.shawly.compose.cleric.enabled` - Will enable compose-cleric if set to `true`.
- `de.shawly.compose.cleric.monitor-only` - Will only monitor the container and log if it is unhealthy when set to `true`.
- `de.shawly.compose.cleric.restart-limit` - Per default, cleric will stop revival attempts after 10 restarts, with this label you can increase or decrease that value.
- `de.shawly.compose.cleric.restart-limit-cmd` - If the restart limit has been reached, the default is "ignored" so cleric will simply ignore the containers state. You can change this to any docker command like "restart", "stop" or "kill", if you set it to restart, cleric will restart the container infinitely!
- `de.shawly.compose.cleric.restart-wait` - Time before the container is restarted in seconds, afterwards a last healthcheck will be done before restarting. The default is 15 seconds, with this label you can increase or decrease that value.

## Installation without Ansible

You can install the role without Ansible by simply copying `files/cleric.sh` to `/opt/compose_cleric/cleric.sh`.

And create a `compose-cleric.service` file in `/lib/systemd/system` with the following content:

```ini
[Unit]
Description=Docker Compose Cleric
Wants=docker.socket
After=docker.service

[Service]
Type=simple
ExecStart=/opt/compose_cleric/cleric.sh
KillSignal=SIGINT
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Afterwards you can run `systemctl daemon-reload` and `systemctl enable --now compose-cleric.service` to enable and start the service.
