# Audio — PipeWire (replaces PulseAudio)
{ ... }:

{
  # Disable PulseAudio (conflicts with PipeWire)
  services.pulseaudio.enable = false;

  # PipeWire — modern audio/video stack
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;   # needed for 32-bit games
    pulse.enable = true;        # PulseAudio compatibility
    wireplumber.enable = true;  # session manager
  };

  # RealtimeKit — allows PipeWire to acquire realtime scheduling
  security.rtkit.enable = true;
}
