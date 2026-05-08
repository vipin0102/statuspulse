APP_NAME=statuspulse
COMPOSE=docker compose

build:
	$(COMPOSE) build

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f

test:
	curl -f http://localhost:8000/health

clean:
	$(COMPOSE) down -v --rmi all --remove-orphans

shell:
	docker exec -it statuspulse-app bash