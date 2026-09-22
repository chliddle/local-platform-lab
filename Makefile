.PHONY: bootstrap bootstrap-prod destroy destroy-prod

bootstrap:
	./scripts/bootstrap.sh dev

bootstrap-prod:
	./scripts/bootstrap.sh prod

destroy:
	./scripts/teardown.sh dev

destroy-prod:
	./scripts/teardown.sh prod
