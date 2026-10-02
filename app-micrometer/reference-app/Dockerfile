# Cross-build senza qemu: il bytecode Java e' portabile, quindi la fase di BUILD
# gira sull'architettura nativa dell'host (veloce) e SOLO il JRE runtime viene preso
# per l'architettura target. Lancia la build con:
#   podman build --platform=linux/amd64 -t <IMG> .
#   (TARGETPLATFORM=linux/amd64, BUILDPLATFORM=linux/arm64 sul tuo Mac)

# Stage 1: build (nativa sull'host: niente emulazione, mvn/java girano su arm64)
FROM --platform=$BUILDPLATFORM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /build
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B package -DskipTests

# Stage 2: runtime (JRE per l'architettura dei nodi = amd64; qui NON c'e' alcun RUN,
# quindi non serve qemu: il file giunto viene solo copiato nel filesystem amd64)
FROM --platform=$TARGETPLATFORM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /build/target/micrometer-otlp-demo.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
