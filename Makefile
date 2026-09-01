.PHONY: help analyze test test-app test-api dev-api dev-app clean

help:
	@echo "Skyward Monorepo Commands:"
	@echo "  make analyze   - Run static analysis on Flutter app"
	@echo "  make test      - Run all tests (Flutter & Go)"
	@echo "  make test-app  - Run Flutter tests"
	@echo "  make test-api  - Run Go backend tests"
	@echo "  make dev-api   - Run Go backend API locally"
	@echo "  make dev-app   - Run Flutter app locally"

analyze:
	@echo "==> Running Flutter analyze..."
	cd apps/app && flutter analyze

test-app:
	@echo "==> Running Flutter unit/widget tests..."
	cd apps/app && flutter test

test-api:
	@echo "==> Running Go backend unit tests..."
	cd apps/api && go test ./...

test: test-api test-app

dev-api:
	@echo "==> Starting Go API backend on localhost:8090..."
	cd apps/api && go run ./cmd/server

dev-app:
	@echo "==> Starting Flutter app..."
	cd apps/app && flutter run

clean:
	cd apps/app && flutter clean
