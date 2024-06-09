#! /bin/bash

read -p "Enter: NUM_VALIDATORS = " num_validator
read -p "Enter: KEYSTORE_PASSWORD = " keystore_password
read -p "Enter: WITHDRAWAL_ADDRESS = " withdrawal_address
read -p "Node type: lighthouse (rust - best performance) or lodestar (nodejs - stable) or prysm (golang): (lighthouse/lodestar/prysm) " node_type
if [ "$node_type" != "lodestar" ] && [ "$node_type" != "prysm" ] && [ "$node_type" != "lighthouse" ]; then
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

echo ""
echo NUM_VALIDATORS: $num_validator, KEYSTORE_PASSWORD: $keystore_password, WITHDRAWAL_ADDRESS: $withdrawal_address, Node type: $node_type
echo ""
read -p "Correct? (y/N): " confirmed
if [ "$confirmed" != "y" ]; then
  echo "Existing"
  exit 1
fi

read -p "Did you generate the keystores on local machine? (y/N) " keys_ready

rm -rf /canxium
mkdir -p /canxium

if [ "$keys_ready" = "y" ]; then
  myip=$(curl -kLs "http://api.ipify.org")
  echo "Please zip the keystores folder and copy it to server by this command: scp keystores.zip root@$myip:/canxium/"
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

