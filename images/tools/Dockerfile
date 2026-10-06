# syntax=docker/dockerfile:1
ARG POSTGRES_BASE=postgres:18.6-bookworm@sha256:3725f4e2499eef5134592b3b4ab79a543ed7f8e533b05b5b637af926630f6650
FROM ${POSTGRES_BASE}
ENV PATH=/opt/tools/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    ANSIBLE_NOCOLOR=1
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-venv openssh-client sshpass openssl jq curl \
      shellcheck shfmt git rsync util-linux ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/tools
COPY images/tools/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt
COPY images/tools/collections.yml /tmp/collections.yml
RUN ansible-galaxy collection install -r /tmp/collections.yml -p /opt/collections
ENV ANSIBLE_COLLECTIONS_PATH=/opt/collections
ENTRYPOINT []
CMD ["ansible-playbook", "--version"]
