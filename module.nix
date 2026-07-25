self:
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.agent-pulse;
  pkg = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  options.programs.agent-pulse = {
    enable = lib.mkEnableOption "agent-pulse agent state tracking";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkg;
      description = "The agent-pulse package to install.";
    };

    tmux.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install the tmux layer to ~/.config/agent-pulse/tmux/agents.conf.

        This only places the file. Source it yourself at the END of your tmux
        config, after your theme has loaded:

          source-file ~/.config/agent-pulse/tmux/agents.conf
      '';
    };

    sound = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Play a sound when an unattended agent needs you or finishes.";
    };

    opencode = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Install the OpenCode plugin adapter.";
      };
      pluginDir = lib.mkOption {
        type = lib.types.str;
        default = ".config/opencode/plugins";
        description = "Where OpenCode loads plugins from, relative to $HOME.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    # Scripts are exposed at a stable path so tmux hooks and agent adapters can
    # reference them without knowing anything about the Nix store.
    home.file.".config/agent-pulse/scripts".source =
      "${cfg.package}/share/agent-pulse/scripts";

    home.file.".config/agent-pulse/tmux/agents.conf" = lib.mkIf cfg.tmux.enable {
      source = "${cfg.package}/share/agent-pulse/tmux/agents.conf";
    };

    home.file."${cfg.opencode.pluginDir}/agent-pulse.js" = lib.mkIf cfg.opencode.enable {
      source = "${cfg.package}/share/agent-pulse/adapters/opencode/agent-pulse.js";
    };

    home.sessionVariables = lib.mkIf (!cfg.sound) {
      AGENT_PULSE_SOUND = "0";
    };
  };
}