if [ "$node_env" = "native" ]; then
  echo "Installing golang..."
  sudo apt install snapd -y
  export PATH=$PATH:/snap/bin
  sudo snap install go --channel=1.22 --classic
  echo "Installing system packages..."
  sudo apt install build-essential -y
  sudo apt install git -y
  sudo apt install unzip -y

  systemctl stop node
  systemctl stop beacon
  systemctl stop validator
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
    arch=$(uname -i)
    if [[ $arch == x86_64* ]]; then
      echo "X64 Architecture"
      mkdir -p /canxium/lighthouse/target/release
      cd /canxium/lighthouse/target/release && wget https://github.com/canxium/lighthouse/releases/download/v5.1.3/lighthouse-v5.1.3-x86_64-unknown-linux-gnu-portable.tar.gz.zip
      unzip lighthouse-v5.1.3-x86_64-unknown-linux-gnu-portable.tar.gz.zip
      tar -zxvf lighthouse-v5.1.3-x86_64-unknown-linux-gnu-portable.tar.gz
      chmod a+x lighthouse
      cd ~
    else
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
      source "$HOME/.cargo/env"
      sudo apt install libclang-dev -y
      sudo apt install cmake -y
      git clone https://github.com/canxium/lighthouse.git /canxium/lighthouse
      cd /canxium/lighthouse
      make
      cd ~
    fi
  fi

  git clone https://github.com/canxium/go-canxium.git /canxium/go-canxium
  if [ "$network" = "mainnet" ]; then
    cd /canxium/go-canxium
    git checkout v0.2.2
    make canxium
  else
    cd /canxium/go-canxium
    git checkout v0.2.2
    make canxium
  fi

  cd ~
  if [ "$node_type" = "lodestar" ]; then
    git clone https://github.com/canxium/lodes.git /canxium/lodes
    cd /canxium/lodes
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
  echo $keystore_password > /canxium/password.txt
  mkdir -p /canxium/logs
  if [ "$network" = "testnet" ]; then
    /canxium/go-canxium/build/bin/canxium --datadir=/canxium/chain --db.engine=pebble init /canxium/go-canxium/genesis/praseody.genesis.json
    echo "[Unit]
      Description=PraseOdy Node

      [Service]
      User=root
      WorkingDirectory=/root
      ExecStart=/canxium/go-canxium/build/bin/canxium --http --db.engine=pebble --syncmode full --authrpc.addr 127.0.0.1 --authrpc.jwtsecret=/canxium/jwt.hex --networkid 30203 --datadir /canxium/chain --bootnodes enode://9046044c5d6801d927ddaace0bc96dafa8999f8f5ee6e10bb91bc96bc80347afa77152d7a95c16d247d0faf17323850ca8c4cdd6845138014cc5c5c93fee5323@195.35.45.155:30303,enode://7918d918a36654eeaa860870dbad186553823aa386896b3326a0e8ba1cd60ed78242fad33f691248e1554c87237fb90da70eaa149fe04e7541809e4a835fbd14@15.235.141.136:30303
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
        ExecStart=/canxium/lodes/lodestar beacon --network praseody --dataDir /canxium/beacon --rest --rest.address 127.0.0.1 --metrics --logFile /canxium/logs/beacon.log --logFileLevel info --logLevel info --logFileDailyRotate 5 --jwtSecret /canxium/jwt.hex --execution.urls http://127.0.0.1:8551 --checkpointSyncUrl https://pr-beacon.canxium.net
        Environment=NODE_OPTIONS=--max-old-space-size=8192
        Environment=LODESTAR_PRESET=praseody

        [Install]
        WantedBy=multi-user.target" > /etc/systemd/system/beacon.service
      systemctl enable beacon
      systemctl start beacon

      echo "[Unit]
        Description=PraseOdy Lodestar Node

        [Service]
        User=root
        WorkingDirectory=/canxium/lodes
        ExecStart=/canxium/lodes/lodestar validator --network praseody --suggestedFeeRecipient $withdrawal_address --dataDir /canxium/validator --importKeystores /canxium/keystores --importKeystoresPassword /canxium/password.txt --server http://127.0.0.1:9596 --logFile /canxium/logs/validator.log --logFileLevel info --logFileDailyRotate 5
        Environment=NODE_OPTIONS=--max-old-space-size=2048
        Environment=LODESTAR_PRESET=praseody

        [Install]
        WantedBy=multi-user.target" > /etc/systemd/system/validator.service
      systemctl enable validator
      systemctl start validator
    fi

    if [ "$node_type" = "prysm" ]; then
      /canxium/prysm/build/bin/validator accounts import --wallet-dir=/canxium/wallet/keystores --keys-dir=/canxium/keystores --wallet-password-file=/canxium/password.txt --account-password-file=/canxium/password.txt --accept-terms-of-use

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

      echo "[Unit]
        Description=PraseOdy Prysm Validator Node

        [Service]
        User=root
        WorkingDirectory=/canxium/prysm
        ExecStart=/canxium/prysm/build/bin/validator --suggested-fee-recipient $withdrawal_address --beacon-rpc-provider=127.0.0.1:4000 --datadir=/canxium/validator --accept-terms-of-use --wallet-dir=/canxium/wallet/keystores --wallet-password-file=/canxium/password.txt --praseody 

        [Install]
        WantedBy=multi-user.target" > /etc/systemd/system/validator.service
      systemctl enable validator
      systemctl start validator
    fi

    if [ "$node_type" = "lighthouse" ]; then
      # import keys
      /canxium/lighthouse/target/release/lighthouse account --network praseody --datadir /canxium/lighthouse_validator validator import --directory /canxium/keystores --reuse-password --password-file /canxium/password.txt

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

      echo "[Unit]
        Description=PraseOdy Lighthouse Validator Node

        [Service]
        User=root
        WorkingDirectory=/canxium/lighthouse
        ExecStart=/canxium/lighthouse/target/release/lighthouse vc --network praseody --suggested-fee-recipient $withdrawal_address --datadir /canxium/lighthouse_validator --debug-level info

        [Install]
        WantedBy=multi-user.target" > /etc/systemd/system/validator.service
      systemctl enable validator
      systemctl start validator
    fi
  else
    # mainnet
    /canxium/go-canxium/build/bin/canxium --datadir=/canxium/chain --db.engine=pebble init /canxium/go-canxium/genesis/mainnet.genesis.json
    echo "[Unit]
      Description=Canxium Node

      [Service]
      User=root
      WorkingDirectory=/root
      ExecStart=/canxium/go-canxium/build/bin/canxium --http --db.engine=pebble --syncmode full --authrpc.addr 127.0.0.1 --authrpc.jwtsecret=/canxium/jwt.hex --networkid 3003 --datadir /canxium/chain --bootnodes enode://314f1041da4b27f5e4c02b4eac52ca7bd2f025cb585490cb7032fdb08db737aa10d7d64a780db697643ece6027d3bc1a511696420e76192648c0d2d74d099c73@boot.canxium.net:30303,enode://767d3e408b073ca501ea7336096c048eea46513ac5c44659ac902d7575881ca114c82277dff7826630ec9fb45d8cfa5a82b9eacc8b477dc475746eaec39e2f2a@boot.canxium.org:30303,enode://f06de34b87954abb25be2e8d592306bc55b396a4eead839dba90baf4e59465d3ef704866962cf2fd995e6ce04f17de31edebb11afcac9df4eaea847f35e3cbaf@boot-n2.canxium.org:30303
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
        WorkingDirectory=/canxium/lodes
        ExecStart=/canxium/lodes/lodestar beacon --network canxium --dataDir /canxium/beacon --rest --rest.address 127.0.0.1 --metrics --logFile /canxium/logs/beacon.log --logFileLevel info --logLevel info --logFileDailyRotate 5 --jwtSecret /canxium/jwt.hex --execution.urls http://127.0.0.1:8551 --checkpointSyncUrl https://beacon-api.canxium.org
        Environment=NODE_OPTIONS=--max-old-space-size=8192

        [Install]
        WantedBy=multi-user.target" > /etc/systemd/system/beacon.service
      systemctl enable beacon
      systemctl start beacon

      echo "[Unit]
        Description=Lodestar Validator Node

        [Service]
        User=root
        WorkingDirectory=/canxium/lodes
        ExecStart=/canxium/lodes/lodestar validator --network canxium --suggestedFeeRecipient $withdrawal_address --dataDir /canxium/validator --importKeystores /canxium/keystores --importKeystoresPassword /canxium/password.txt --server http://127.0.0.1:9596 --logFile /canxium/logs/validator.log --logFileLevel info --logFileDailyRotate 5
        Environment=NODE_OPTIONS=--max-old-space-size=2048

        [Install]
        WantedBy=multi-user.target" > /etc/systemd/system/validator.service
      systemctl enable validator
      systemctl start validator
    fi

    if [ "$node_type" = "prysm" ]; then
      /canxium/prysm/build/bin/validator accounts import --wallet-dir=/canxium/wallet/keystores --keys-dir=/canxium/keystores --wallet-password-file=/canxium/password.txt --account-password-file=/canxium/password.txt --accept-terms-of-use

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

      echo "[Unit]
        Description=Prysm Validator Node

        [Service]
        User=root
        WorkingDirectory=/canxium/prysm
        ExecStart=/canxium/prysm/build/bin/validator --suggested-fee-recipient $withdrawal_address --beacon-rpc-provider=127.0.0.1:4000 --datadir=/canxium/validator --accept-terms-of-use --wallet-dir=/canxium/wallet/keystores --wallet-password-file=/canxium/password.txt --canxium 

        [Install]
        WantedBy=multi-user.target" > /etc/systemd/system/validator.service
      systemctl enable validator
      systemctl start validator
    fi

    if [ "$node_type" = "lighthouse" ]; then
      /canxium/lighthouse/target/release/lighthouse account --network canxium --datadir /canxium/lighthouse_validator validator import --directory /canxium/keystores --reuse-password --password-file /canxium/password.txt

      echo "[Unit]
        Description=PraseOdy Lighthouse Node

        [Service]
        User=root
        WorkingDirectory=/canxium/lighthouse
        ExecStart=/canxium/lighthouse/target/release/lighthouse bn --network canxium --execution-endpoint http://127.0.0.1:8551 --execution-jwt /canxium/jwt.hex --http --debug-level info --datadir /canxium/lighthouse_node --checkpoint-sync-url https://beacon-api.canxium.org

        [Install]
        WantedBy=multi-user.target" > /etc/systemd/system/beacon.service
      systemctl enable beacon
      systemctl start beacon

      echo "[Unit]
        Description=Lighthouse Validator Node

        [Service]
        User=root
        WorkingDirectory=/canxium/lighthouse
        ExecStart=/canxium/lighthouse/target/release/lighthouse vc --network canxium --suggested-fee-recipient $withdrawal_address --datadir /canxium/lighthouse_validator --debug-level info

        [Install]
        WantedBy=multi-user.target" > /etc/systemd/system/validator.service
      systemctl enable validator
      systemctl start validator
    fi
  fi
