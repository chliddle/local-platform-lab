.PHONY: bootstrap bootstrap-prod destroy destroy-prod

bootstrap:
	./scripts/bootstrap.sh dev

bootstrap-prod:
	./scripts/bootstrap.sh prod

destroy:
	terraform -chdir=terraform/environments/dev destroy

destroy-prod:
	terraform -chdir=terraform/environments/prod destroy
