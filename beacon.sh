#!/bin/bash

read -p "Node type: lighthouse (rust - best performance) or lodestar (nodejs - stable) or prysm (golang): (lighthouse/lodestar/prysm) " node_type
if [ "$node_type" != "lodestar" ] && [ "$node_type" != "prysm" ] && [ "$node_type" != "lighthouse" ]; then
  echo "Invalid node type!"
  exit 1
fi

read -p "mainnet or testnet: " network
if [ "$network" != "mainnet" ] && [ "$network" != "testnet" ]; then
  echo "Invalid network!"
  exit 1
fi

rm -rf /canxium
mkdir -p /canxium

echo "Installing golang..."
sudo apt update
sudo apt install snapd -y
export PATH=$PATH:/snap/bin
sudo snap install go --channel=1.22 --classic
echo "Installing system packages..."
sudo apt install build-essential -y
sudo apt install git -y
sudo apt install unzip -y

systemctl stop node
systemctl stop beacon
echo "Installing native packages and build..."
if [ "$node_type" = "lodestar" ]; then
  echo "Installing nodejs..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
  curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
  echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
  sudo apt update
  sudo apt install --no-install-recommends yarn -y
fi

if [ "$node_type" = "lighthouse" ]; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  source "$HOME/.cargo/env"
  sudo apt install libclang-dev -y
  sudo apt install cmake -y
  git clone https://github.com/canxium/lighthouse.git /canxium/lighthouse
  cd /canxium/lighthouse
  make
  cd ~
fi

git clone https://github.com/canxium/go-canxium.git /canxium/go-canxium
  cd /canxium/go-canxium
  git checkout v0.3.4
  make canxium

cd ~
if [ "$node_type" = "lodestar" ]; then
  git clone https://github.com/canxium/lodestar.git /canxium/lodestar
  cd /canxium/lodestar
  yarn install
  yarn build
  cd ~
fi
if [ "$node_type" = "prysm" ]; then
  git clone https://github.com/canxium/prysm.git /canxium/prysm
  cd /canxium/prysm
  go build -o=./build/bin/beacon-chain ./cmd/beacon-chain && go build -o=./build/bin/validator ./cmd/validator
  cd ~
fi

# init and run
openssl rand -hex 32 | tr -d "\n" > "/canxium/jwt.hex"
mkdir -p /canxium/logs
if [ "$network" = "testnet" ]; then
  /canxium/go-canxium/build/bin/canxium --datadir=/canxium/chain --db.engine=pebble init /canxium/go-canxium/genesis/praseody.genesis.json
  echo "[Unit]
    Description=PraseOdy Node

    [Service]
    User=root
    WorkingDirectory=/root
    ExecStart=/canxium/go-canxium/build/bin/canxium --http --db.engine=pebble --syncmode full --authrpc.addr 127.0.0.1 --authrpc.jwtsecret=/canxium/jwt.hex --networkid 30203 --datadir /canxium/chain --bootnodes enode://b9281bc8cb07e4f997b5ae7a6cd07e0ab7018c9706aa5507d26c85e89c49c0144ebc1387def54c5346bb3c30ade2dbbdcdcf93a00ae570cb7bc74c87a9a29bae@15.235.141.136:30303,enode://ae595f3bf878303010d69a3002b8db183c98275b91d67bb9657144d19465c3c91b71ee12e5ad9547ecc1c97fc2938c1c0982744d0d72ccabd864365f4d94912f@195.35.45.155:30303
    Restart=always

    [Install]
    WantedBy=multi-user.target" > /etc/systemd/system/node.service
  systemctl enable node
  systemctl start node
  
  if [ "$node_type" = "lodestar" ]; then
    echo "[Unit]
      Description=PraseOdy Lodestar Node

      [Service]
      User=root
      WorkingDirectory=/canxium/lodestar
      ExecStart=/canxium/lodestar/lodestar beacon --network praseody --dataDir /canxium/beacon --rest --rest.address 127.0.0.1 --metrics --logFile /canxium/logs/beacon.log --logFileLevel info --logLevel info --logFileDailyRotate 5 --jwtSecret /canxium/jwt.hex --execution.urls http://127.0.0.1:8551 --checkpointSyncUrl https://pr-beacon.canxium.net
      Environment=NODE_OPTIONS=--max-old-space-size=8192

      [Install]
      WantedBy=multi-user.target" > /etc/systemd/system/beacon.service
    systemctl enable beacon
    systemctl start beacon
  fi

  if [ "$node_type" = "prysm" ]; then
    echo "[Unit]
      Description=PraseOdy Prysm Node

      [Service]
      User=root
      WorkingDirectory=/canxium/prysm
      ExecStart=/canxium/prysm/build/bin/beacon-chain --datadir=/canxium/beacon --execution-endpoint=http://127.0.0.1:8551 --jwt-secret=/canxium/jwt.hex --accept-terms-of-use --verbosity info --praseody --checkpoint-sync-url https://pr-beacon.canxium.net --grpc-gateway-host=127.0.0.1 --rpc-host=127.0.0.1 --min-sync-peers 1

      [Install]
      WantedBy=multi-user.target" > /etc/systemd/system/beacon.service
    systemctl enable beacon
    systemctl start beacon
  fi

  if [ "$node_type" = "lighthouse" ]; then
    echo "[Unit]
      Description=PraseOdy Lighthouse Node

      [Service]
      User=root
      WorkingDirectory=/canxium/lighthouse
      ExecStart=/canxium/lighthouse/target/release/lighthouse bn --network praseody --execution-endpoint http://127.0.0.1:8551 --execution-jwt /canxium/jwt.hex --http --debug-level info --datadir /canxium/lighthouse_node

      [Install]
      WantedBy=multi-user.target" > /etc/systemd/system/beacon.service
    systemctl enable beacon
    systemctl start beacon
  fi
