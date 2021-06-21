#!/bin/bash
set -xe
export VAULT_VERSION="1.7.3" 

# Make the user
sudo useradd --system --shell /sbin/nologin vault

# Make the directories
sudo mkdir -p /opt/vault
sudo mkdir -p /opt/vault/bin
sudo mkdir -p /opt/vault/config
sudo mkdir -p /opt/vault/tls
sudo mkdir -p /opt/vault/data

# Give corret permissions
sudo chmod 755 /opt/vault
sudo chmod 755 /opt/vault/bin

# Change ownership to vault user
sudo chown -R vault:vault /opt/vault


# Get the HashiCorp PGP
curl https://keybase.io/hashicorp/pgp_keys.asc | gpg --import

# Download vault and signatures
curl -Os "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip"
curl -Os "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_SHA256SUMS"
curl -Os "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_SHA256SUMS.sig"

# Verify Signatres
gpg --verify "vault_${VAULT_VERSION}_SHA256SUMS.sig" "vault_${VAULT_VERSION}_SHA256SUMS"
cat "vault_${VAULT_VERSION}_SHA256SUMS" | grep "vault_${VAULT_VERSION}_linux_amd64.zip" | sha256sum -c

# unzip and move to /opt/vault/bin
unzip "vault_${VAULT_VERSION}_linux_amd64.zip"
sudo mv vault /opt/vault/bin

# give ownership to the vault user
sudo chown vault:vault /opt/vault/bin/vault

# create a symlink
sudo ln -s /opt/vault/bin/vault /usr/local/bin/vault

# allow vault permissions to use mlock and prevent memory from swapping to disk
sudo setcap cap_ipc_lock=+ep /opt/vault/bin/vault

# cleanup files
rm "vault_${VAULT_VERSION}_linux_amd64.zip"
rm "vault_${VAULT_VERSION}_SHA256SUMS"
rm "vault_${VAULT_VERSION}_SHA256SUMS.sig"