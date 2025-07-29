#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f /stacks/.initialized ]]; then
  echo "Initializing!"

  echo "Downloading config..."
  wget https://raw.githubusercontent.com/stacks-network/stacks-core/refs/heads/master/sample/conf/${NETWORK}-signer.toml -O /stacks/config/config.toml

  # Node config.
  dasel put -f /stacks/config/config.toml -v 30 -t int node.pox_sync_sample_secs
  dasel put -f /stacks/config/config.toml -v true -t bool node.always_use_affirmation_maps
  dasel put -f /stacks/config/config.toml -v true -t bool node.require_affirmed_anchor_blocks

  # Update Nakamoto epoch 3.2 start height for testnet only
  if [ "$NETWORK" = "testnet" ]; then
    # Find and update epoch 3.2 start height using sed
    sed -i 's/^start_height = 2100$/start_height = 71525/' /stacks/config/config.toml
  fi

  # Ports config.
  dasel put -f /stacks/config/config.toml -v "/stacks/data" node.working_dir
  dasel put -f /stacks/config/config.toml -v "0.0.0.0:${NODE_RPC_PORT}" node.rpc_bind
  dasel put -f /stacks/config/config.toml -v "0.0.0.0:${NODE_P2P_PORT}" node.p2p_bind
  dasel put -f /stacks/config/config.toml -v "0.0.0.0:${NODE_METRICS_PORT}" node.prometheus_bind

  # Burnchain config.
  if [ "$NETWORK" = "mainnet" ]; then
    __mode="mainnet"
  else
    __mode="krypton"
  fi

  dasel put -f /stacks/config/config.toml -v "${__mode}" burnchain.mode

  # No events observer by default.
  dasel delete -f /stacks/config/config.toml 'events_observer'

  if [ -n "$SNAPSHOT" ]; then
    echo "Downloading snapshot..."
    wget --progress=bar:force:noscroll -O /stacks/snapshot.tar.gz "$SNAPSHOT"

    # Download and verify shasum
    SHASUM_URL="${SNAPSHOT%.tar.gz}.sha256"
    echo "Downloading shasum for verification..."
    wget --progress=bar:force:noscroll -O /stacks/snapshot.sha256 "$SHASUM_URL"

    echo "Verifying snapshot integrity..."
    # Get the expected filename from the sha256 file and replace it with our actual filename
    EXPECTED_HASH=$(cut -d' ' -f1 /stacks/snapshot.sha256)
    ACTUAL_HASH=$(sha256sum /stacks/snapshot.tar.gz | cut -d' ' -f1)

    if [ "$EXPECTED_HASH" = "$ACTUAL_HASH" ]; then
      echo "Snapshot verification successful. Extracting..."
      tar -xzf /stacks/snapshot.tar.gz -C /stacks/data
      rm /stacks/snapshot.tar.gz /stacks/snapshot.sha256
      echo "Snapshot extraction complete."
    else
      echo "Snapshot verification failed. Expected: $EXPECTED_HASH, Got: $ACTUAL_HASH"
      echo "Removing corrupted files..."
      rm -f /stacks/snapshot.tar.gz /stacks/snapshot.sha256
      exit 1
    fi
  else
    echo "No snapshot URL defined."
  fi

  echo "Initialization done!"

  touch /stacks/.initialized
else
  echo "Already initialized!"
fi

# Update burnchain config.
dasel put -f /stacks/config/config.toml -v "${BTC_HOST}" burnchain.peer_host
dasel put -f /stacks/config/config.toml -v "${BTC_USER}" burnchain.username
dasel put -f /stacks/config/config.toml -v "${BTC_PASS}" burnchain.password
dasel put -f /stacks/config/config.toml -v "${BTC_RPC_PORT}" -t int burnchain.rpc_port
dasel put -f /stacks/config/config.toml -v "${BTC_P2P_PORT}" -t int burnchain.peer_port

dasel put -f /stacks/config/config.toml -v "${NODE_AUTH_TOKEN}" connection_options.auth_token

# Update signer/stacker config.
if dasel -f /stacks/config/config.toml 'events_observer' >/dev/null 2>&1; then
  dasel delete -f /stacks/config/config.toml 'events_observer'
fi

dasel put -f /stacks/config/config.toml -v ${NODE_STACKER} -t bool node.stacker

if [ "$NODE_STACKER" = "true" ]; then
  echo "Configuring node to run with signer/stacker..."
  dasel put -f /stacks/config/config.toml -v "${SIGNER_ENDPOINT}:${SIGNER_PORT}" "events_observer.[].endpoint"
  dasel put -f /stacks/config/config.toml -v "stackerdb" "events_observer.[0].events_keys.[]"
  dasel put -f /stacks/config/config.toml -v "block_proposal" "events_observer.[0].events_keys.[]"
  dasel put -f /stacks/config/config.toml -v "burn_blocks" "events_observer.[0].events_keys.[]"
  dasel put -f /stacks/config/config.toml -v 300000 -t int "events_observer.[0].timeout_ms"
fi

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${EXTRAS}
