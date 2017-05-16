all: network.json.team.patch

network.json.team.patch: network.json.team
	diff -Naur network.json.original $^ > $@ || true
	sed -i -e 's/$^/network.json/' $@
