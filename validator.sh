#! /bin/bash

read -p "Enter: NUM_VALIDATORS = " num_validator
read -p "Enter: KEYSTORE_PASSWORD = " keystore_password
read -p "Enter: WITHDRAWAL_ADDRESS = " withdrawal_address
read -p "Node type: lodestar (nodejs) or prysm (golang): (lodestar/prysm) " node_type
if [ "$node_type" != "lodestar" ] && [ "$node_type" != "prysm" ]; then
  echo "Invalid node type!"
  exit 1
fi

read -p "Run node in native binary or docker: (native/docker) " node_env
if [ "$node_env" != "native" ] && [ "$node_env" != "docker" ]; then
  echo "Invalid node env!"
  exit 1
fi

read -p "mainnet or testnet: " network
if [ "$network" != "mainnet" ] && [ "$network" != "testnet" ]; then
  echo "Invalid network!"
  exit 1
fi
if [ "$network" = "mainnet" ]; then
  echo "Mainnet is not supported yet"
  exit 1
fi

echo ""
echo NUM_VALIDATORS: $num_validator, KEYSTORE_PASSWORD: $keystore_password, WITHDRAWAL_ADDRESS: $withdrawal_address, Node type: $node_type
echo ""
read -p "Correct? (y/N): " confirmed
if [ "$confirmed" != "y" ]; then
  echo "Existing"
  exit 1
fi

read -p "Did you generate the keystores on local machine? (y/N) " keys_ready

systemctl stop node
systemctl stop lodestar
systemctl stop lodestar.validator
systemctl stop prysm
systemctl stop prysm.validator
rm -rf /canxium
mkdir -p /canxium

if [ "$keys_ready" = "y" ]; then
  echo "Please zip the keystores folder and copy it to this server: scp keystores.zip root@[server_ip]:/canxium/"
  read -p "Did you copy it: (y) " copied
  sudo apt update
  sudo apt-get install unzip -y
  rm -rf /canxium/keystores
  rm -rf /canxium/__MACOSX
  unzip /canxium/keystores.zip -d /canxium
  if [ ! -d "/canxium/keystores" ]; then
   echo "/canxium/keystores.zip does not exist. Make sure you copied the keystores.zip correctly!"
   exit 1
  fi
else
  echo "Installing docker..."
  # Add Docker's official GPG key:
  sudo apt-get update
  sudo apt-get install ca-certificates curl -y
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  # Add the repository to Apt sources:
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y

  echo "Generating keystores...."
  rm -rf /canxium/keystores
  mkdir -p /canxium/keystores
  if [ "$network" = "mainnet" ]; then
    docker run -e NUM_VALIDATORS=$num_validator -e KEYSTORE_PASSWORD=$keystore_password -e WITHDRAWAL_ADDRESS=$withdrawal_address -v /canxium/keystores:/app/validator_keys canxium/staking-deposit-cli:v0.1
  else
    docker run -e NUM_VALIDATORS=$num_validator -e KEYSTORE_PASSWORD=$keystore_password -e WITHDRAWAL_ADDRESS=$withdrawal_address -v /canxium/keystores:/app/validator_keys canxium/staking-deposit-cli-praseody:latest
  fi
  echo ""
  read -p "Did you save the mnemonic above? (y) " mnemonic
fi

echo "Installing golang..."
sudo snap install go --channel=1.22 --classic
echo "Installing system packages..."
sudo apt install build-essential -y
sudo apt install git -y

