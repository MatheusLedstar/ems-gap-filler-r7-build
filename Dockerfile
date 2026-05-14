# Build multi-stage: usa imagem maven (o repo NAO versiona o Maven Wrapper -
# .mvn/ e mvnw estao no .gitignore, entao o build via ./mvnw quebrava aqui).
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build
COPY pom.xml ./
# baixa dependencias primeiro pra aproveitar cache de layer
RUN mvn -B -q -DskipTests dependency:go-offline
COPY src ./src
RUN mvn -B -q -DskipTests package

# Runtime enxuto - JRE 21 Alpine + TZ Manaus (mesmo do banco EMS)
FROM eclipse-temurin:21-jre-alpine
RUN addgroup -S app && adduser -S app -G app && \
    apk add --no-cache curl tzdata wget && \
    cp /usr/share/zoneinfo/America/Manaus /etc/localtime && \
    echo "America/Manaus" > /etc/timezone
ENV TZ=America/Manaus
WORKDIR /app
COPY --from=build /build/target/*.jar app.jar
USER app
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s \
    CMD curl -fs http://localhost:8080/actuator/health || exit 1
ENTRYPOINT ["java","-XX:MaxRAMPercentage=75.0","-jar","/app/app.jar"]
