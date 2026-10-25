# syntax=docker/dockerfile:1
ARG POSTGRES_BASE_IMAGE=postgres:17.11-bookworm@sha256:858bb5e98eed02eb8cafbcdc007f9a65d1b613972028944a8ec2133ccaf80d27
FROM ${POSTGRES_BASE_IMAGE} AS dependencies
USER root
ARG DOWNLOAD_SOURCE=official
COPY --chmod=0555 source-profiles.sh /usr/local/bin/ha-source-profiles
RUN /usr/local/bin/ha-source-profiles --apply "$DOWNLOAD_SOURCE" \
    && apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-venv ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/patroni
COPY build-requirements.lock requirements.lock /tmp/
RUN PIP_CONFIG_FILE=/dev/null PIP_EXTRA_INDEX_URL= /opt/patroni/bin/pip install --index-url "$(/usr/local/bin/ha-source-profiles --pip-url "$DOWNLOAD_SOURCE")" --no-cache-dir --require-hashes -r /tmp/build-requirements.lock \
    && PIP_CONFIG_FILE=/dev/null PIP_EXTRA_INDEX_URL= /opt/patroni/bin/pip install --index-url "$(/usr/local/bin/ha-source-profiles --pip-url "$DOWNLOAD_SOURCE")" --no-cache-dir --no-build-isolation --require-hashes -r /tmp/requirements.lock \
    && /opt/patroni/bin/pip check

FROM ${POSTGRES_BASE_IMAGE}
USER root
ARG DOWNLOAD_SOURCE=official
COPY --chmod=0555 source-profiles.sh /usr/local/bin/ha-source-profiles
RUN /usr/local/bin/ha-source-profiles --apply "$DOWNLOAD_SOURCE" \
    && apt-get update \
    && apt-get install -y --no-install-recommends python3 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && install -d -o 999 -g 999 -m 0700 /run/patroni \
    && install -d -o 999 -g 999 -m 0770 /run/postgresql \
    && install -d -o 999 -g 999 -m 0700 /var/lib/postgresql/data
COPY --from=dependencies /opt/patroni /opt/patroni
COPY --chmod=0555 entrypoint.sh /usr/local/bin/patroni-entrypoint
COPY --chmod=0555 healthcheck.sh /usr/local/bin/patroni-healthcheck
COPY --chmod=0555 pg-admin.sh /usr/local/bin/pg-admin
ENV PATH="/opt/patroni/bin:${PATH}" \
    PGDATA=/var/lib/postgresql/data \
    PATRONI_CONFIG_FILE=/etc/one-postgres-ha/patroni.yml \
    PYTHONDONTWRITEBYTECODE=1
USER 999:999
ENTRYPOINT ["/usr/local/bin/patroni-entrypoint"]
CMD ["patroni", "/etc/one-postgres-ha/patroni.yml"]
HEALTHCHECK --interval=10s --timeout=5s --start-period=120s CMD ["/usr/local/bin/patroni-healthcheck"]
LABEL org.opencontainers.image.title="one-postgres-ha" \
    org.opencontainers.image.description="PostgreSQL 17.11 with Patroni 4.1.5; non-root, file credentials, external etcd3"