else
  # mainnet
  /canxium/go-canxium/build/bin/canxium --datadir=/canxium/chain --db.engine=pebble init /canxium/go-canxium/genesis/mainnet.genesis.json
  echo "[Unit]
    Description=Canxium Node

    [Service]
    User=root
    WorkingDirectory=/root
    ExecStart=/canxium/go-canxium/build/bin/canxium --http --db.engine=pebble --syncmode full --authrpc.addr 127.0.0.1 --authrpc.jwtsecret=/canxium/jwt.hex --networkid 3003 --datadir /canxium/chain --bootnodes enode://6a9e8f0de62b92d8e935a65cfb54a4cbf6573c485a396bfaf95fd1f154f4475aca95a10abc1824ec2fda6466026554aa5d0d828d3f5c2e9b9ab67c50593cddee@boot-n2.canxium.org:30303,enode://1cd78440972f585d53a7bf48fc6faa7095ffc70bff3cc4a5c2f6b77ebd6126f1c1f44d2dc1a8643db626500d8b7ce74eab926fcd5848870b31ac8f1be8f3d770@boot.canxium.org:30303,enode://314f1041da4b27f5e4c02b4eac52ca7bd2f025cb585490cb7032fdb08db737aa10d7d64a780db697643ece6027d3bc1a511696420e76192648c0d2d74d099c73@boot.canxium.net:30303,enode://173dbc9ccfc79d7ecdfde768546dc31dad2d0f85f3ef6796cb192f9a141598cb0ddd347a18f78e04b832d8842beafcdcfbdd0473ee2ca2bc5195b4ddfa5f3cc5@boot-n3.canxium.org:30303,enode://a0edd17d53782fbd08a9b01ebf717ea5ac7d82c8582ddbb9d34f5ede39cbb62014cab0a58c6ae07da85a7d9daa33bebc75db4052c81d1b93776baf5946c1294b@boot-n4.canxium.org:30303
    Restart=always

    [Install]
    WantedBy=multi-user.target" > /etc/systemd/system/node.service
  systemctl enable node
  systemctl start node
  
  if [ "$node_type" = "lodestar" ]; then
    echo "[Unit]
      Description=Lodestar Node

      [Service]
      User=root
      WorkingDirectory=/canxium/lodestar
      ExecStart=/canxium/lodestar/lodestar beacon --network canxium --dataDir /canxium/beacon --rest --rest.address 127.0.0.1 --metrics --logFile /canxium/logs/beacon.log --logFileLevel info --logLevel info --logFileDailyRotate 5 --jwtSecret /canxium/jwt.hex --execution.urls http://127.0.0.1:8551 --checkpointSyncUrl https://beacon-api.canxium.org
      Environment=NODE_OPTIONS=--max-old-space-size=8192

      [Install]
      WantedBy=multi-user.target" > /etc/systemd/system/beacon.service
    systemctl enable beacon
    systemctl start beacon
  fi

  if [ "$node_type" = "prysm" ]; then
    echo "[Unit]
      Description=Prysm Node

      [Service]
      User=root
      WorkingDirectory=/canxium/prysm
      ExecStart=/canxium/prysm/build/bin/beacon-chain --datadir=/canxium/beacon --execution-endpoint=http://127.0.0.1:8551 --jwt-secret=/canxium/jwt.hex --accept-terms-of-use --verbosity info --canxium --checkpoint-sync-url https://beacon-api.canxium.org --grpc-gateway-host=127.0.0.1 --rpc-host=127.0.0.1 --min-sync-peers 1

      [Install]
      WantedBy=multi-user.target" > /etc/systemd/system/beacon.service
    systemctl enable beacon
    systemctl start beacon
  fi

  if [ "$node_type" = "lighthouse" ]; then
    echo "[Unit]
      Description=Lighthouse Node

      [Service]
      User=root
      WorkingDirectory=/canxium/lighthouse
      ExecStart=/canxium/lighthouse/target/release/lighthouse bn --network canxium --execution-endpoint http://127.0.0.1:8551 --execution-jwt /canxium/jwt.hex --http --debug-level info --datadir /canxium/lighthouse_node --checkpoint-sync-url https://beacon-api.canxium.org

      [Install]
      WantedBy=multi-user.target" > /etc/systemd/system/beacon.service
    systemctl enable beacon
    systemctl start beacon
  fi
fi

echo ""
echo "You can check node status by: systemctl status node or read the log by: journalctl -f -u node"
echo "You can check beacon node status by: systemctl status beacon or read the log by: journalctl -f -u beacon"
