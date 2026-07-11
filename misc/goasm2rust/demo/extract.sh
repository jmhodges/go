#!/bin/sh
# Regenerate body.inc: the machine code of xorBytesSSE2 from
# ../../../src/crypto/cipher/xor_amd64.s, extracted via the Go toolchain.
# Requires a host Go installation (any modern version).
set -e
cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp ../../../src/crypto/cipher/xor_amd64.s "$tmp/"
go tool asm -I "$(go env GOROOT)/pkg/include" -p demo -o "$tmp/xor.o" "$tmp/xor_amd64.s"
go tool objdump -gnu "$tmp/xor.o" |
  awk '$3 ~ /^[0-9a-f]+$/ && $2 ~ /^0x/ {
    for (i = 1; i <= length($3); i += 2) printf ".byte 0x%s\n", substr($3, i, 2)
  }' > body.inc
echo "wrote $(wc -l < body.inc) bytes to body.inc"
