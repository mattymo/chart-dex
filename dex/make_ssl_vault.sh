#!/bin/bash -xe

VAULT_SERVER="https://127.0.0.1:8200"
UNSEAL_TOKEN=$(sudo cat /etc/vault/secrets/unseal_keys)
ROOT_TOKEN=$(sudo cat /etc/vault/secrets/root_token)
SERVICE_NAME=dex
ROLE_NAME=coreapps
DOMAIN="kube-system.svc.cluster.local"
FQDN="$SERVICE_NAME.$DOMAIN"
PKI_MOUNT=kube
ROLE_NAME=coreapps
ALT_NAMES=""

help(){
  echo -e "\nUsage: ./$0 <options>"
  echo -e "Available Options:"
  echo -e "  --vault-server 	Location of vault server (default: $VAULT_SERVER)"
  echo -e "  --service-name	Base for common name (default: $SERVICE_NAME)"
  echo -e "  --domain		Domain to use for Vault role (default: $DOMAIN)"
  echo -e "  --fqdn		FQDN for common name of cert (default: $FQDN)"
  echo -e "  --pki-mount	Vault PKI mount to use (default: $PKI_MOUNT)"
  echo -e "  --alt-names	Comma-separated list of extra SANs to use (default: \"$ALT_NAMES\")"
  echo -e "  --role-name        Vault role to create/reuse (default: $ROLE_NAME)"
}

# Parse parameters
while [[ $# -gt 0 ]]; do
  case $i in
    --vault-server)
      VAULT_SERVER=$2
      shift 2
    ;;
    --service-name)
      SERVICE_NAME=$2
      shift 2
    ;;
    --domain)
      DOMAIN=$2
      shift 2
    ;;
    --fdqn)
      FQDN=$2
      shift 2
    ;;
    --pki-mount)
      PKI_MOUNT=$2
      shift 2
    ;;
    --alt-names)
      ALT_NAMES=$2
      shift 2
    ;;
    --role-name)
      ROLE_NAME=$2
      shift 2
    ;;
    --) shift
        break
    ;;
    *)
      help
      exit 1
    ;;
  esac
done

# Unseal vault
curl -s \
    -o /dev/null \
    -X PUT \
    -d "{\"key\": \"${UNSEAL_TOKEN}\"}" \
    "${VAULT_SERVER}/v1/sys/unseal" 

# Mount pki
curl -s \
    -o /dev/null \
    --header "X-Vault-Token: ${ROOT_TOKEN}" \
    --request POST \
    --data "{\"type\": \"pki\"}" \
    "${VAULT_SERVER}/v1/sys/mounts/${PKI_MOUNT}"

# Create/update role
PAYLOADFILE=$(mktemp /tmp/payload.XXXX)
cat << EOF > $PAYLOADFILE
{
  "key_bits": 2048,
  "max_ttl": "8760h",
  "allowed_any_name": true,
  "allowed_domains": "$DOMAIN",
  "allow_subdomains": true,
  "allow_bare_domains": true,
  "enforce_hostnames": false
}
EOF

curl -s \
    --header "X-Vault-Token: ${ROOT_TOKEN}" \
    --request POST \
    --data @${PAYLOADFILE} \
    "${VAULT_SERVER}/v1/${PKI_MOUNT}/roles/${ROLE_NAME}"

rm -f $PAYLOADFILE

# Issue cert
PAYLOADFILE=$(mktemp /tmp/payload.XXXX)
cat << EOF > $PAYLOADFILE
{
  "common_name": "$FQDN",
  "alt_names": "$ALT_NAMES"
}
EOF

CERT_DETAILS=$(curl -s \
    --header "X-Vault-Token: ${ROOT_TOKEN}" \
    --request POST \
    --data @${PAYLOADFILE} \
    "${VAULT_SERVER}/v1/${PKI_MOUNT}/issue/${ROLE_NAME}")


rm -f $PAYLOADFILE
curl -s \
    -X PUT \
    --header "X-Vault-Token: ${ROOT_TOKEN}" \
    "${VAULT_SERVER}/v1/sys/seal"



# Seal vault
curl -s \
    -X PUT \
    --header "X-Vault-Token: ${ROOT_TOKEN}" \
    "${VAULT_SERVER}/v1/sys/seal"


cat << EOF
Certificates have been generated.
Copy the following data into values.yaml:

tls:
  ca: "$(echo $CERT_DETAILS | jq -r .data.issuing_ca | base64 -w0)"
  cert: "$(echo $CERT_DETAILS | jq -r .data.certificate | base64 -w0)"
  key: "$(echo $CERT_DETAILS | jq -r .data.private_key | base64 -w0)"
EOF
