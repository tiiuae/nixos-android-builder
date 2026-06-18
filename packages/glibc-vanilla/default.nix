# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{ glibc, linuxHeaders }:
glibc.overrideAttrs (oldAttrs: {
  configureFlags = (oldAttrs.configureFlags or [ ]) ++ [
    "--with-headers=${linuxHeaders}/include"
    "--prefix=/"
    "--libdir=/lib"
    "--libexecdir=/lib"
    "--sysconfdir=/etc"
    "--enable-kernel=6.12"
  ];

  installPhase = ''
    make install DESTDIR=$out
  '';

  dontFixup = true;
  separateDebugInfo = false;
  outputs = [ "out" ];
})
