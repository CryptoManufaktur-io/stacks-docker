#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f /signer/.initialized ]]; then
  echo "Initializing!"

  echo "Downloading config..."
  wget https://raw.githubusercontent.com/stacks-network/stacks-blockchain-docker/refs/heads/master/conf/${NETWORK}/Signer.toml.sample -O /signer/config/config.toml

  dasel put -f /signer/config/config.toml -v "${NETWORK}" network
  dasel put -f /signer/config/config.toml -v /signer/data/signer.sqlite db_path

  echo "Initialization done!"

  touch /signer/.initialized
else
  echo "Already initialized!"
fi

# Always update ports.
dasel put -f /signer/config/config.toml -v "node:${NODE_RPC_PORT}" node_host
dasel put -f /signer/config/config.toml -v "0.0.0.0:${SIGNER_PORT}" endoint
dasel put -f /signer/config/config.toml -v "0.0.0.0:${SIGNER_METRICS_PORT}" metrics_endpoint

dasel put -f /signer/config/config.toml -v "${NODE_AUTH_TOKEN}" auth_password
dasel put -f /signer/config/config.toml -v "${SIGNER_PRIVATE_KEY}" stacks_private_key

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@"
