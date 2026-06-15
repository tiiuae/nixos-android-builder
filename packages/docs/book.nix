{
  lib,
  stdenvNoCC,
  writeShellApplication,
  callPackage,
  quarto,
  typst,
  chromium,
  which,
  lychee,
  cacert,
  nixosOptionsDoc,
  nixos,
  self,
  git,
}:
let
  # Quarto 1.9.37 expects pandoc 3.8.3; nixpkgs has 3.7.
  # Remove this once nixpkgs catches up.
  pandoc-bin = callPackage ./pandoc-bin.nix { };

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

  # Hermetic build producing HTML site
  book-html = stdenvNoCC.mkDerivation {
    pname = "nixos-android-builder-docs-html";
    version = "0.1.0";

    src = lib.fileset.toSource {
      root = ../..;
      fileset = lib.fileset.fileFilter (
        f:
        lib.hasSuffix ".md" f.name
        || lib.hasSuffix ".qmd" f.name
        || lib.hasSuffix ".yml" f.name
        || lib.hasSuffix ".lua" f.name
        || lib.hasSuffix ".css" f.name
        || lib.hasSuffix ".typ" f.name
      ) ../../docs;
    };

    nativeBuildInputs = [
      quarto
      chromium
      which
      lychee
    ];

    QUARTO_PANDOC = "${pandoc-bin}/bin/pandoc";
    QUARTO_CHROMIUM = "${chromium}/bin/chromium";
    HOME = "/build/home";

    buildPhase = ''
      runHook preBuild
      mkdir -p $HOME
      cd docs
      sed -i "s|NIXOS_OPTIONS_JSON|${optionDocs}/share/doc/nixos/options.json|g" _quarto.yml
      quarto render --to html
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cp -a _output $out
      runHook postInstall
    '';

    doCheck = true;
    checkPhase = ''
      runHook preCheck
      SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt \
        lychee '_output/**/*.html' --offline --no-progress
      runHook postCheck
    '';

    meta.description = "NixOS Android Builder docs — HTML site";
  };

  # Interactive preview for development
  preview-book = writeShellApplication {
    name = "preview-book";
    runtimeInputs = [ quarto ];
    text = ''
      export QUARTO_PANDOC="${pandoc-bin}/bin/pandoc"
      export QUARTO_CHROMIUM="${chromium}/bin/chromium"
      export QUARTO_TYPST="${typst}/bin/typst"

      REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
      WORKDIR=$(mktemp -d)
      trap 'rm -rf "$WORKDIR"' EXIT

      cp -a "$REPO/docs/." "$WORKDIR/"
      cd "$WORKDIR"
      sed -i "s|NIXOS_OPTIONS_JSON|${optionDocs}/share/doc/nixos/options.json|g" _quarto.yml

      quarto preview
    '';
  };

  # One-shot build for development (outputs to docs/_output/)
  build-book = writeShellApplication {
    name = "build-book";
    runtimeInputs = [ quarto ];
    text = ''
      export QUARTO_PANDOC="${pandoc-bin}/bin/pandoc"
      export QUARTO_CHROMIUM="${chromium}/bin/chromium"
      export QUARTO_TYPST="${typst}/bin/typst"

      REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
      WORKDIR=$(mktemp -d)
      trap 'rm -rf "$WORKDIR"' EXIT

      cp -a "$REPO/docs/." "$WORKDIR/"
      cd "$WORKDIR"

      sed -i "s|NIXOS_OPTIONS_JSON|${optionDocs}/share/doc/nixos/options.json|g" _quarto.yml

      case "''${1:-all}" in
        html)  quarto render --to html ;;
        pdf)   quarto render --to typst ;;
        all)   quarto render ;;
        *)     echo "Usage: build-book [html|pdf|all]"; exit 1 ;;
      esac

      rm -rf "$REPO/docs/_output"
      cp -a _output "$REPO/docs/_output"
      echo "Output in docs/_output/"
    '';
  };

  # Deploy docs to gh-pages branch
  deploy-docs = writeShellApplication {
    name = "deploy-docs";
    runtimeInputs = [
      quarto
      git
    ];
    text = ''
      export QUARTO_PANDOC="${pandoc-bin}/bin/pandoc"
      export QUARTO_CHROMIUM="${chromium}/bin/chromium"
      export QUARTO_TYPST="${typst}/bin/typst"

      REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
      WORKDIR=$(mktemp -d)
      trap 'rm -rf "$WORKDIR"' EXIT

      echo "Building docs..."
      cp -a "$REPO/docs/." "$WORKDIR/"
      cd "$WORKDIR"
      sed -i "s|NIXOS_OPTIONS_JSON|${optionDocs}/share/doc/nixos/options.json|g" _quarto.yml
      quarto render

      echo "Deploying to gh-pages..."
      DEPLOY=$(mktemp -d)
      cd "$DEPLOY"
      git init -b gh-pages
      cp -a "$WORKDIR/_output/." .
      # Move PDF into the site root for easy download
      mkdir -p pdf
      mv ./*.pdf pdf/ 2>/dev/null || true
      touch .nojekyll
      git add -A
      git commit -m "docs: deploy $(date -I) from $(git -C "$REPO" rev-parse --short HEAD)"

      REMOTE=$(git -C "$REPO" remote get-url origin 2>/dev/null || echo "")
      if [ -z "$REMOTE" ]; then
        echo "No remote found. Push manually:"
        echo "  cd $DEPLOY && git remote add origin <url> && git push -f origin gh-pages"
        # Don't clean up so user can push
        trap - EXIT
      else
        git remote add origin "$REMOTE"
        git push -f origin gh-pages
        echo "Deployed to gh-pages. Enable GitHub Pages (Settings → Pages → Branch: gh-pages) if not already done."
      fi
    '';
  };
in
{
  inherit
    book-html
    build-book
    preview-book
    deploy-docs
    ;
}
