#!/bin/sh
# Regenerates the throwaway test certificates (keys of no value). Needs the openssl CLI.
set -e
cd "$(dirname "$0")"
O=${OPENSSL:-openssl}
D=36500
EC="-newkey ec -pkeyopt ec_paramgen_curve:prime256v1"
selfsigned() { # name subject alt keyargs
  $O req -x509 $4 -nodes -keyout "$1_key.pem" -out "$1_cert.pem" -days $D -subj "$2" -addext "subjectAltName=$3" 2>/dev/null
}
selfsigned rsa "/CN=localhost" "DNS:localhost,IP:127.0.0.1" "-newkey rsa:2048"
selfsigned ec "/CN=localhost" "DNS:localhost,IP:127.0.0.1" "$EC"
selfsigned renewed "/O=renewed/CN=localhost" "DNS:localhost,IP:127.0.0.1" "$EC"
selfsigned a "/CN=a.test" "DNS:a.test" "$EC"
selfsigned b "/CN=b.test" "DNS:b.test,DNS:*.b.test" "$EC"
selfsigned stranger "/CN=stranger" "DNS:stranger" "$EC"
$O pkey -in rsa_key.pem -aes256 -passout pass:secret -out rsa_key_enc.pem
selfsigned ca "/CN=Facil test CA" "DNS:ca.test" "$EC -addext basicConstraints=critical,CA:TRUE -addext keyUsage=keyCertSign"
$O req -new $EC -nodes -keyout client_key.pem -out client.csr -subj "/CN=client" 2>/dev/null
$O x509 -req -in client.csr -CA ca_cert.pem -CAkey ca_key.pem -CAcreateserial -out client_cert.pem -days $D 2>/dev/null
rm -f client.csr ca_cert.srl
