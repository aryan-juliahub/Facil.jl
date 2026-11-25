# TLS configuration checks against cfg_server.jl on port $CPORT. Sourced by
# run.sh with: CPORT, W, LIB, D (suite dir). Each check starts its own server.
O=${OPENSSL_BIN:-/opt/homebrew/opt/openssl@4/bin/openssl}
[ -x "$O" ] || O=$(command -v openssl)
C=$D/certs
CU=https://127.0.0.1:$CPORT
up() { srv_start "$W/cfg.log" "$CPORT" - env "$@" "$JULIA" --startup-file=no -t 2 "$D/cfg_server.jl" "$LIB" "$CPORT" ||
  { result "cfg: server starts with $*" 1; return 1; }; }
down() { srv_stop; }
sc() { echo | "$O" s_client -connect 127.0.0.1:$CPORT "$@" 2>&1; }
# keeps the connection open long enough to receive the session tickets
sct() { (sleep 0.4; echo) | "$O" s_client -connect 127.0.0.1:$CPORT "$@" 2>&1; }
code() { curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "$@" $CU/; }
subj() { sc "$@" | grep -o 'subject=.*' | head -1; }
check() { local name=$1 got=$2 exp=$3; [ "$got" = "$exp" ]; result "cfg: $name" $? "got: $got"; }
refused() { grep -q 'Cipher is (NONE)\|alert\|error' && echo refused || echo accepted; }

up && {
  check "default floor refuses TLS 1.1" "$(sc -tls1_1 | refused)" refused
  check "default accepts TLS 1.2" "$(sc -tls1_2 | grep -o 'Cipher is .*')" "Cipher is ECDHE-RSA-AES256-GCM-SHA384"
  check "ALPN http/1.1" "$(sc -alpn h2,http/1.1 | grep -o 'ALPN protocol: .*\|No ALPN negotiated')" "ALPN protocol: http/1.1"
  check "default: client picks the cipher" "$(sc -ciphersuites TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384 | grep -o 'Cipher is .*')" "Cipher is TLS_CHACHA20_POLY1305_SHA256"
  check "default session tickets per handshake" "$(sct | grep -c 'Post-Handshake New Session Ticket arrived')" 2
  before=$(subj)
  ( "$W/tlsload" hs "$CPORT" 4 0 3 > "$W/reload.load" ) & lp=$!
  for i in $(seq 40); do curl -sk --max-time 5 $CU/reload > "$W/reload.out"; sleep 0.05; done
  wait $lp
  check "hot reload x40 under handshake load: last reply" "$(tr -s ' ' < "$W/reload.out")" "reload 40 -> 0"
  check "hot reload: new certificate served" "$before -> $(subj)" "subject=CN=localhost -> subject=CN=localhost, O=renewed"
  check "hot reload: handshake load had no errors" "$(grep -o '"errors":[0-9]*' "$W/reload.load")" '"errors":0'
  check "reload with a mismatched key is refused" "$(curl -sk --max-time 5 $CU/reload-bad | tr -s ' ')" "reload with a mismatched key -> -1"
  check "after a refused reload the old certificate stays" "$(subj)" "subject=CN=localhost, O=renewed"
  down; }

up CFG_CERTS="localhost|$D/cert.pem|$C/key_enc_pkcs8.pem|secret" &&
  check "password key (PKCS#8) via fio_tls_new" "$(sc | grep -o 'Cipher is .*')" "Cipher is TLS_AES_256_GCM_SHA384"; down
up CFG_CERTS="localhost|$D/cert.pem|$C/key_enc_trad.pem|secret" &&
  check "password key (traditional) via fio_tls_new" "$(sc | grep -o 'Cipher is .*')" "Cipher is TLS_AES_256_GCM_SHA384"; down
up CFG_CERTS="localhost|$C/chain.pem|$C/leaf_key.pem|" &&
  check "chain file sends leaf + intermediate, verifies" "$(sc -showcerts | grep -c 'BEGIN CERTIFICATE') $(sc -CAfile $C/root_cert.pem | grep -o 'Verify return code: .*')" "2 Verify return code: 0 (ok)"; down
up CFG_CERTS="a.test|$C/a_cert.pem|$C/a_key.pem|;b.test|$C/b_cert.pem|$C/b_key.pem|" &&
  check "SNI, two names" "$(subj -servername a.test); $(subj -servername b.test); $(subj -servername www.b.test)" "subject=CN=a.test; subject=CN=b.test; subject=CN=a.test"; down
up CFG_TRUST=$C/ca_cert.pem &&
  check "client certs: trust list alone" "$(code) $(code --cert $C/client_cert.pem --key $C/client_key.pem) $(code --cert $C/stranger_cert.pem --key $C/stranger_key.pem)" "200 200 000"; down
up CFG_MIN=1.3 &&
  check "min version 1.3" "$(sc -tls1_2 | refused) $(sc | grep -o 'New, TLSv1.3')" "refused New, TLSv1.3"; down
up CFG_SUITES=TLS_CHACHA20_POLY1305_SHA256 CFG_CIPHERS=ECDHE-RSA-AES128-GCM-SHA256 &&
  check "ciphersuites + cipher list" "$(sc | grep -o 'Cipher is .*'); $(sc -tls1_2 | grep -o 'Cipher is .*'); $(grep -h configure "$W/cfg.log")" "Cipher is TLS_CHACHA20_POLY1305_SHA256; Cipher is ECDHE-RSA-AES128-GCM-SHA256; fio_tls_configure -> 0"; down
up CFG_FLAGS=1 &&
  check "server cipher preference" "$(sc -ciphersuites TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384 | grep -o 'Cipher is .*')" "Cipher is TLS_AES_256_GCM_SHA384"; down
up CFG_BAD_SUITES=TLS_NOT_A_SUITE &&
  check "invalid setting rejected, old one kept" "$(grep -ho -- '-> -1' "$W/cfg.log") $(curl -sk --max-time 5 $CU/ | tr -d ' \n')" "-> -1 ok"; down
up CFG_PEM=1 CFG_CERTS="localhost|$D/cert.pem|$C/key_enc_pkcs8.pem|secret;b.test|$C/b_cert.pem|$C/b_key.pem|" &&
  check "PEM strings, password key, SNI" "$(grep -h set_pem "$W/cfg.log" | tr '\n' ' ')| $(subj) | $(subj -servername b.test)" "fio_tls_cert_set_pem(localhost) -> 0 fio_tls_cert_set_pem(b.test) -> 0 | subject=CN=localhost | subject=CN=b.test"; down
up CFG_TRUST=$C/ca_cert.pem CFG_FLAGS=2 && {
  sct -cert $C/client_cert.pem -key $C/client_key.pem -sess_out "$W/sess.pem" > /dev/null
  check "client certs required" "$(code) $(code --cert $C/client_cert.pem --key $C/client_key.pem) $(code --cert $C/stranger_cert.pem --key $C/stranger_key.pem) $(sc -cert $C/client_cert.pem -key $C/client_key.pem -sess_in "$W/sess.pem" | grep -o '^Reused\|^New' | head -1)" "000 200 000 Reused"; }; down
up CFG_TICKETS=1 &&
  check "SSL_CTX hook from Julia (1 ticket)" "$(grep -h on_context "$W/cfg.log") $(sct | grep -c 'Post-Handshake New Session Ticket arrived')" "fio_tls_on_context -> 0 1"; down
