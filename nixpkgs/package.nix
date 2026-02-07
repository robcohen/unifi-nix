{
  lib,
  stdenv,
  fetchFromGitHub,
  makeWrapper,
  jq,
  openssh,
  coreutils,
  diffutils,
  nix,
}:

stdenv.mkDerivation rec {
  pname = "unifi-nix";
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "robcohen";
    repo = "unifi-nix";
    rev = "v${version}";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };

  nativeBuildInputs = [ makeWrapper ];

  buildInputs = [
    jq
    openssh
    coreutils
    diffutils
    nix
  ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/share/unifi-nix

    # Install scripts
    install -m755 scripts/deploy.sh $out/bin/unifi-deploy
    install -m755 scripts/diff.sh $out/bin/unifi-diff
    install -m755 scripts/eval.sh $out/bin/unifi-eval
    install -m755 scripts/validate-config.sh $out/bin/unifi-validate
    install -m755 scripts/extract-schema.sh $out/bin/unifi-extract-schema

    # Install module and library for Nix evaluation
    cp -r module.nix lib examples $out/share/unifi-nix/

    # Install schemas if present
    if [ -d schemas ]; then
      cp -r schemas $out/share/unifi-nix/
    fi

    # Wrap scripts with dependencies
    for script in $out/bin/unifi-*; do
      wrapProgram "$script" \
        --prefix PATH : ${lib.makeBinPath buildInputs}
    done

    runHook postInstall
  '';

  meta = with lib; {
    description = "Declarative UniFi Dream Machine configuration via Nix";
    longDescription = ''
      unifi-nix provides a declarative way to configure UniFi Dream Machine
      devices using Nix. Define your networks, WiFi, firewall rules, port
      forwards, and DHCP reservations in Nix, preview changes with diff,
      validate against schema, and deploy directly to your UDM.
    '';
    homepage = "https://github.com/robcohen/unifi-nix";
    license = licenses.mit;
    maintainers = with maintainers; [ ];
    platforms = platforms.unix;
    mainProgram = "unifi-deploy";
  };
}
