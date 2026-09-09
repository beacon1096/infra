{ pkgs, ... }:

{
  programs.firefox = {
    enable = true;

    profiles.default = {
      id = 0;
      name = "default";
      isDefault = true;

      # Declaratively install extensions from rycee's NUR repository
      extensions.packages = with pkgs.nur.repos.rycee.firefox-addons; [
        # Personal
        bitwarden
        # Environment
        ublock-origin
        darkreader
        # Contnet
        bilisponsorblock
      ];

      # Keep extension installs declarative, but do not manage Bitwarden's
      # storage.js. Bitwarden stores login/session state in the same file, and
      # rewriting it on each activation resets the selected server and login.
      extensions.force = true;

      # Optional: Search engine and privacy tweaks
      settings = {
        "identity.sync.tokenserver.uri" = "https://firefox-sync.beaco.works/1.0/sync/1.5";

        # Privacy & Security tweaks
        "browser.send_pings" = false;
        "browser.urlbar.speculativeConnect.enabled" = false;
        "dom.security.https_only_mode" = true;
        "privacy.trackingprotection.enabled" = true;
        "toolkit.telemetry.enabled" = false;
        "toolkit.telemetry.unified" = false;

        # Disable pocket
        "extensions.pocket.enabled" = false;

        # Disable autofill (let Bitwarden handle passwords/forms)
        "signon.rememberSignons" = false;
        "browser.formfill.enable" = false;

        # UI tweaks
        "browser.aboutConfig.showWarning" = false;
        "browser.compactmode.show" = true;
      };
    };
  };
}
