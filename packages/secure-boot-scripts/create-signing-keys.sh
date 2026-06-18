#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

set -e

keystore="${1:-./keys}"

if [ -d "$keystore" ]; then
	echo "Directory 'keys' already exists, delete if you want new keys!"
	exit 1
fi

mkdir -p "$keystore"
cd "$keystore"

echo ">>> Generating UUID"
uuidgen --random >guid.txt
cat guid.txt

# PK
echo ""
echo ">>> Generating PK"
openssl req -newkey rsa:4096 -nodes -keyout PK.key -new -x509 -sha256 -days 3650 -subj "/CN=nixos-android-builder/" -out PK.crt
openssl x509 -outform DER -in PK.crt -out PK.cer
cert-to-efi-sig-list -g "$(<guid.txt)" PK.crt PK.esl
sign-efi-sig-list -g "$(<guid.txt)" -k PK.key -c PK.crt PK PK.esl PK.auth
sign-efi-sig-list -g "$(<guid.txt)" -c PK.crt -k PK.key PK /dev/null rm_PK.auth

# KEK
echo ""
echo ">>> Generating KEK"
openssl req -newkey rsa:4096 -nodes -keyout KEK.key -new -x509 -sha256 -days 3650 -subj "/CN=nixos-android-builder/" -out KEK.crt
openssl x509 -outform DER -in KEK.crt -out KEK.cer
cert-to-efi-sig-list -g "$(<guid.txt)" KEK.crt KEK.esl
sign-efi-sig-list -g "$(<guid.txt)" -k PK.key -c PK.crt KEK KEK.esl KEK.auth

# DB
echo ""
echo ">>> Generating DB"
openssl req -newkey rsa:4096 -nodes -keyout db.key -new -x509 -sha256 -days 3650 -subj "/CN=nixos-android-builder/" -out db.crt
openssl x509 -outform DER -in db.crt -out db.cer
cert-to-efi-sig-list -g "$(<guid.txt)" db.crt db.esl
sign-efi-sig-list -g "$(<guid.txt)" -k KEK.key -c KEK.crt db db.esl db.auth

echo ""
ls -la .
