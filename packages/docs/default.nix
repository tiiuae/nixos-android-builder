# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{
  lib,
  writeShellApplication,
  pandoc,
  mermaid-filter,
  gitMinimal,
  texliveSmall,
  entr,
  nixosOptionsDoc,
  nixos,
  self,
}:
let
  build-docs = writeShellApplication {
    name = "build-docs";
    runtimeInputs = [
      pandoc
      mermaid-filter
      gitMinimal
      (texliveSmall.withPackages (ps: [
        ps.framed
        ps.fvextra
      ]))
    ];
    text = ''
      cd "$(git rev-parse --show-toplevel 2>/dev/null)/docs"
            pandoc \
              --pdf-engine=xelatex \
              --toc \
              --standalone \
              --metadata=options_json:${optionDocs}/share/doc/nixos/options.json \
              --lua-filter=./nixos-options.lua  \
              --include-in-header=./header.tex \
              --highlight-style=./pygments.theme \
              --filter=mermaid-filter \
              --variable=linkcolor:blue \
              --variable=geometry:a4paper \
              --variable=geometry:margin=3cm \
              --output "./$1.pdf" "./$1.md"
    '';
  };

  watch-docs = writeShellApplication {
    name = "watch-docs";
    runtimeInputs = [
      entr
      gitMinimal
    ];
    text = ''
      find "$(git rev-parse --show-toplevel 2>/dev/null)/docs" -name '*.md' \
          | entr -s "${build-docs}/bin/build-docs $*"
    '';
  };

  optionDocs =
    let
      isDefinedInThisRepo =
        opt: lib.any (decl: lib.hasPrefix (toString self) (toString decl)) (opt.declarations or [ ]);
      isMocked =
        opt:
        opt.loc == [
          "environment"
          "ldso"
        ]
        ||
          opt.loc == [
            "environment"
            "ldso32"
          ];
    in
    (nixosOptionsDoc {
      inherit (nixos) options;
      transformOptions =
        opt: if isDefinedInThisRepo opt && !isMocked opt then opt else opt // { visible = false; };
    }).optionsJSON;
in
{
  inherit build-docs watch-docs;
}
