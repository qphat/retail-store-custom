# UI Service

| Language | Framework | Port |
|---|---|---|
| Java 21 | Spring Boot | 8080 |

Frontend gateway for the retail store. Serves the HTML UI and proxies calls to all backend services (catalog, cart, orders, checkout).

## Running

### Local

Requires Java 21.

```bash
./mvnw spring-boot:run
```

Open `http://localhost:8080`.

### Docker Compose (single service)

Runs UI with all backend services using in-memory persistence — no external databases needed.

```bash
docker compose up --build
```

Open `http://localhost:8888`.

```bash
docker compose down
```

### Docker Compose (with observability)

Same as above but also starts Prometheus, Grafana, and ELK stack.

```bash
docker compose up --build
```

| Service | URL | Credentials |
|---|---|---|
| UI | http://localhost:8888 | — |
| Prometheus | http://localhost:9090 | — |
| Grafana | http://localhost:3000 | admin / admin |
| Kibana | http://localhost:5601 | — |

## Configuration

| Variable | Description | Default |
|---|---|---|
| `RETAIL_UI_ENDPOINTS_CATALOG` | Catalog service URL | `false` (mock) |
| `RETAIL_UI_ENDPOINTS_CARTS` | Cart service URL | `false` (mock) |
| `RETAIL_UI_ENDPOINTS_ORDERS` | Orders service URL | `false` (mock) |
| `RETAIL_UI_ENDPOINTS_CHECKOUT` | Checkout service URL | `false` (mock) |
| `RETAIL_UI_THEME` | UI theme: `default`, `green`, `orange`, `teal` | `default` |
| `RETAIL_UI_DISABLE_DEMO_WARNINGS` | Hide demo warning banners | `false` |
| `RETAIL_UI_PRODUCT_IMAGES_PATH` | Override product image source path | — |
| `RETAIL_UI_CHAT_ENABLED` | Enable AI chat bot | `false` |
| `RETAIL_UI_CHAT_PROVIDER` | Chat provider: `bedrock`, `openai`, `mock` | — |
| `RETAIL_UI_CHAT_MODEL` | Model name (depends on provider) | — |
| `RETAIL_UI_CHAT_TEMPERATURE` | Model temperature | `0.6` |
| `RETAIL_UI_CHAT_MAX_TOKENS` | Max response tokens | `300` |
| `RETAIL_UI_CHAT_BEDROCK_REGION` | AWS region for Bedrock | — |
| `RETAIL_UI_CHAT_OPENAI_BASE_URL` | Base URL for OpenAI-compatible endpoint | — |
| `RETAIL_UI_CHAT_OPENAI_API_KEY` | API key for OpenAI endpoint | — |

Setting an endpoint to `false` enables a mock implementation — useful for running the UI standalone without backend services.

## Utility Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/utility/status/{code}` | Return any HTTP status code |
| `GET` | `/utility/headers` | Echo request headers |
| `GET` | `/utility/panic` | Crash the application |
| `POST` | `/utility/echo` | Echo the request body |
| `GET` | `/utility/stress/{iterations}` | CPU stress test |
| `POST` | `/utility/store` | Write payload to disk, return hash |
| `GET` | `/utility/store/{hash}` | Read payload from disk by hash |

## Observability

- Metrics: `GET /actuator/prometheus`
- Health: `GET /actuator/health`
- Info: `GET /actuator/info`
