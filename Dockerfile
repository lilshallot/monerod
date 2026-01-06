FROM debian:stable-slim

# ----------------------------
# Monero release configuration
# ----------------------------
ARG MONERO_VERSION=0.18.4.4
ARG MONERO_TARBALL=monero-linux-x64-v${MONERO_VERSION}.tar.bz2
ARG MONERO_DOWNLOAD_BASE=https://downloads.getmonero.org/cli

ENV DEBIAN_FRONTEND=noninteractive

# Base deps:
# - curl
# - ca-certificates
# - bzip2: extract
# - tini: clean PID1
# - gosu: drop privileges
# - gnupg/dirmngr: verify GPG-signed hashes.txt
# - findutils: locate monerod path after extraction
# - netcat-openbsd/curl: healthcheck and debugging
# - iptables: optional egress enforcement (requires NET_ADMIN)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl bzip2 tini gosu \
    gnupg dirmngr findutils \
    netcat-openbsd iptables \
  && rm -rf /var/lib/apt/lists/*

# Dedicated user (customizable UID if you rebuild)
RUN useradd -r -m -u 1000 -s /usr/sbin/nologin monero

# ----------------------------
# Download + Verify + Install
# ----------------------------
RUN set -eux; \
  cd /tmp; \
  \
  echo "==[1/6] Download Monero CLI tarball =="; \
  curl -fsSL -o "${MONERO_TARBALL}" "${MONERO_DOWNLOAD_BASE}/${MONERO_TARBALL}"; \
  \
  echo "==[2/6] Download signed hashes list (hashes.txt) =="; \
  curl -fsSLO "https://www.getmonero.org/downloads/hashes.txt"; \
  \
  echo "==[3/6] Import BinaryFate signing key =="; \
  curl -fsSL "https://raw.githubusercontent.com/monero-project/monero/master/utils/gpg_keys/binaryfate.asc" \
    | gpg --batch --import; \
  \
  echo "==[4/6] Verify hashes.txt signature (GPG) =="; \
  gpg --batch --verify hashes.txt; \
  echo "GPG signature OK for hashes"; \
  \
  echo "==[5/6] Verify tarball SHA256 matches hashes.txt =="; \
  TAR_HASH="$(awk -v f="${MONERO_TARBALL}" ' \
      {for (i=1; i<=NF; i++) if ($i==f) {print $(i-1); exit}} \
    ' hashes.txt)"; \
  test -n "${TAR_HASH}"; \
  echo "${TAR_HASH}  ${MONERO_TARBALL}" | sha256sum -c -; \
  echo "SHA256 OK for ${MONERO_TARBALL}"; \
  echo ">>> VERIFICATION CHECKS PASSED FOR MONERO BINARY"; \
  sleep 3; \
  \
  echo "==[6/6] Extract + install monerod =="; \
  tar -xjf "${MONERO_TARBALL}"; \
  MONEROD_PATH="$(find /tmp -maxdepth 4 -type f -name monerod | head -n 1)"; \
  test -n "${MONEROD_PATH}"; \
  cp "${MONEROD_PATH}" /usr/local/bin/monerod; \
  chmod +x /usr/local/bin/monerod; \
  \
  rm -rf /tmp/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/entrypoint.sh"]