else
  docker stop $(docker ps -aq)
  docker rm $(docker ps -aq)
  docker system prune -a -f
  echo $keystore_password > /canxium/keystores/password.txt
  if [ "$network" = "testnet" ]; then
    if [ "$node_type" = "lodestar" ]; then
      cd /canxium
      curl -o /canxium/docker-compose.praseody.validator.yml https://raw.githubusercontent.com/canxium/lodestar/main/docker-compose.praseody.validator.yml
      docker compose -f docker-compose.praseody.validator.yml up -d
    fi
    if [ "$node_type" = "prysm" ]; then
      cd /canxium
      curl -o /canxium/docker-compose.praseody.validator.yml https://raw.githubusercontent.com/canxium/prysm/main/docker-compose.praseody.validator.yml
      docker compose -f docker-compose.praseody.validator.yml up -d
    fi
    if [ "$node_type" = "lighthouse" ]; then
      cd /canxium
      curl -o /canxium/docker-compose.praseody.validator.yml https://raw.githubusercontent.com/canxium/lighthouse/main/docker-compose.praseody.validator.yml
      docker compose -f docker-compose.praseody.validator.yml up -d
    fi
  else
    # mainnet
    if [ "$node_type" = "lodestar" ]; then
      cd /canxium
      curl -o /canxium/docker-compose.validator.yml https://raw.githubusercontent.com/canxium/lodestar/main/docker-compose.validator.yml
      docker compose -f docker-compose.validator.yml up -d
    fi
    if [ "$node_type" = "prysm" ]; then
      cd /canxium
      curl -o /canxium/docker-compose.validator.yml https://raw.githubusercontent.com/canxium/prysm/main/docker-compose.validator.yml
      docker compose -f docker-compose.validator.yml up -d
    fi
    if [ "$node_type" = "lighthouse" ]; then
      cd /canxium
      curl -o /canxium/docker-compose.validator.yml https://raw.githubusercontent.com/canxium/lighthouse/main/docker-compose.validator.yml
      docker compose -f docker-compose.validator.yml up -d
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

if [ "$node_env" = "native" ]; then
  echo ""
  echo "You can check node status by: systemctl status node or read the log by: journalctl -f -u node"
  echo "You can check beacon node status by: systemctl status node or read the log by: journalctl -f -u beacon"
  echo "You can check validator status by: systemctl status node or read the log by: journalctl -f -u validator"
else
  echo ""
  echo "You can check docker status by: docker ps"
  echo "You can check the docker logs by: docker logs -f --tail 10 [container_id]"
fi