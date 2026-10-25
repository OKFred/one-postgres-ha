# syntax=docker/dockerfile:1
ARG POSTGRES_BASE=postgres:17.11-bookworm@sha256:858bb5e98eed02eb8cafbcdc007f9a65d1b613972028944a8ec2133ccaf80d27
FROM ${POSTGRES_BASE}
ARG DOWNLOAD_SOURCE=official
ENV PATH=/opt/tools/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    ANSIBLE_NOCOLOR=1
COPY --chmod=0555 images/postgres/source-profiles.sh /usr/local/bin/ha-source-profiles
RUN /usr/local/bin/ha-source-profiles --apply "$DOWNLOAD_SOURCE" \
    && apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-venv openssh-client sshpass openssl jq curl \
      shellcheck shfmt git rsync util-linux ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/tools
COPY images/tools/requirements.txt /tmp/requirements.txt
RUN PIP_CONFIG_FILE=/dev/null PIP_EXTRA_INDEX_URL= pip install --index-url "$(/usr/local/bin/ha-source-profiles --pip-url "$DOWNLOAD_SOURCE")" --no-cache-dir -r /tmp/requirements.txt
COPY images/tools/collections.yml /tmp/collections.yml
RUN ansible-galaxy collection install -r /tmp/collections.yml -p /opt/collections
ENV ANSIBLE_COLLECTIONS_PATH=/opt/collections
ENTRYPOINT []
CMD ["ansible-playbook", "--version"]
