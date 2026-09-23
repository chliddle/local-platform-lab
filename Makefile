.PHONY: bootstrap bootstrap-prod bootstrap-management destroy destroy-prod destroy-management

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
