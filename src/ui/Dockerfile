# Build Stage
FROM maven:3.9-eclipse-temurin-21 AS build-env

WORKDIR /app

# Cache dependencies before copying source
COPY .mvn .mvn
COPY mvnw .
COPY pom.xml .
RUN ./mvnw dependency:go-offline -B -q

# Build jar
COPY ./src ./src
RUN ./mvnw -DskipTests package -q && \
    mv target/*.jar /app.jar

# Run Stage
FROM eclipse-temurin:21-jre-jammy

# Install curl for healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -g 1000 appgroup && useradd -u 1000 -g appgroup -m appuser

ENV SPRING_PROFILES_ACTIVE=prod
# JVM tuning: container-aware memory, G1GC, crash on OOM
ENV JAVA_TOOL_OPTIONS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -XX:+UseG1GC -XX:+ExitOnOutOfMemoryError"

WORKDIR /app
USER appuser

COPY --chown=appuser:appgroup --from=build-env /app.jar .

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=5s --retries=3 --start-period=30s \
    CMD curl -f http://localhost:8080/actuator/health || exit 1

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
