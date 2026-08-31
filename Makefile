.PHONY: lint fmt test test-deploy typecheck demo-remote-sandbox demo-remote-sandbox-teardown

lint:
	pre-commit run --all-files

fmt:
	pnpm exec prettier --write .

test:
	pnpm -r test
	cd remote-worker && go test ./...
	$(MAKE) test-deploy

# Cluster-free unit tests for the deploy/ shell scripts: kubectl, kind and docker are
# mocked on PATH and only the call log is asserted. Run in CI by the `deploy-scripts` job.
# `set -e` so one failing test file fails the target instead of being scrolled past.
test-deploy:
	@set -e; for t in deploy/knative/tests/*.test.sh; do echo "== $$t"; bash "$$t"; done

typecheck:
	cd harness && pnpm exec tsc --noEmit
	cd packages/k8s-sandbox && pnpm exec tsc --noEmit
	cd packages/knative-server && pnpm exec tsc --noEmit
	cd experiments && pnpm exec tsc --noEmit

# Laptop showcase: harness on kind, remote worker as a host container dialing out.
# See deploy/knative/README-worker.md. Add --reuse-cluster to skip setup on a warm cluster.
demo-remote-sandbox:
	bash deploy/knative/demo-remote-worker.sh $(DEMO_ARGS)

demo-remote-sandbox-teardown:
	bash deploy/knative/demo-remote-worker.sh --teardown