if [ "$node_env" = "native" ]; then
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

  git clone https://github.com/canxium/go-canxium.git /canxium/go-canxium
  if [ "$network" = "mainnet" ]; then
    cd /canxium/go-canxium
    make canxium
  else
    cd /canxium/go-canxium
    git checkout 66487b7dc4ea72a40234826220f1fad3903aa26d
    make canxium
  fi

  cd ~
  if [ "$node_type" = "lodestar" ]; then
    git clone https://github.com/canxium/lodes.git /canxium/lodes
    cd /canxium/lodes
    yarn install
    yarn build=
    cd ~
  else
    git clone https://github.com/canxium/prysm.git /canxium/prysm
    cd /canxium/prysm
    go build -o=./build/bin/beacon-chain ./cmd/beacon-chain && go build -o=./build/bin/validator ./cmd/validator
    cd ~
  fi

  # init and run
  openssl rand -hex 32 | tr -d "\n" > "/canxium/jwt.hex"
  echo $keystore_password > /canxium/password.txt
  mkdir -p /canxium/logs
  if [ "$network" = "testnet" ]; then
    /canxium/go-canxium/build/bin/canxium --datadir=/canxium/chain --db.engine=pebble init /canxium/go-canxium/genesis/praseody.genesis.json
    echo "[Unit]
      Description=Odynium Node

      [Service]
      User=root
      WorkingDirectory=/root
      ExecStart=/canxium/go-canxium/build/bin/canxium --http --db.engine=pebble --syncmode snap --authrpc.addr 0.0.0.0 --authrpc.jwtsecret=/canxium/jwt.hex --authrpc.vhosts=canxium --networkid 30203 --datadir /canxium/chain --bootnodes enode://9046044c5d6801d927ddaace0bc96dafa8999f8f5ee6e10bb91bc96bc80347afa77152d7a95c16d247d0faf17323850ca8c4cdd6845138014cc5c5c93fee5323@195.35.45.155:30303,enode://7918d918a36654eeaa860870dbad186553823aa386896b3326a0e8ba1cd60ed78242fad33f691248e1554c87237fb90da70eaa149fe04e7541809e4a835fbd14@15.235.141.136:30303
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
        WorkingDirectory=/canxium/lodes
        ExecStart=/canxium/lodes/lodestar beacon --network praseody --dataDir /canxium/beacon --rest --rest.address 0.0.0.0 --metrics --logFile /canxium/logs/beacon.log --logFileLevel info --logLevel info --logFileDailyRotate 5 --jwtSecret /canxium/jwt.hex --execution.urls http://127.0.0.1:8551 --checkpointSyncUrl https://pr-beacon.canxium.net
        Environment=NODE_OPTIONS=--max-old-space-size=8192
        Environment=LODESTAR_PRESET=praseody

        [Install]
        WantedBy=multi-user.target" > /etc/systemd/system/lodestar.service
      systemctl enable lodestar
      systemctl start lodestar

      echo "[Unit]
        Description=PraseOdy Lodestar Node

        [Service]
        User=root
        WorkingDirectory=/canxium/lodes
        ExecStart=/canxium/lodes/lodestar validator --network praseody --suggestedFeeRecipient $withdrawal_address --dataDir /canxium/validator --importKeystores /canxium/keystores --importKeystoresPassword /canxium/password.txt --server http://127.0.0.1:9596 --logFile /canxium/logs/validator.log --logFileLevel info --logFileDailyRotate 5
        Environment=NODE_OPTIONS=--max-old-space-size=8192
        Environment=LODESTAR_PRESET=praseody

        [Install]
        WantedBy=multi-user.target" > /etc/systemd/system/lodestar.validator.service
      systemctl enable lodestar.validator
      systemctl start lodestar.validator
    else
      /canxium/prysm/build/bin/validator accounts import --wallet-dir=/canxium/wallet/keystores --keys-dir=/canxium/keystores --wallet-password-file=/canxium/password.txt --account-password-file=/canxium/password.txt --accept-terms-of-use

      echo "[Unit]
        Description=PraseOdy Prysm Node

        [Service]
        User=root
        WorkingDirectory=/canxium/prysm
        ExecStart=/canxium/prysm/build/bin/beacon-chain --datadir=/data --execution-endpoint=http://127.0.0.1:8551 --jwt-secret=/canxium/jwt.hex --accept-terms-of-use --verbosity info --praseody --checkpoint-sync-url https://pr-beacon.canxium.net --grpc-gateway-host=0.0.0.0 --rpc-host=0.0.0.0 --min-sync-peers 1

        [Install]
        WantedBy=multi-user.target" > /etc/systemd/system/prysm.service
      systemctl enable prysm
      systemctl start prysm

      echo "[Unit]
        Description=PraseOdy Prysm Validator Node

        [Service]
        User=root
        WorkingDirectory=/canxium/prysm
        ExecStart=/canxium/prysm/build/bin/validator --suggested-fee-recipient $withdrawal_address --beacon-rpc-provider=127.0.0.1:4000 --datadir=/canxium/validator --accept-terms-of-use --wallet-dir=/canxium/wallet/keystores --wallet-password-file=/canxium/password.txt --praseody 

        [Install]
        WantedBy=multi-user.target" > /etc/systemd/system/prysm.validator.service
      systemctl enable prysm.validator
      systemctl start prysm.validator
    fi
  else
    if [ "$node_type" = "lodestar" ]; then
      echo "Not supported yet"
      exit 1
    else
      echo "Not supported yet"
      exit 1
    fi
  fi
else
  docker stop $(docker ps -aq)
  docker rm $(docker ps -aq)
  docker system prune -af –volumes
  echo $keystore_password > /canxium/keystores/password.txt
  if [ "$network" = "testnet" ]; then
    if [ "$node_type" = "lodestar" ]; then
      cd /canxium
      curl -o /canxium/docker-compose.praseody.validator.yml https://raw.githubusercontent.com/canxium/lodes/main/docker-compose.praseody.validator.yml
      docker compose -f docker-compose.praseody.validator.yml up -d
    else
      cd /canxium
      curl -o /canxium/docker-compose.praseody.validator.yml https://raw.githubusercontent.com/canxium/neuro/main/docker-compose.praseody.validator.yml
      docker compose -f docker-compose.praseody.validator.yml up -d
    fi
  else
    if [ "$node_type" = "lodestar" ]; then
      echo "Not supported yet"
      exit 1
      cd /canxium
      curl -o /canxium/docker-compose.praseody.validator.yml https://raw.githubusercontent.com/canxium/lodes/main/docker-compose.validator.yml
      docker compose -f docker-compose.praseody.validator.yml up -d
    else
      echo "Not supported yet"
      exit 1
      cd /canxium
      curl -o /canxium/docker-compose.praseody.validator.yml https://raw.githubusercontent.com/canxium/neuro/main/docker-compose.validator.yml
      docker compose -f docker-compose.praseody.validator.yml up -d
    fi
  fi
fi

if [ "$keys_ready" != "y" ]; then
  clear
  echo "Please copy this deposit data and save it to deposit.json, then deposit your CAU"
  echo ""
  cat /canxium/keystores/deposit_data*
  echo ""
fi
