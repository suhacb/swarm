# Pre-builds Keycloak's Quarkus augmentation at image-build time instead of
# container-start time. Plain `kc.sh start` re-runs this build on every boot,
# which spikes memory during startup — risky when the container is capped at
# 750M. Building here lets the stack use `kc.sh start --optimized`, which
# skips that phase entirely.
#
# Rebuild after bumping the Keycloak version or changing build-time options:
#   docker build -t local/keycloak:26.0-optimized -f images/keycloak/Dockerfile .
FROM quay.io/keycloak/keycloak:26.0

# Build-time options (baked into the optimized distribution, cannot be
# changed with env vars at runtime — connection details like host/user/
# password ARE runtime and belong in the stack file instead).
ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true

RUN /opt/keycloak/bin/kc.sh build
