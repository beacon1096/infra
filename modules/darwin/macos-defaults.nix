# macOS system preferences
{ config, ... }:

{
  system.defaults = {
    dock = {
      autohide = false;
      show-recents = false;
      mru-spaces = false;
      minimize-to-application = true;
    };

    finder = {
      AppleShowAllExtensions = true;
      AppleShowAllFiles = true;
      FXEnableExtensionChangeWarning = false; # no warning when changing file extension
      FXPreferredViewStyle = "clmv";
      QuitMenuItem = true;                    # allow Cmd+Q to quit Finder
      ShowPathbar = true;
      ShowStatusBar = true;
      _FXShowPosixPathInTitle = true;
    };

    NSGlobalDomain = {
      AppleShowAllExtensions = true;
      AppleInterfaceStyleSwitchesAutomatically = true;
      AppleKeyboardUIMode = 3;                          # full keyboard control (Tab through all UI elements)
      InitialKeyRepeat = 15;
      KeyRepeat = 2;
      NSAutomaticCapitalizationEnabled = false;
      NSAutomaticDashSubstitutionEnabled = false;        # disable smart dashes
      NSAutomaticPeriodSubstitutionEnabled = false;      # disable double-space to period
      NSAutomaticQuoteSubstitutionEnabled = false;       # disable smart quotes
      NSAutomaticSpellingCorrectionEnabled = false;
      NSNavPanelExpandedStateForSaveMode = true;         # expand save dialog by default
      NSNavPanelExpandedStateForSaveMode2 = true;
      "com.apple.swipescrolldirection" = true;
    };

    trackpad = {
      Clicking = true;
      TrackpadRightClick = true;
      TrackpadThreeFingerDrag = true;
    };

    screencapture = {
      location = "~/Pictures/Screenshots";
      type = "png";
    };

    loginwindow = {
      GuestEnabled = false;   # disable guest user
      SHOWFULLNAME = true;    # show full name in login window
    };

    CustomUserPreferences = {
      "com.apple.finder" = {
        # Set home directory as startup window
        NewWindowTargetPath = "file:///Users/${config.system.primaryUser}/";
        NewWindowTarget = "PfHm";
        # Set search scope to directory
        FXDefaultSearchScope = "SCcf";
        # Multi-file tab view
        FinderSpawnTab = true;
        # Sort folders first
        _FXSortFoldersFirst = true;
      };
      "com.apple.desktopservices" = {
        # Disable creating .DS_Store files on network and USB volumes
        DSDontWriteNetworkStores = true;
        DSDontWriteUSBStores = true;
      };
      # Show battery percentage
      "/Users/${config.system.primaryUser}/Library/Preferences/ByHost/com.apple.controlcenter".BatteryShowPercentage =
        true;
      # Require password immediately after sleep or screen saver
      "com.apple.screensaver" = {
        askForPassword = 1;
        askForPasswordDelay = 0;
      };
      # Prevent Photos from opening when devices are plugged in
      "com.apple.ImageCapture".disableHotPlug = true;
      # Privacy
      "com.apple.AdLib".allowApplePersonalizedAdvertising = false;
    };
    CustomSystemPreferences = { };
  };
}
