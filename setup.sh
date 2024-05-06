#!/bin/bash

# Load environment variables from .bashrc (modify the path if needed)
source ~/.bashrc

# Check yq installation
yq >/dev/null 2>&1 || { echo "yq tool is not installed. Please install yq"; exit 1; }

# Check openssl installation
openssl >/dev/null 2>&1 || { echo "openssl is not installed. Please install openssl"; exit 1; }

# Check docker installation
docker >/dev/null 2>&1 || { echo "docker is not installed. Please install docker"; exit 1; }

# Check docker compose installation
docker compose >/dev/null 2>&1 || { echo "docker compose is not installed. Please install docker compose"; exit 1; }


# Check if required environment variables are set
if [ -z "$WORKING_DIR" ] || [ -z "$DOMAIN" ] || [ -z "$HOSTNAMES" ] || [ -z "$API_KEY" ] || [ -z "$LISTEN_ADDRESS" ] || [ -z "$ADMIN_PASSWORD" ]; then
  echo "Error: Please set WORKING_DIR, DOMAIN, HOSTNAMES, API_KEY, LISTEN_ADDRESS and ADMIN_PASSWORD environment variables 
  (e.g., export DOMAIN=0xdead.invincibility HOSTNAMES=mail.0xdead.invincibility API_KEY=THISISAPIKEY LISTEN_ADDRESS=127.0.0.1 WORKING_DIR=~/mailu ADMIN_PASSWORD=123456)"
  exit 1
fi

# Define working directory
WORKING_DIR=$WORKING_DIR/mailu

# Check if working directory exists, remove it if it does
if [ -d "$WORKING_DIR" ]; then
  rm -rf $WORKING_DIR
fi

# Create new working directory
mkdir $WORKING_DIR

# Convert working directory to URI format
WORKING_DIR_URI=$(echo "$WORKING_DIR" | yq @uri)

# Define template variables
TEMPLATE_DOMAIN="TEMPLATE_DOMAIN"
TEMPLATE_HOSTNAMES="TEMPLATE_HOSTNAMES"
HNS_DNS="103.196.38.38"

# Generate Nginx Configuration
sed -e "s/$TEMPLATE_DOMAIN/$DOMAIN/g" -e "s/$TEMPLATE_HOSTNAMES/$HOSTNAMES/g" nginx.conf.template > $WORKING_DIR/nginx.conf
cp tls.conf $WORKING_DIR/tls.conf
cp proxy.conf $WORKING_DIR/proxy.conf

# Check if nginx.conf generation was successful
if [ $? -ne 0 ]; then
  echo "Error: Failed to generate nginx.conf"
  exit 1
fi

# Generate Self-Signed Certificate and DANE TLSA Record
openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout $WORKING_DIR/cert.key -out $WORKING_DIR/cert.crt -extensions ext -config \
  <(echo "[req]";
    echo distinguished_name=req;
    echo "[ext]";
    echo "keyUsage=critical,digitalSignature,keyEncipherment";
    echo "extendedKeyUsage=serverAuth";
    echo "basicConstraints=critical,CA:FALSE";
    echo "subjectAltName=DNS:$DOMAIN,DNS:*.$DOMAIN";
    ) -subj "/CN=*.$DOMAIN"

echo "3 1 1 $(openssl x509 -in $WORKING_DIR/cert.crt -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | xxd  -p -u -c 32)" >> $WORKING_DIR/tlsa

# Check if certificate generation was successful
if [ $? -ne 0 ]; then
  echo "Error: Failed to generate self-signed certificate."
  exit 1
fi

# Generate Mailu Docker Compose and Mailu environment files
curl 'https://setup.mailu.io/2.0/submit' \
  -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7' \
  -H 'accept-language: en-US,en;q=0.9' \
  -H 'cache-control: max-age=0' \
  -H 'content-type: application/x-www-form-urlencoded' \
  -H 'dnt: 1' \
  -H 'origin: https://setup.mailu.io' \
  -H 'priority: u=0, i' \
  -H 'referer: https://setup.mailu.io/2.0/' \
  -H 'sec-ch-ua: "Chromium";v="124", "Microsoft Edge";v="124", "Not-A.Brand";v="99"' \
  -H 'sec-ch-ua-mobile: ?0' \
  -H 'sec-ch-ua-platform: "Windows"' \
  -H 'sec-fetch-dest: document' \
  -H 'sec-fetch-mode: navigate' \
  -H 'sec-fetch-site: same-origin' \
  -H 'sec-fetch-user: ?1' \
  -H 'upgrade-insecure-requests: 1' \
  -H 'user-agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0' \
  --data-raw 'flavor=compose&root='$WORKING_DIR_URI'&domain='$DOMAIN'&postmaster=admin&tls_flavor=notls&auth_ratelimit_ip=5&auth_ratelimit_user=50&message_ratelimit_pd=200&site_name=Mailu&website=https%3A%2F%2Fmailu.io&admin_enabled=true&api_enabled=true&api_token='$API_KEY'&webmail_type=roundcube&antivirus_enabled=clamav&webdav_enabled=radicale&fetchmail_enabled=true&oletools_enabled=true&bind4='$LISTEN_ADDRESS'&subnet=192.168.203.0%2F24&bind6=%3A%3A1&subnet6=fdcf%3Ab3ab%3Acf6e%3Abeef%3A%3A%2F64&resolver_enabled=true&hostnames='$HOSTNAMES'' > html.tmp

# Extract the UUID using grep
UUID=$(grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' html.tmp | head -1)

# Check if UUID was found
if [ -z "$UUID" ]; then
  echo "No UUID found in the HTML file."
  exit 1
else
  echo "Extracted UUID: $UUID"
fi

# Clean up temporary file (optional)
rm html.tmp

# Get Mailu Docker Compose and Mailu environment files
wget 'https://setup.mailu.io/2.0/file/'$UUID'/docker-compose.yml' -O $WORKING_DIR/docker-compose.tmp
wget 'https://setup.mailu.io/2.0/file/'$UUID'/mailu.env' -O $WORKING_DIR/mailu.env

# Modify Docker Compose File (requires yq tool)
# Build the yq filter expression
FILTER=".services.[].dns |= . + [\"$HNS_DNS\"]" 
FILTER+=" | .services.admin.dns |= . - [\"$HNS_DNS\"]"

FILTER+=" | .services.front.volumes += [\"$WORKING_DIR/cert.crt:/etc/ssl/cert.crt:ro\", \"$WORKING_DIR/cert.key:/etc/ssl/cert.key:ro\", \"$WORKING_DIR/nginx.conf:/etc/nginx/nginx.conf:ro\", \"$WORKING_DIR/tls.conf:/etc/nginx/tls.conf:ro\", \"$WORKING_DIR/proxy.conf:/etc/nginx/proxy.conf:ro\"]"  # Add volumes for front service

yq -r "$FILTER" $WORKING_DIR/docker-compose.tmp > $WORKING_DIR/docker-compose.yml

echo "Nginx configuration and Docker Compose file modified."

cd $WORKING_DIR

# Run mail server
docker compose -p mailu up -d

# Create admin user
docker compose -p mailu exec admin flask mailu admin admin $DOMAIN 1
