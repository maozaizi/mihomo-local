ARG BASE=debian:13-slim
FROM ${BASE}
RUN apt-get update && apt-get install -y --no-install-recommends python3 curl ca-certificates unzip util-linux coreutils iproute2 bash zsh systemd && rm -rf /var/lib/apt/lists/*
