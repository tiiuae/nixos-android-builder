# Pandoc 3.8.3 static binary — matches quarto 1.9.37's expected version.
# Remove this once nixpkgs ships pandoc >= 3.8.
{
  lib,
  stdenv,
  fetchzip,
  autoPatchelfHook,
  gmp,
  zlib,
}:
let
  version = "3.8.3";
in
stdenv.mkDerivation {
  pname = "pandoc-bin";
  inherit version;

  src = fetchzip {
    url = "https://github.com/jgm/pandoc/releases/download/${version}/pandoc-${version}-linux-amd64.tar.gz";
    sha256 = "10k0aynp9bxspy16vh5jlpc6g64ybbxznc02ahyb3zc28cgw2gbl";
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [
    gmp
    zlib
    stdenv.cc.cc.lib
  ];

  installPhase = ''
    mkdir -p $out/bin
    cp bin/pandoc $out/bin/
    cp bin/pandoc-server $out/bin/ 2>/dev/null || true
    cp bin/pandoc-lua $out/bin/ 2>/dev/null || true
  '';

  meta = {
    description = "Universal document converter (static binary)";
    homepage = "https://pandoc.org";
    license = lib.licenses.gpl2Plus;
    platforms = [ "x86_64-linux" ];
  };
}
