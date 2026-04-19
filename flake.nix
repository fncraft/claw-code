{
  description = "claw — a Rust-based Claude Code compatible CLI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages.default = pkgs.rustPlatform.buildRustPackage {
          pname = "claw";
          version = "0.1.0";

          src = ./rust;

          cargoLock.lockFile = ./rust/Cargo.lock;

          # MCP stdio tests spawn child processes, which are not available
          # in the Nix sandbox. Tests pass fine in a normal dev environment.
          doCheck = false;

          # build.rs calls `git rev-parse` and `date`; both fall back to
          # "unknown" / env vars when unavailable, so no extra inputs needed.
          # SOURCE_DATE_EPOCH is set automatically by Nix for reproducibility.
          nativeBuildInputs = [ pkgs.git ];

          meta = {
            description = "Rust implementation of the Claude Code CLI (claw)";
            homepage = "https://github.com/fncraft/claw-code";
            license = pkgs.lib.licenses.mit;
            mainProgram = "claw";
          };
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ self.packages.${system}.default ];
          packages = with pkgs; [
            cargo
            clippy
            rustfmt
            rust-analyzer
          ];
        };
      }
    );
}
