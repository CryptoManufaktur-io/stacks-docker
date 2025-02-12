# stacks-docker

Docker compose for the Stacks chain.

Meant to be used with [central-proxy-docker](https://github.com/CryptoManufaktur-io/central-proxy-docker) for traefik
and Prometheus remote write; use `:ext-network.yml` in `COMPOSE_FILE` inside `.env` in that case.

## Node Quick setup

Run `cp default.env .env`, then `nano .env`, and update values like NETWORK, STACKS_NODE_VERSION, and SNAPSHOT.

If you want the consensus node RPC ports exposed locally, use `rpc-shared.yml` in `COMPOSE_FILE` inside `.env`.

- `./stacksd install` brings in docker-ce, if you don't have Docker installed already.
- `./stacksd up`

To update the software, run `./stacksd update` and then `./stacksd up`

## Running a Signer

A private key is required to run the Signer. Create one by running:

```
docker compose run --rm stx make_keychain -t
# '-t' option makes this a testnet account
```

Make sure to backup the output.

The private key should be set as an environment variable, ideally it shouldn't be placed in the .env

```
export SIGNER_PRIVATE_KEY=d6114748969b3186513e9e55ec54666772994fa1d01741a3d147b518931b002501
./stacksd up
```

## Version

Stacks Docker uses a semver scheme.

This is stacks-docker v1.0.0
