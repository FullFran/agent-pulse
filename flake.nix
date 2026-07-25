{
  description = "agent-pulse — see which AI agent needs you, in your tmux tab bar";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      homeManagerModules.default = import ./module.nix self;
      homeManagerModules.agent-pulse = self.homeManagerModules.default;

      packages = forAll (pkgs: {
        default = pkgs.stdenvNoCC.mkDerivation {
          pname = "agent-pulse";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/share/agent-pulse
            cp -r scripts adapters tmux $out/share/agent-pulse/
            chmod +x $out/share/agent-pulse/scripts/*
            for s in agent-report agent-heal hook-adapter agent-sessions; do
              makeWrapper $out/share/agent-pulse/scripts/$s $out/bin/$s \
                --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.tmux pkgs.coreutils pkgs.gnused pkgs.gawk ]}
            done
            runHook postInstall
          '';
        };
      });

      checks = forAll (pkgs: {
        shellcheck = pkgs.runCommand "agent-pulse-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          shellcheck -S warning ${./scripts}/agent-report ${./scripts}/agent-heal ${./scripts}/hook-adapter ${./scripts}/agent-sessions
          touch $out
        '';
      });

      formatter = forAll (pkgs: pkgs.nixpkgs-fmt);
    };
}
