FROM maven:3.9-eclipse-temurin-21 AS provider-build
WORKDIR /provider
COPY deploy/keycloak/pin-provider/pom.xml .
COPY deploy/keycloak/pin-provider/src ./src
RUN mvn -B -ntp package

FROM quay.io/keycloak/keycloak:26.8.1
ENV KC_DB=postgres KC_HEALTH_ENABLED=true KC_METRICS_ENABLED=true
COPY --from=provider-build /provider/target/nephos-keycloak-pin-provider.jar /opt/keycloak/providers/
RUN /opt/keycloak/bin/kc.sh build
