FROM golang:1.24-alpine AS build-env

WORKDIR /app

RUN apk add --no-cache gcc musl-dev

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=1 go build -o main main.go

FROM alpine:3.20

RUN apk add --no-cache sqlite-libs
RUN adduser -D appuser

USER appuser
WORKDIR /app

COPY --from=build-env /app/main .

EXPOSE 8080
ENTRYPOINT ["./main"]