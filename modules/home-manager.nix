{ config, lib, pkgs, ... }:

let
  cfg = config.programs.claw;

  # Helper: an option that accepts either a literal string or a path to a
  # secret file (e.g. config.sops.secrets.foo.path).  At shell init the
  # file variant is read with $(cat <path>) so the value never lands in
  # the Nix store.
  credentialOpt = { envVar, description }: lib.mkOption {
    default = { };
    description = ''
      ${description}

      Set exactly one of `value` or `file`.
      - `value` is written directly into the shell environment (use only
        for non-secret or already-encrypted values).
      - `file` is a path whose *contents* become the env var at shell
        startup (works well with sops-nix: set to
        `config.sops.secrets.<name>.path`).
    '';
    type = lib.types.submodule {
      options = {
        value = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Literal credential value (stored in the Nix store).";
        };
        file = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Path to a file whose contents are the credential value.";
        };
      };
    };
  };

  # Emit a shell line for a credential option, or nothing if unset.
  shellLine = envVar: opt:
    if opt.value != null then
      ''export ${envVar}=${lib.escapeShellArg opt.value}''
    else if opt.file != null then
      ''export ${envVar}="$(cat ${lib.escapeShellArg (toString opt.file)})"''
    else
      "";

  hasApiKey     = cfg.credentials.anthropicApiKey.value    != null || cfg.credentials.anthropicApiKey.file    != null;
  hasAuthToken  = cfg.credentials.anthropicAuthToken.value != null || cfg.credentials.anthropicAuthToken.file != null;
  hasOpenRouter = cfg.credentials.openRouter.key.value     != null || cfg.credentials.openRouter.key.file     != null;
  hasLlama      = cfg.llamaServer.enable;

  # llama-server: claw routes through the OpenAI-compat path, which requires
  # OPENAI_API_KEY to be non-empty even though llama-server ignores the value.
  llamaLines = lib.optionalString hasLlama ''
    export OPENAI_API_KEY=${lib.escapeShellArg cfg.llamaServer.apiKey}
    export OPENAI_BASE_URL=${lib.escapeShellArg "${cfg.llamaServer.address}/v1"}
  '';

  credentialLines = lib.concatStringsSep "\n" (lib.filter (s: s != "") [
    (shellLine "ANTHROPIC_API_KEY"  cfg.credentials.anthropicApiKey)
    (shellLine "ANTHROPIC_AUTH_TOKEN" cfg.credentials.anthropicAuthToken)
    (shellLine "OPENAI_API_KEY"     cfg.credentials.openRouter.key)
    (if hasOpenRouter
     then ''export OPENAI_BASE_URL=${lib.escapeShellArg cfg.credentials.openRouter.baseUrl}''
     else "")
    llamaLines
  ]);
in
{
  options.programs.claw = {
    enable = lib.mkEnableOption "claw, the Rust Claude Code CLI";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.claw;
      defaultText = lib.literalExpression "pkgs.claw";
      description = "The claw package to install.";
    };

    credentials = {
      anthropicApiKey = credentialOpt {
        envVar = "ANTHROPIC_API_KEY";
        description = ''
          Anthropic API key (`sk-ant-*`).  Sent as the `x-api-key` HTTP
          header.  Obtain from console.anthropic.com.

          **Do not** put an OAuth bearer token here — use
          `credentials.anthropicAuthToken` for that.
        '';
      };

      anthropicAuthToken = credentialOpt {
        envVar = "ANTHROPIC_AUTH_TOKEN";
        description = ''
          Anthropic OAuth access token (opaque, not `sk-ant-*`).  Sent as
          `Authorization: Bearer <token>`.  Comes from an Anthropic-
          compatible proxy or OAuth flow, not from console.anthropic.com.

          **Do not** put an `sk-ant-*` API key here — that is the most
          common source of 401 errors.  API keys go in
          `credentials.anthropicApiKey`.
        '';
      };

      openRouter = {
        key = credentialOpt {
          envVar = "OPENAI_API_KEY";
          description = ''
            OpenRouter key (`sk-or-v1-*`).  Sent as
            `Authorization: Bearer <key>` via the OpenAI-compatible path.
            Setting this also sets `OPENAI_BASE_URL` to `baseUrl`.
            Obtain from openrouter.ai/keys.
          '';
        };

        baseUrl = lib.mkOption {
          type = lib.types.str;
          default = "https://openrouter.ai/api/v1";
          description = ''
            Base URL written to `OPENAI_BASE_URL` when an OpenRouter key
            is configured.  Override if you use a different OpenAI-compat
            endpoint.
          '';
        };
      };
    };

    llamaServer = {
      enable = lib.mkEnableOption "local llama-server backend via OpenAI-compat path";

      address = lib.mkOption {
        type = lib.types.str;
        default = "http://localhost:8080";
        description = ''
          Base address of the running llama-server instance.
          `OPENAI_BASE_URL` is set to `<address>/v1`.

          Override if you run llama-server on a different port or host,
          e.g. `"http://localhost:9090"`.
        '';
      };

      apiKey = lib.mkOption {
        type = lib.types.str;
        default = "no-key";
        description = ''
          Value written to `OPENAI_API_KEY`.  llama-server does not
          validate this, but claw requires the variable to be non-empty
          before it will attempt the OpenAI-compat path.  The default
          `"no-key"` is sufficient; change it only if your llama-server
          is configured with `--api-key`.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(hasApiKey && hasAuthToken);
        message = ''
          programs.claw: set either `credentials.anthropicApiKey` or
          `credentials.anthropicAuthToken`, not both.  They map to
          different HTTP headers and claw will reject the combination.
        '';
      }
      {
        assertion = !(hasOpenRouter && (hasApiKey || hasAuthToken));
        message = ''
          programs.claw: `credentials.openRouter` is mutually exclusive
          with Anthropic credentials — they target different providers.
        '';
      }
      {
        assertion = !(hasLlama && (hasApiKey || hasAuthToken || hasOpenRouter));
        message = ''
          programs.claw: `llamaServer` is mutually exclusive with all
          other credential options — they each set OPENAI_API_KEY /
          OPENAI_BASE_URL or Anthropic vars and would conflict.
        '';
      }
    ];

    home.packages = [ cfg.package ];

    # Credentials are injected at shell startup so the values come from
    # the live secret files, not the Nix store.
    home.sessionVariablesExtra = lib.mkIf (credentialLines != "") credentialLines;
  };
}
