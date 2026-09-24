.PHONY: up down bootstrap bootstrap-prod destroy destroy-prod

# Whole platform, one command: both clusters, the cross-cluster runner
# credential dev needs to check prod, and the host-level setup (Mac<->cluster
# routing, local DNS, CA trust) local HTTPS access needs. Expect a
# sudo/Touch ID prompt or two.
up:
	./scripts/up.sh

# Both clusters torn down. Host-level setup (docker-mac-net-connect,
# dnsmasq, CA trust) is deliberately left in place -- see scripts/down.sh.
down:
	./scripts/down.sh

bootstrap:
	./scripts/bootstrap.sh dev

bootstrap-prod:
	./scripts/bootstrap.sh prod

destroy:
	./scripts/teardown.sh dev

destroy-prod:
	./scripts/teardown.sh prod
