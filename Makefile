.PHONY: up down bootstrap bootstrap-prod bootstrap-management destroy destroy-prod destroy-management

# Whole platform, one command: all three clusters, cross-cluster runner
# credentials, and the host-level setup (Mac<->cluster routing, local DNS,
# CA trust) local HTTPS access needs. Expect a sudo/Touch ID prompt or two.
up:
	./scripts/up.sh

# All three clusters torn down. Host-level setup (docker-mac-net-connect,
# dnsmasq, CA trust) is deliberately left in place -- see scripts/down.sh.
down:
	./scripts/down.sh

bootstrap:
	./scripts/bootstrap.sh dev

bootstrap-prod:
	./scripts/bootstrap.sh prod

bootstrap-management:
	./scripts/bootstrap.sh management

destroy:
	./scripts/teardown.sh dev

destroy-prod:
	./scripts/teardown.sh prod

destroy-management:
	./scripts/teardown.sh management
