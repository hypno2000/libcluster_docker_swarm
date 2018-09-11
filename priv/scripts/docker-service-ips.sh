#/bin/bash

DOCKER_HOST=$(route | awk '/default/ { print $2 }')
SWARM_MANAGER=$(docker -H $DOCKER_HOST info --format '{{(index .Swarm.RemoteManagers 0).Addr}}' | cut -d : -f 1)

docker -H $SWARM_MANAGER inspect \
$(docker -H $SWARM_MANAGER service ps $1 --filter "desired-state=running" --format '{{.ID}}') \
--format '{{range .NetworksAttachments}}{{if eq .Network.Spec.Name "'$2'"}}{{index .Addresses 0}}{{end}}{{end}}' \
| cut -d / -f 1
