# Thin wrapper around the official `hl-visor` / `hl-node` binary from
# Hyperliquid. No business logic in this image — just the binary, its
# system deps (curl, ca-certificates), s5cmd, and the invocation script
# (run_live.sh).
#
# Downstream consumers read this container's output via a shared
# volume — never spawn this binary directly from the indexer container.
#
# To pin a specific binary version, set HL_BINARY_URL at build time:
#   docker build --build-arg HL_BINARY_URL=https://binaries.hyperliquid.xyz/Mainnet/hl-visor ...
FROM ubuntu:24.04

ARG HL_BINARY_URL=https://binaries.hyperliquid.xyz/Mainnet/hl-visor
ARG S5CMD_VERSION=2.2.2

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates gnupg \
    && rm -rf /var/lib/apt/lists/*

# Vendor binaries (no hl-node symlink — hl-visor downloads hl-node at
# runtime; a symlink to hl-visor would cause `curl -o hl-node` to
# overwrite the visor binary itself).
RUN curl -fsSL "${HL_BINARY_URL}" -o /usr/local/bin/hl-visor \
    && chmod +x /usr/local/bin/hl-visor \
    && curl -fsSL \
        "https://github.com/peak/s5cmd/releases/download/v${S5CMD_VERSION}/s5cmd_${S5CMD_VERSION}_Linux-64bit.tar.gz" \
        | tar xz -C /usr/local/bin s5cmd \
    && curl -fsSL \
        https://raw.githubusercontent.com/hyperliquid-dex/node/main/pub_key.asc \
        -o /usr/local/share/hl_pub_key.asc

# Run as non-root. Pin to UID/GID 1000 so it matches the host owner
# of the bind-mounted ${DATA_DIR}/hl-node-data and /mnt/hl_node_fills
# (which are chown'd to 1000:1000 by the build script's preflight).
# ubuntu:24.04 pre-creates an 'ubuntu' user at 1000 — delete first.
RUN userdel -r ubuntu 2>/dev/null || true
RUN groupadd -g 1000 hluser && useradd -m -u 1000 -g 1000 hluser
# hl-visor downloads hl-node into /usr/local/bin at runtime, so the dir
# must be writable by hluser. Existing binaries (hl-visor, s5cmd, visor.json)
# remain readable + executable by all.
RUN chown -R 1000:1000 /usr/local/bin

USER hluser
WORKDIR /home/hluser

# Import HL's signing key into hluser's gpg keyring so hl-visor's
# runtime `gpg --verify hl-node.asc hl-node` passes. Trust ultimately
# so verifications don't print scary warnings.
RUN gpg --import /usr/local/share/hl_pub_key.asc \
    && echo "CF2C2EA3DC3E8F042A55FB6503254A9349F1820B:6:" | gpg --import-ownertrust

RUN mkdir -p /home/hluser/hl/data /home/hluser/hl/tmp

COPY --chown=hluser:hluser scripts/ /home/hluser/scripts/

# hl-visor reads visor.json from /usr/local/bin/ (alongside the binary),
# NOT from $HOME. Compose mounts override this at runtime to inject
# environment-specific configs without rebuilding.
COPY visor.json /usr/local/bin/visor.json

EXPOSE 4000-4010 3001
# No ENTRYPOINT — `command:` in compose picks scripts/run_live.sh.
