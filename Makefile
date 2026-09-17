.PHONY: bootstrap destroy

bootstrap:
	./scripts/bootstrap.sh

destroy:
	terraform -chdir=terraform/environments/dev destroy
