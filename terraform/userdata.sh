#!/bin/bash
set -xo

INSTANCE_IP_ADDR=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
INSTANCE_DNS_NAME=$(curl http://169.254.169.254/latest/meta-data/local-hostname)
NODE_ID=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c10)


# Used for encryption between the load balancer and vault instances.
# Th other alternatives are either creating an entire, private CA and hoping AWS
# eventually adds the ability to add trusted CAs to load balancers...
# ...or paying $400/month base for the ACM private CA.
# openssl req -x509 -sha256 -nodes \
#   -newkey rsa:4096 -days 3650 \
#   -keyout /opt/vault/tls/vault.key -out /opt/vault/tls/vault.crt \
#   -subj "/CN=$INSTANCE_DNS_NAME" \
#   -extensions san \
#   -config <(cat /etc/ssl/openssl.cnf <(echo -e "\n[san]\nsubjectAltName=DNS:$INSTANCE_DNS_NAME,IP:$INSTANCE_IP_ADDR"))

# chown vault:vault /opt/vault/tls/vault.key
# chown vault:vault /opt/vault/tls/vault.crt

# chmod 640 /opt/vault/tls/vault.key
# chmod 644 /opt/vault/tls/vault.crt

# # Trust the certificate
# cp /opt/vault/tls/vault.crt /etc/ssl/certs/vault.crt

cat <<EOF > /etc/systemd/system/vault.service
[Unit]
Description="HashiCorp Vault - A tool for managing secrets"
Documentation=https://www.vaultproject.io/docs/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/opt/vault/config/kms.hcl
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
User=vault
Group=vault
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
SecureBits=keep-caps
AmbientCapabilities=CAP_IPC_LOCK
Capabilities=CAP_IPC_LOCK+ep
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
NoNewPrivileges=yes
ExecStart=/usr/local/bin/vault server -config=/opt/vault/config
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
LimitNOFILE=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF

cat << EOF > /opt/vault/config/vault.hcl
listener "tcp" {
  address       = "INSTANCE_IP_ADDR:8200"
  tls_disable = true 
  cluster_address = "INSTANCE_IP_ADDR:8201"
  # tls_cert_file = "/opt/vault/tls/vault.crt"
  # tls_key_file = "/opt/vault/tls/vault.key"
}

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "NODE_ID"

  retry_join {
    auto_join = "provider=aws tag_key=vault tag_value=server access_key_id=${AWS_ACCESS_KEY} secret_access_key=${AWS_SECRET_KEY} region=us-east-1"
    auto_join_scheme = "http"
  }
}

ui = true
cluster_name = "MERA-CLUSTER"
api_addr = "https://vault.imparham.in"
cluster_addr = "http://INSTANCE_IP_ADDR:8201"
EOF

cat << EOF > /opt/vault/config/kms.hcl 
seal "awskms" {
  region     = "${AWS_REGION}"
  kms_key_id = "${kms_key}"
  access_key = "${AWS_ACCESS_KEY}"
  secret_key = "${AWS_SECRET_KEY}"
}
EOF


sed -i -e "s/INSTANCE_IP_ADDR/$INSTANCE_IP_ADDR/g" /opt/vault/config/vault.hcl
sed -i -e "s/NODE_ID/$NODE_ID/g" /opt/vault/config/vault.hcl
chown -R vault:vault /opt/vault/config
export "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY}"
export "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_KEY}"
export "AWS_DEFAULT_REGION=${AWS_REGION}"
export "VAULT_ADDR=http://$INSTANCE_IP_ADDR:8200"

echo "export \"AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY}\"" >> /home/ubuntu/.profile
echo "export \"AWS_SECRET_ACCESS_KEY=${AWS_SECRET_KEY}\"" >> /home/ubuntu/.profile
echo "export \"AWS_DEFAULT_REGION=${AWS_REGION}\"" >> /home/ubuntu/.profile
echo "export \"VAULT_ADDR=http://$INSTANCE_IP_ADDR:8200\"" >> /home/ubuntu/.profile
chown -R ubuntu:ubuntu /home/ubuntu

systemctl daemon-reload
systemctl enable vault
systemctl restart vault
sleep 20

%{ if count == 1 }
cd /home/ubuntu
vault operator init -recovery-shares 5 -recovery-threshold 3 > recovery.txt

# encrypt it with the KMS key
aws kms encrypt --key-id ${kms_key} --plaintext fileb://recovery.txt --output text --query CiphertextBlob | base64 --decode > vault_creds_encrypted

# send the encrypted file to the s3 bucket
aws s3 cp vault_creds_encrypted s3://${VAULT_S3_BUCKET_NAME}/

cleanup
rm recovery.txt
rm vault_creds_encrypted
history -c
history -w

%{ else }
sleep 20
sudo systemctl restart vault
%{ endif }